import Foundation
import AVFoundation
import Speech

/// 转录服务：设备端 Apple Speech（默认）+ 云端 OpenAI 兼容
/// 长视频安全：PCM 抽取 → 60s 分块缓冲识别 → 时间偏移拼接（避免整段识别中途失败）
final class TranscriptionService {
    static let shared = TranscriptionService()

    struct Progress { var phase: String; var percent: Double }

    func authorize() async -> Bool {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized
    }

    private func locale(for code: String) -> Locale {
        switch code {
        case "zh": return Locale(identifier: "zh-CN")
        case "en": return Locale(identifier: "en-US")
        case "ja": return Locale(identifier: "ja-JP")
        case "ko": return Locale(identifier: "ko-KR")
        default: return Locale.current
        }
    }

    /// 主入口：视频/音频文件 → [Segment]（词级时间戳尽量保留）
    func transcribe(url: URL, lang: String, onProgress: @escaping (Progress) -> Void) async throws -> [Segment] {
        switch SettingsStore.shared.transcribeSource {
        case .appleSpeech: return try await localSpeech(url: url, lang: lang, onProgress: onProgress)
        case .cloud: return try await cloud(url: url, onProgress: onProgress)
        }
    }

    // MARK: - 设备端（Apple Speech + PCM 分块）
    private func localSpeech(url: URL, lang: String, onProgress: @escaping (Progress) -> Void) async throws -> [Segment] {
        guard await authorize() else { throw AppError.transcribe("语音识别权限被拒绝") }
        guard let recognizer = SFSpeechRecognizer(locale: locale(for: lang)) else {
            throw AppError.transcribe("该语言不支持设备端识别，请改用云端 API")
        }
        // 1) 抽取 PCM 16k mono
        onProgress(.init(phase: "抽取音频", percent: 0.02))
        let pcm = try extractPCM(url: url)
        let total = pcm.count / 2 / 16000 // 秒（Int16 mono 16k）
        // 2) 60s 分块识别
        var allSegments: [Segment] = []
        let chunkSec = 60
        let samplesPerChunk = 16000 * chunkSec
        var offset = 0.0
        var idx = 0
        var cursor = 0
        while cursor < pcm.count {
            let end = min(cursor + samplesPerChunk, pcm.count)
            let slice = Array(pcm[cursor..<end])
            let words = try await recognizeChunk(bufferSamples: slice, recognizer: recognizer)
            // 词级 → 合并 ≤8s 字幕段
            let merged = mergeWords(words, startOffset: offset)
            for m in merged { allSegments.append(Segment(idx: idx, start: m.start, end: m.end, text: m.text, words: nil)); idx += 1 }
            offset += Double((end - cursor) / 2 / 16000)
            cursor = end
            onProgress(.init(phase: "转写中", percent: min(0.95, Double(cursor) / Double(max(1, pcm.count)))))
            _ = total
        }
        onProgress(.init(phase: "转写完成", percent: 1.0))
        return allSegments
    }

