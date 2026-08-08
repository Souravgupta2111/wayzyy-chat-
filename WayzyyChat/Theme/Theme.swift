// Colours, typography and spacing tokens shared by every view.

import SwiftUI

enum WZ {

    static let orange = Color(hex: 0xEE7A33)
    static let orangeLight = Color(hex: 0xF5975A)
    static let orangeDeep = Color(hex: 0xC85A1B)
    static let orangeSoft = Color(hex: 0xF6C9A8)

    static let brandGradient = LinearGradient(
        colors: [orangeLight, orange, orangeDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let bg = Color(hex: 0x0A0A0C)
    static let surface = Color(hex: 0x16151A)
    static let surfaceRaised = Color(hex: 0x1E1D23)
    static let surfaceHigh = Color(hex: 0x27262E)

    static let textPrimary = Color(hex: 0xF4F4F7)
    static let textSecondary = Color(hex: 0x9B9BA3)
    static let textTertiary = Color(hex: 0x6A6A72)

    static let onMesh = Color(hex: 0xF2F2F5)
    static let onMeshSecondary = Color(hex: 0xF2F2F5).opacity(0.55)

    static let allow = Color(hex: 0x35C77B)
    static let mask = Color(hex: 0xEE7A33)
    static let warn = Color(hex: 0xE8A33D)
    static let block = Color(hex: 0xE85147)
    static let review = Color(hex: 0x7C88F5)

    static let hairline = Color.white.opacity(0.07)

    static let bubbleRadius: CGFloat = 13
    static let cardRadius: CGFloat = 16
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

struct WZMeshCanvas: View {
    var body: some View {
        ZStack {
            WZ.bg

            RadialGradient(
                colors: [Color(hex: 0x2A2028).opacity(0.9), .clear],
                center: UnitPoint(x: 0.12, y: 0.06),
                startRadius: 0,
                endRadius: 340
            )
            RadialGradient(
                colors: [WZ.orangeDeep.opacity(0.34), .clear],
                center: UnitPoint(x: 0.88, y: 0.30),
                startRadius: 0,
                endRadius: 330
            )
            RadialGradient(
                colors: [WZ.orange.opacity(0.20), .clear],
                center: UnitPoint(x: 0.5, y: 1.02),
                startRadius: 0,
                endRadius: 380
            )
        }
    }
}

struct WZHeaderBloom: View {
    var body: some View {
        ZStack {
            WZ.bg

            RadialGradient(
                colors: [Color(hex: 0x3A2418).opacity(0.95), .clear],
                center: UnitPoint(x: 0.18, y: 0.30),
                startRadius: 0,
                endRadius: 300
            )
            RadialGradient(
                colors: [WZ.orangeDeep.opacity(0.42), .clear],
                center: UnitPoint(x: 0.80, y: 0.62),
                startRadius: 0,
                endRadius: 280
            )
            RadialGradient(
                colors: [WZ.orange.opacity(0.16), .clear],
                center: UnitPoint(x: 0.40, y: 0.10),
                startRadius: 0,
                endRadius: 240
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.80),
                    .init(color: WZ.bg.opacity(0.6), location: 0.93),
                    .init(color: WZ.bg, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct WZGlassPill: ViewModifier {
    var fill: Double = 0.07
    var stroke: Double = 0.12

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color.white.opacity(fill)))
            .background(Capsule().fill(.ultraThinMaterial.opacity(0.5)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(stroke), lineWidth: 0.9))
    }
}

extension View {
    func wzGlassPill(fill: Double = 0.07, stroke: Double = 0.12) -> some View {
        modifier(WZGlassPill(fill: fill, stroke: stroke))
    }
}

struct WZGlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 15
    var foreground: Color = WZ.textPrimary
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.09)))
                .background(Circle().fill(.ultraThinMaterial.opacity(0.5)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.9))
        }
        .buttonStyle(.plain)
    }
}

struct WZLogoMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(WZ.brandGradient)
            Image(systemName: "house.fill")
                .font(.system(size: size * 0.40, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct WZChip: View {
    let text: String
    var tint: Color = WZ.orange
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(filled ? Color.white : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(filled ? .clear : tint.opacity(0.38), lineWidth: 0.8))
    }
}

struct WZAvatar: View {
    let initials: String
    var size: CGFloat = 48
    var isHost: Bool = false
    var ring: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: isHost
                            ? [WZ.orangeLight, WZ.orangeDeep]
                            : [Color(hex: 0x3E3E48), Color(hex: 0x24242B)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initials)
                .font(.system(size: size * 0.35, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(WZ.orange.opacity(ring ? 0.9 : 0), lineWidth: 2))
    }
}

struct WZCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WZ.cardRadius, style: .continuous)
                    .fill(WZ.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WZ.cardRadius, style: .continuous)
                    .strokeBorder(WZ.hairline, lineWidth: 1)
            )
    }
}

struct WZMetric: View {
    let value: String
    let label: String
    var tint: Color = WZ.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(WZ.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
