// Renders one message, applying the verdict at display time.

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var isLastInGroup: Bool = true
    var onInspect: () -> Void = {}
    var onReveal: () -> Void = {}

    private var isOut: Bool { message.isOutgoing }

    private var textColor: Color { isOut ? Color.white.opacity(0.97) : WZ.textPrimary }
    private var timeColor: Color { isOut ? Color.white.opacity(0.6) : WZ.textTertiary }

    private let radius: CGFloat = 21
    private let tailRadius: CGFloat = 7

    var body: some View {
        VStack(alignment: isOut ? .trailing : .leading, spacing: 5) {
            bubble
            if message.wasModerated { footer }
        }
        .frame(maxWidth: .infinity, alignment: isOut ? .trailing : .leading)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: (!isOut && isLastInGroup) ? tailRadius : radius,
            bottomTrailingRadius: (isOut && isLastInGroup) ? tailRadius : radius,
            topTrailingRadius: radius,
            style: .continuous
        )
    }

    private var bubble: some View {
        Text(bodyText)
            .font(.system(size: 14.5))
            .foregroundStyle(textColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .overlay(alignment: isOut ? .topLeading : .topTrailing) {
                if message.wasModerated {
                    shieldBadge.offset(x: isOut ? -6 : 6, y: -5)
                }
            }
            .frame(maxWidth: 284, alignment: isOut ? .trailing : .leading)
            .contentShape(Rectangle())
            .onTapGesture { if message.verdict != nil { onInspect() } }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = bubbleShape
        if isOut {
            shape
                .fill(
                    LinearGradient(
                        colors: [WZ.orange, WZ.orangeDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
        } else {
            shape
                .fill(Color.white.opacity(0.085))
                .background(shape.fill(.ultraThinMaterial.opacity(0.5)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.11), lineWidth: 0.7))
        }
    }

    private var shieldBadge: some View {
        Image(systemName: message.revealed ? "eye.fill" : "shield.lefthalf.filled")
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(3.5)
            .background(Circle().fill(verdictTint))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: 0.9))
    }

    private var verdictTint: Color {
        guard let v = message.verdict else { return WZ.mask }
        switch v.action {
        case .allow, .hint: return WZ.allow
        case .mask:         return WZ.mask
        case .warn:         return WZ.warn
        case .block:        return WZ.block
        case .review:       return WZ.review
        }
    }

    private var bodyText: AttributedString {
        var s = renderedText

        var meta = AttributedString("   " + message.timestamp.wzTimeLabel)
        if isOut { meta += AttributedString(" " + message.status.textGlyph) }
        meta.font = .system(size: 10, weight: .medium)
        meta.foregroundColor = timeColor
        s += meta

        return s
    }

    private var renderedText: AttributedString {
        guard let verdict = message.verdict,
              verdict.action != .allow, verdict.action != .hint,
              !verdict.redactedRanges.isEmpty
        else {
            return AttributedString(message.text)
        }

        let chars = Array(message.text)
        var out = AttributedString()

        var merged: [Range<Int>] = []
        for r in verdict.redactedRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let clipped = max(0, r.lowerBound)..<min(chars.count, r.upperBound)
            guard clipped.lowerBound < clipped.upperBound else { continue }
            if let last = merged.last, clipped.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, clipped.upperBound)
            } else {
                merged.append(clipped)
            }
        }

        var cursor = 0
        for r in merged {
            if cursor < r.lowerBound {
                out += AttributedString(String(chars[cursor..<r.lowerBound]))
            }

            if message.revealed {
                var seg = AttributedString(String(chars[r]))
                seg.underlineStyle = .single
                seg.foregroundColor = isOut ? .white : WZ.orange
                out += seg
            } else {
                var seg = AttributedString(String(repeating: "●", count: min(max(r.count, 3), 6)))
                seg.font = .system(size: 10, weight: .bold)
                seg.foregroundColor = isOut ? Color.white.opacity(0.9) : WZ.orange
                out += seg
            }
            cursor = r.upperBound
        }
        if cursor < chars.count {
            out += AttributedString(String(chars[cursor...]))
        }
        return out
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let v = message.verdict {
                Text(v.action.label)
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(verdictTint))

                Text(String(format: "%.2fms", v.latencyMs))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(WZ.textTertiary)

                Button(action: onReveal) {
                    Text(message.revealed ? "Hide" : "Reveal")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(WZ.textSecondary)
                }
                .buttonStyle(.plain)

                Button(action: onInspect) {
                    Text("Why?")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(WZ.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
    }
}

struct SystemNoticeRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WZ.orange)
                .padding(.top, 1)

            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(WZ.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1.5)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: 306)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WZ.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(WZ.orange.opacity(0.28), lineWidth: 0.8)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(WZ.orange)
                .frame(width: 2.5)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
    }
}