    /// AVAssetReader 抽取 PCM Int16 mono 16k
    private func extractPCM(url: URL) throws -> [Int16] {
        let asset = AVURLAsset(url: url)
        guard let track = (try? asset.loadTracks(withMediaType: .audio))?.first else {
            throw AppError.transcribe("没有音频轨")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Int16] = []
        while let sb = output.copyNextSampleBuffer() {
            if let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb)
                var data = Data(count: len)
                data.withUnsafeMutableBytes { ptr in
                    _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: ptr.baseAddress!)
                }
                data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    let arr = ptr.bindMemory(to: Int16.self)
                    samples.append(contentsOf: Array(arr))
                }
            }
        }
        return samples
    }

    private func recognizeChunk(bufferSamples: [Int16], recognizer: SFSpeechRecognizer) async throws -> [Segment.Word] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Segment.Word], Error>) in
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            // Int16 → Float32
            let count = bufferSamples.count
            var floats = [Float](repeating: 0, count: count)
            for i in 0..<count { floats[i] = Float(bufferSamples[i]) / 32768.0 }
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                cont.resume(throwing: AppError.transcribe("音频缓冲创建失败")); return
            }
            buf.frameLength = AVAudioFrameCount(count)
            if let ch = buf.floatChannelData?[0] {
                floats.withUnsafeBufferPointer { src in
                    ch.update(from: src.baseAddress!, count: count)
                }
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.append(buf)
            request.shouldReportPartialResults = false
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            var finished = false
            var words: [Segment.Word] = []
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let r = result, r.isFinal, !finished {
                    finished = true
                    for seg in r.bestTranscription.segments {
                        words.append(Segment.Word(w: seg.substring, s: seg.timestamp, e: seg.timestamp + seg.duration))
                    }
                    request.endAudio()
                    cont.resume(returning: words)
                } else if let e = error, !finished {
                    finished = true
                    request.endAudio()
                    if words.isEmpty { cont.resume(throwing: AppError.transcribe("识别失败: \(e.localizedDescription)")) }
                    else { cont.resume(returning: words) }
                }
            }
            request.endAudio()
            _ = task
        }
    }

    /// 词级 → 字幕段（≤8s / ≤18 字），块内时间 + 偏移
    private func mergeWords(_ words: [Segment.Word], startOffset: Double) -> [(start: Double, end: Double, text: String)] {
        var out: [(Double, Double, String)] = []
        var curText = ""
        var curStart: Double?
        var curEnd = 0.0
        for w in words {
            let s = w.s + startOffset
            let e = w.e + startOffset
            if curStart == nil { curStart = s }
            curText += w.w
            curEnd = e
            let tooLong = curText.count >= 18 || (curEnd - (curStart ?? 0)) >= 8.0
            if tooLong {
                out.append((curStart ?? s, curEnd, curText))
                curText = ""; curStart = nil
            }
        }
        if !curText.isEmpty, let cs = curStart { out.append((cs, curEnd, curText)) }
        return out
    }

    // MARK: - 云端（OpenAI 兼容 /audio/transcriptions；先抽 AAC 音轨）
    private func cloud(url: URL, onProgress: @escaping (Progress) -> Void) async throws -> [Segment] {
        guard let p = SettingsStore.provider(SettingsStore.shared.llmProviderId) else { throw AppError.transcribe("供应商无效") }
        onProgress(.init(phase: "抽取音频轨", percent: 0.05))
        let audioURL = Paths.temp.appendingPathComponent("transcribe_\(UUID().uuidString.prefix(6)).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AppError.transcribe("音频导出会话创建失败")
        }
        session.outputURL = audioURL
        session.outputFileType = .m4a
        await session.export()
        guard FileManager.default.fileExists(atPath: audioURL.path) else { throw AppError.transcribe("音频导出失败") }
        onProgress(.init(phase: "上传云端识别", percent: 0.3))
        let base = SettingsStore.shared.effectiveLLMBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let endpoint = URL(string: base + "/audio/transcriptions")!
        var req = URLRequest(url: endpoint, timeoutInterval: 600)
        req.httpMethod = "POST"
        let key = SettingsStore.shared.apiKey(for: SettingsStore.shared.llmProviderId)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let boundary = "----AutoClip\(Int.random(in: 1_000_000...9_999_999))"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(SettingsStore.shared.cloudTranscribeModel)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n".data(using: .utf8)!)
        let fileData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.transcribe("云端转录失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        // verbose_json → segments
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segs = obj["segments"] as? [[String: Any]] else {
            throw AppError.transcribe("云端响应缺 segments")
        }
        var out: [Segment] = []
        for (i, s) in segs.enumerated() {
            let start = s["start"] as? Double ?? 0
            let end = s["end"] as? Double ?? 0
            let text = s["text"] as? String ?? ""
            out.append(Segment(idx: i, start: start, end: end, text: text.trimmingCharacters(in: .whitespacesAndNewlines), words: nil))
        }
        onProgress(.init(phase: "转写完成", percent: 1.0))
        _ = p
        return out
    }
}

enum AppError: Error, LocalizedError {
    case transcribe(String)
    case pipeline(String)
    case render(String)
    case import_(String)
    var errorDescription: String? {
        switch self {
        case .transcribe(let m): return "转写错误: \(m)"
        case .pipeline(let m): return "管线错误: \(m)"
        case .render(let m): return "渲染错误: \(m)"
        case .import_(let m): return "导入错误: \(m)"
        }
    }
}
