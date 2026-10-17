import Foundation
import AVFoundation
import CoreImage
import UIKit

/// 渲染引擎（对齐 pipeline/step6_video.py + services/video_encoder.py + publish_export.py + output_branding.py）
/// - 编码：AVAssetExportSession（Apple 硬编优先，等价原版 videotoolbox 优先 + libx264 兜底）
/// - 画幅：original 直出 / fullscreen 竖版填满 / interview 访谈式（模糊底+居中）
/// - 字幕烧录：AVVideoCompositionCoreAnimationTool，4 风格参数来自 publish_export.py
/// - 水印：output_branding.py「Made with AutoClip」fontsize=width*0.035 居中，可关
final class RenderService {
    static let shared = RenderService()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    struct RenderProgress { var phase: String; var percent: Double }

    func render(clip: Clip, project: Project, onProgress: @escaping (RenderProgress) -> Void) async throws -> URL {
        var c = clip
        c.renderStatus = .rendering
        c.save()
        defer { if c.renderStatus != .done { c.renderStatus = .failed; c.save() } }

        let sourceURL = URL(fileURLWithPath: project.sourceRef)
        let outDir = Paths.outputs.appendingPathComponent(project.id, isDirectory: true)
        try outDir.ensureDir()
        let outURL = outDir.appendingPathComponent("clip_\(clip.idx + 1).mp4")
        try? FileManager.default.removeItem(at: outURL)

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let total = CMTimeGetSeconds(duration)
        let start = CMTime(seconds: max(0, clip.start), preferredTimescale: 600)
        let endCM = CMTime(seconds: min(total, clip.end), preferredTimescale: 600)
        let range = CMTimeRange(start: start, end: endCM)
        let clipDur = max(0.5, CMTimeGetSeconds(range.duration))

        onProgress(.init(phase: "准备", percent: 0.05))
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw AppError.render("导出会话创建失败")
        }
        session.outputURL = outURL
        session.outputFileType = .mp4
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true

        // 目标画幅
        let settings = SettingsStore.shared
        let mode = settings.aspectMode
        let srcW = CGFloat(project.width ?? 1080)
        let srcH = CGFloat(project.height ?? 1920)
        var renderSize = CGSize(width: srcW, height: srcH)

