import Foundation
import AVFoundation
import UIKit

/// 封面生成（对齐 services/cover.py 的本地路径：抽帧 + 标题合成；AI 生图走图片供应商，v0.2）
final class CoverService {
    static let shared = CoverService()

    @discardableResult
    func generate(clip: Clip, project: Project) throws -> String {
        // 已有封面跳过
        if let p = clip.coverPath, FileManager.default.fileExists(atPath: p) { return p }
        let asset = AVURLAsset(url: URL(fileURLWithPath: project.sourceRef))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1920)
        let mid = CMTime(seconds: (clip.start + clip.end) / 2, preferredTimescale: 600)
        let cg = try gen.copyCGImage(at: mid, actualTime: nil)
        let base = UIImage(cgImage: cg)

        // 标题合成（上三分之一安全区）
        let target = CGSize(width: 1080, height: Int(1080.0 * (Double(project.height ?? 1920) / Double(project.width ?? 1080))))
        let renderer = UIGraphicsImageRenderer(size: target)
        let img = renderer.image { ctx in
            base.draw(in: CGRect(origin: .zero, size: target))
            let title = clip.title.isEmpty ? "AutoClip" : clip.title
            let fontSize: CGFloat = target.width * 0.075
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = fontSize * 0.25
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .strokeColor: UIColor.black,
                .strokeWidth: -6,
            ]
            let maxW = target.width * 0.86
            let attr = NSAttributedString(string: title, attributes: attrs)
            let rect = attr.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], context: nil)
            let y = target.height * 0.08
            attr.draw(in: CGRect(x: (target.width - rect.width) / 2, y: y, width: rect.width, height: rect.height))
        }
        let url = Paths.covers.appendingPathComponent("cover_\(project.id)_\(clip.idx + 1).jpg")
        if let data = img.jpegData(compressionQuality: 0.92) {
            try data.write(to: url)
            var c = clip
            c.coverPath = url.path
            c.save()
            return url.path
        }
        throw AppError.render("封面编码失败")
    }
}
