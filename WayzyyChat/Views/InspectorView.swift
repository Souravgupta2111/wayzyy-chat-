// Shows the verdict behind a message: detections, reason codes, features and timings.

import SwiftUI

struct InspectorView: View {
    let text: String
    let verdict: Verdict

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    verdictHeader
                    metricsRow
                    if !verdict.detections.isEmpty { detectionsCard }
                    if !verdict.transformsApplied.isEmpty { pipelineCard }
                    if !verdict.features.isEmpty { featuresCard }
                    reasonCard
                    Spacer(minLength: 20)
                }
                .padding(16)
            }
            .background(WZ.bg)
            .navigationTitle("Why this verdict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(WZ.surface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(WZ.orange)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var tint: Color {
        switch verdict.action {
        case .allow, .hint: return WZ.allow
        case .mask:         return WZ.mask
        case .warn:         return WZ.warn
        case .block:        return WZ.block
        case .review:       return WZ.review
        }
    }

    private var verdictHeader: some View {
        WZCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Text(verdict.action.label)
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(tint))

                    Text("tier \(verdict.tierReached)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(WZ.textTertiary)

                    Spacer()

                    Text(String(format: "%.3f ms", verdict.latencyMs))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(WZ.orange)
                }

                Text("\"\(text)\"")
                    .font(.system(size: 13))
                    .foregroundStyle(WZ.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("score")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(WZ.textTertiary)
                        Spacer()
                        Text(String(format: "%.3f", verdict.score))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(tint)
                        Text("· mask at \(String(format: "%.2f", verdict.threshold))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(WZ.textTertiary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(WZ.surfaceHigh).frame(height: 6)
                            Capsule().fill(tint)
                                .frame(width: max(3, geo.size.width * verdict.score), height: 6)
                            Rectangle()
                                .fill(Color.white.opacity(0.65))
                                .frame(width: 1.5, height: 12)
                                .offset(x: geo.size.width * verdict.threshold)
                        }
                    }
                    .frame(height: 12)
                }
            }
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 10) {
            WZCard(padding: 12) {
                WZMetric(value: "\(verdict.obfuscationEffort)", label: "Obfusc. effort", tint: WZ.orange)
            }
            WZCard(padding: 12) {
                WZMetric(value: "\(verdict.detections.count)", label: "Candidates")
            }
            WZCard(padding: 12) {
                WZMetric(value: "\(verdict.transformsApplied.count)", label: "Transforms")
            }
        }
    }

    private var detectionsCard: some View {
        WZCard {
            VStack(alignment: .leading, spacing: 11) {
                cardTitle("Candidates recovered")

                ForEach(verdict.detections) { d in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Image(systemName: d.category.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(WZ.orange)
                            Text(d.category.display)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(WZ.textPrimary)
                            Spacer()
                            Text(String(format: "%.2f", d.confidence))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(confidenceTint(d.confidence))
                        }

                        HStack(spacing: 6) {
                            Text(d.surface.isEmpty ? "—" : d.surface)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(WZ.textSecondary)
                                .lineLimit(2)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(WZ.textTertiary)
                            Text(d.canonical)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(WZ.orange)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(WZ.surfaceRaised)
                        )

                        Text(d.reason)
                            .font(.system(size: 10.5))
                            .foregroundStyle(WZ.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !d.transforms.isEmpty {
                            transformChips(d.transforms, effort: d.effort)
                        }
                    }
                    .padding(.bottom, 4)

                    if d.id != verdict.detections.last?.id {
                        Divider().overlay(WZ.hairline)
                    }
                }
            }
        }
    }

    private func transformChips(_ transforms: [String], effort: Int) -> some View {
        let deliberate = transforms.filter { Canonicalizer.deliberateTransforms.contains($0) }
        return VStack(alignment: .leading, spacing: 4) {
            if !deliberate.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(deliberate, id: \.self) { t in
                        Text(t)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(WZ.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(WZ.orange.opacity(0.14)))
                            .overlay(Capsule().strokeBorder(WZ.orange.opacity(0.3), lineWidth: 0.6))
                    }
                }
                Text("Effort \(effort) — de-obfuscation this deliberate is itself the intent signal.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(WZ.textTertiary)
            }
        }
    }

    private func confidenceTint(_ v: Double) -> Color {
        v >= 0.85 ? WZ.block : (v >= 0.6 ? WZ.warn : WZ.textSecondary)
    }

    private var pipelineCard: some View {
        WZCard {
            VStack(alignment: .leading, spacing: 9) {
                cardTitle("Canonicalisation pipeline")
                Text("Rather than matching each evasion, the message is normalised until the evasion disappears. One matcher instead of fifty — and it generalises to patterns never seen before.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WZ.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                FlowRow(spacing: 5) {
                    ForEach(verdict.transformsApplied, id: \.self) { t in
                        let isDeliberate = Canonicalizer.deliberateTransforms.contains(t)
                        Text(t)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(isDeliberate ? WZ.orange : WZ.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(isDeliberate ? WZ.orange.opacity(0.14) : WZ.surfaceHigh)
                            )
                    }
                }
            }
        }
    }

    private var featuresCard: some View {
        WZCard {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("Score contributions")
                Text("Logistic fusion over deterministic features. Calibrated, because the thresholds downstream are business policy.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WZ.textTertiary)

                let maxMag = max(verdict.features.map { abs($0.1) }.max() ?? 1, 0.01)

                ForEach(Array(verdict.features.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        Text(item.0)
                            .font(.system(size: 10.5))
                            .foregroundStyle(WZ.textSecondary)
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(2)

                        GeometryReader { geo in
                            let half = geo.size.width / 2
                            let w = abs(item.1) / maxMag * half
                            ZStack(alignment: .center) {
                                Rectangle().fill(WZ.surfaceHigh).frame(height: 5)
                                HStack(spacing: 0) {
                                    if item.1 < 0 {
                                        Spacer()
                                        Capsule().fill(WZ.allow).frame(width: max(2, w), height: 5)
                                        Spacer().frame(width: half)
                                    } else {
                                        Spacer().frame(width: half)
                                        Capsule().fill(WZ.block).frame(width: max(2, w), height: 5)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .frame(height: 10)

                        Text(String(format: "%+.2f", item.1))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(item.1 < 0 ? WZ.allow : WZ.block)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var reasonCard: some View {
        WZCard {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle("Reason codes")
                FlowRow(spacing: 5) {
                    ForEach(verdict.reasonCodes, id: \.self) { code in
                        Text(code)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(WZ.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(WZ.surfaceHigh))
                    }
                }
                Text("Emitted with every verdict alongside model and policy versions, so decisions are replayable and appealable.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(WZ.textTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func cardTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(WZ.textTertiary)
    }
}

struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