        if mode != "original" {
            // 竖版 9:16（横源转竖；竖源保持）
            let targetH: CGFloat = 1920
            let targetW: CGFloat = 1080
            renderSize = CGSize(width: targetW, height: targetH)
            let comp = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { [weak self] request in
                guard let self else { return }
                let out = self.compositeFrame(request.sourceImage, mode: mode, target: renderSize)
                request.finish(with: out, context: self.ciContext)
            })
            comp.renderSize = renderSize
            comp.frameDuration = CMTime(value: 1, timescale: 30)
            session.videoComposition = comp
        }

        // 字幕烧录 + 水印（CoreAnimation 工具层）
        let overlay = Self.buildOverlay(
            clip: clip,
            segments: Segment.all(projectId: project.id).filter { $0.end > clip.start && $0.start < clip.end },
            clipStart: clip.start,
            size: renderSize,
            styleName: settings.subtitleStyle,
            watermark: settings.watermarkEnabled
        )
        if let overlay {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: renderSize)
            let videoLayer = CALayer()
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            parent.addSublayer(overlay)
            session.videoComposition = session.videoComposition ?? {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: 30)
                return vc
            }()
            session.videoComposition?.customVideoCompositorClass = nil
            let tool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
            session.animationTool = tool
        }

        onProgress(.init(phase: "导出中", percent: 0.3))
        try await session.export()
        guard FileManager.default.fileExists(atPath: outURL.path) else { throw AppError.render("导出无产物") }
        c.renderStatus = .done
        c.outputPath = outURL.path
        c.save()
        onProgress(.init(phase: "完成", percent: 1.0))
        Log.render.log("渲染完成 \(outURL.lastPathComponent) \(TimeFmt.hms(clipDur))")
        return outURL
    }

    // MARK: - 逐帧画幅合成（fullscreen 填满裁切 / interview 模糊底）
    private func compositeFrame(_ src: CIImage, mode: String, target: CGSize) -> CIImage {
        let srcW = src.extent.width, srcH = src.extent.height
        if mode == "fullscreen" {
            // 填满：等比放大裁切
            let scale = max(target.width / srcW, target.height / srcH)
            let scaled = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = (target.width - scaled.extent.width) / 2
            let dy = (target.height - scaled.extent.height) / 2
            let moved = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            return moved.cropped(to: CGRect(origin: .zero, size: target))
        }
        // interview：模糊放大背景 + 前景等比居中
        let bgScale = max(target.width / srcW, target.height / srcH) * 1.15
        var bg = src.transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
        bg = bg.transformed(by: CGAffineTransform(translationX: (target.width - bg.extent.width) / 2, y: (target.height - bg.extent.height) / 2))
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(bg, forKey: kCIInputImageKey)
            blur.setValue(40.0, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage { bg = blurred.cropped(to: CGRect(origin: .zero, size: target)) }
        }
        // 前景
        let fgScale = min(target.width / srcW, target.height / srcH)
        var fg = src.transformed(by: CGAffineTransform(scaleX: fgScale, y: fgScale))
        fg = fg.transformed(by: CGAffineTransform(translationX: (target.width - fg.extent.width) / 2, y: (target.height - fg.extent.height) / 2))
        return fg.composited(over: bg).cropped(to: CGRect(origin: .zero, size: target))
    }

    // MARK: - 覆盖层（字幕 + 水印）
    static func buildOverlay(clip: Clip, segments: [Segment], clipStart: Double, size: CGSize,
                             styleName: String, watermark: Bool) -> CALayer? {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        let style = SubtitleIO.style(styleName)
        let clipDur = max(0.5, clip.end - clip.start)
        let fontPx = size.height * style.fontRatio
        var hasContent = false

        for seg in segments {
            // 字幕段相对切片的时间
            let relStart = max(0, seg.start - clipStart)
            let relEnd = min(clipDur, seg.end - clipStart)
            guard relEnd - relStart > 0.15 else { continue }
            let text = SubtitleIO.paged(seg.text)
            guard !text.isEmpty else { continue }
            hasContent = true

            let layer = CATextLayer()
            let lineCount = text.components(separatedBy: "\n").count
            let layerH = fontPx * CGFloat(lineCount) * 1.45 + 12
            layer.frame = CGRect(x: 12, y: size.height - size.height * style.marginBottomRatio - layerH,
                                 width: size.width - 24, height: layerH)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontPx, weight: style.bold ? .semibold : .regular),
                .foregroundColor: UIColor(red: style.color.r, green: style.color.g, blue: style.color.b, alpha: 1),
            ]
            layer.string = NSAttributedString(string: text, attributes: attrs)
            layer.alignmentMode = .center
            layer.isWrapped = true
            layer.contentsScale = UIScreen.main.scale
            layer.cornerRadius = style.boxOpacity > 0 ? 6 : 0
            if style.boxOpacity > 0 {
                layer.backgroundColor = UIColor(white: 0, alpha: style.boxOpacity).cgColor
            }
            // 描边/阴影（对应 ASS Outline/Shadow）
            if style.shadow > 0 {
                layer.shadowOpacity = 0.9
                layer.shadowRadius = style.shadow
                layer.shadowOffset = CGSize(width: 0, height: style.shadow)
                layer.shadowColor = UIColor.black.cgColor
            }
            if style.stroke > 0, style.boxOpacity == 0 {
                // CATextLayer 无原生描边：用阴影近似轮廓（iOS 渲染差异，记录于矩阵）
                layer.shadowOpacity = 0.85
                layer.shadowRadius = style.stroke * 0.6
                layer.shadowOffset = .zero
                layer.shadowColor = UIColor.black.cgColor
            }
            // 时间窗动画
            let anim = CAKeyframeAnimation(keyPath: "opacity")
            let t0 = relStart / clipDur, t1 = relEnd / clipDur
            anim.duration = clipDur
            anim.values = [0, 1, 1, 0].map { NSNumber(value: $0) }
            anim.keyTimes = [max(0, t0 - 0.001), t0 + 0.002, max(t1 - 0.002, t0 + 0.003), min(1, t1)]
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.opacity = 0
            layer.add(anim, forKey: "vis")
            root.addSublayer(layer)
        }

        if watermark {
            hasContent = true
            let wm = CATextLayer()
            let wmFont = size.width * 0.035
            let text = "Made with AutoClip"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: wmFont, weight: .medium),
                .foregroundColor: UIColor(white: 1, alpha: 0.55),
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            wm.string = str
            wm.contentsScale = UIScreen.main.scale
            wm.alignmentMode = .center
            let est = (text as NSString).size(withAttributes: attrs)
            wm.frame = CGRect(x: (size.width - est.width) / 2, y: (size.height - est.height) / 2,
                              width: est.width + 8, height: est.height + 4)
            root.addSublayer(wm)
        }
        return hasContent ? root : nil
    }
}
