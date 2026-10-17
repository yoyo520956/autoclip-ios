import SwiftUI

/// Calm Premium 组件库（DESIGN.md：克制、留白、发丝分隔、唯一强调蓝）
struct Card<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .background(Theme.card)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
    }
}

struct StatusPill: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.10))
        .cornerRadius(20)
        .foregroundColor(color)
    }
}

struct ProgressLine: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 4)
        .animation(.easeInOut(duration: 0.3), value: value)
    }
}

struct Row: View {
    var title: String
    var value: String
    var body: some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundColor(Theme.sub)
            Spacer()
            Text(value).font(.system(size: 14, weight: .medium)).foregroundColor(Theme.ink)
        }
    }
}

/// 主 CTA：实心墨（DESIGN.md cta-bg #1A1A19）
struct CTAButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.ink)
                .cornerRadius(12)
        }
    }
}
