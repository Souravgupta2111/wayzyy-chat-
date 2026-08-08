// Moderation queue and Tier-3 operational state.

import SwiftUI

struct OpsView: View {
    @EnvironmentObject var store: ChatStore
    @State private var inspecting: QueueItem? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statsRow
                    architectureCard
                    queueSection
                    Spacer(minLength: 24)
                }
                .padding(16)
            }
            .background(WZ.bg)
            .navigationTitle("Trust & Safety")
            .toolbarBackground(WZ.surface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $inspecting) { item in
                InspectorView(text: item.text, verdict: item.verdict)
            }
        }
    }

    private var statsRow: some View {
        let pending = store.queue.filter { $0.resolution == nil }.count
        let overturned = store.queue.filter { $0.resolution == .overturned }.count
        let resolved = store.queue.filter { $0.resolution != nil }.count
        let overturnRate = resolved == 0 ? 0 : Double(overturned) / Double(resolved)

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                WZCard(padding: 12) {
                    WZMetric(value: "\(pending)", label: "In queue", tint: pending > 0 ? WZ.warn : WZ.allow)
                }
                WZCard(padding: 12) {
                    WZMetric(value: String(format: "%.0f%%", overturnRate * 100), label: "Overturn rate",
                             tint: overturnRate > 0.2 ? WZ.block : WZ.allow)
                }
                WZCard(padding: 12) {
                    WZMetric(value: "\(store.trainingExamplesCollected)", label: "Training labels", tint: WZ.orange)
                }
            }
        }
    }

    private var architectureCard: some View {
        WZCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WZ.orange)
                    Text("DEPLOYMENT SHAPE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(WZ.textTertiary)
                }

                tierRow("1", "Deterministic · RECOVER", "Canonicalise, extract, validate",
                        "in-process · ~1.4 ms · always on", WZ.allow)
                tierRow("2", "Retrieval · RECOGNISE", "Nearest-neighbour over intent exemplars",
                        "in-process · ~0.2 ms · always on", WZ.allow)
                tierRow("3", "Semantic judge · REASON", "LLM over the conversation window",
                        store.tier3Enabled
                            ? "\(SecretsStore.providerDescription) · async"
                            : "OFF by default · measured 1.7 s p50", WZ.review)

                Toggle(isOn: Binding(
                    get: { store.tier3Enabled },
                    set: { store.tier3Enabled = $0 }
                )) {
                    Text("Enable Tier 3 on the live chat path")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WZ.textSecondary)
                }
                .tint(WZ.orange)

                if let activity = store.tier3Activity {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6).tint(WZ.orange)
                        Text(activity)
                            .font(.system(size: 9.5))
                            .foregroundStyle(WZ.orange)
                    }
                }

                Text("Tiers 1 and 2 run in-process on the write path: a sidecar would turn a sub-millisecond decision into a 10-50 ms one and make moderation availability cap chat availability. Tier 3 is off by default because measured against a live model it added nothing our corpus could detect that Tier 2 had not already caught for free — at 1.7 s per call. It runs after delivery and revises, never before.")
                    .font(.system(size: 10))
                    .foregroundStyle(WZ.textTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func tierRow(_ n: String, _ title: String, _ role: String, _ note: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(tint))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WZ.textPrimary)
                Text(role)
                    .font(.system(size: 10.5))
                    .foregroundStyle(WZ.textSecondary)
                Text(note)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(WZ.textTertiary)
            }
            Spacer()
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REVIEW QUEUE")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(WZ.textTertiary)

            if store.queue.isEmpty {
                WZCard {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Nothing queued")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WZ.textPrimary)
                        Text("Send a message containing contact details from any thread and it will appear here with full reasoning.")
                            .font(.system(size: 11))
                            .foregroundStyle(WZ.textTertiary)
                    }
                }
            } else {
                ForEach(store.queue) { item in
                    queueCard(item)
                }
            }
        }
    }

    private func queueCard(_ item: QueueItem) -> some View {
        WZCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(item.verdict.action.label)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint(item.verdict)))

                    Text(item.conversationName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(WZ.textSecondary)

                    Spacer()

                    Text(String(format: "%.2f ms", item.verdict.latencyMs))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(WZ.textTertiary)
                }

                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WZ.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                scoreBar(item.verdict)

                if !item.verdict.detections.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("DETECTIONS (\(item.verdict.detections.count))")
                        ForEach(item.verdict.detections) { d in
                            detectionRow(d)
                        }
                    }
                }

                if !item.verdict.reasonCodes.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        sectionLabel("REASON CODES")
                        FlowRow(spacing: 4) {
                            ForEach(item.verdict.reasonCodes, id: \.self) { code in
                                Text(code)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(WZ.textSecondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(WZ.surfaceHigh))
                            }
                        }
                    }
                }

                if !item.verdict.transformsApplied.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        sectionLabel("CANONICALISATION · EFFORT \(item.verdict.obfuscationEffort)")
                        FlowRow(spacing: 4) {
                            ForEach(item.verdict.transformsApplied, id: \.self) { t in
                                let deliberate = Canonicalizer.deliberateTransforms.contains(t)
                                Text(t)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(deliberate ? WZ.orange : WZ.textTertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule().fill(deliberate ? WZ.orange.opacity(0.14) : WZ.surfaceHigh)
                                    )
                            }
                        }
                    }
                }

                if let resolution = item.resolution {
                    HStack(spacing: 5) {
                        Image(systemName: resolution == .upheld ? "checkmark.seal.fill" : "arrow.uturn.backward")
                            .font(.system(size: 9))
                        Text("\(resolution.rawValue) · added to training set")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(resolution == .upheld ? WZ.allow : WZ.review)
                } else {
                    HStack(spacing: 8) {
                        Button { store.resolve(item, as: .upheld) } label: {
                            actionLabel("Uphold", WZ.allow)
                        }
                        .buttonStyle(.plain)

                        Button { store.resolve(item, as: .overturned) } label: {
                            actionLabel("Overturn", WZ.review)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button { inspecting = item } label: {
                            Text("Why?")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(WZ.orange)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(WZ.textTertiary)
    }

    private func scoreBar(_ v: Verdict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionLabel("SCORE")
                Text(String(format: "%.3f", v.score))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint(v))
                Text("· mask at \(String(format: "%.2f", v.threshold)) · tier \(v.tierReached)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(WZ.textTertiary)
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(WZ.surfaceHigh).frame(height: 5)
                    Capsule().fill(tint(v))
                        .frame(width: max(2, geo.size.width * v.score), height: 5)
                    Rectangle()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 1.5, height: 11)
                        .offset(x: geo.size.width * v.threshold)
                }
            }
            .frame(height: 11)
        }
    }

    private func detectionRow(_ d: Detection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: d.category.systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WZ.orange)
                Text(d.category.display)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WZ.textPrimary)
                Spacer()
                if d.effort > 0 {
                    Text("effort \(d.effort)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(WZ.orange)
                }
                Text(String(format: "%.2f", d.confidence))
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(d.confidence >= 0.85 ? WZ.block : WZ.warn)
            }

            if !d.surface.isEmpty || !d.canonical.isEmpty {
                HStack(spacing: 5) {
                    Text(d.surface.isEmpty ? "—" : d.surface)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(WZ.textSecondary)
                        .lineLimit(2)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(WZ.textTertiary)
                    Text(d.canonical)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(WZ.orange)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WZ.surfaceRaised)
                )
            }

            Text(d.reason)
                .font(.system(size: 9.5))
                .foregroundStyle(WZ.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func actionLabel(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.7))
    }

    private func tint(_ v: Verdict) -> Color {
        switch v.action {
        case .allow, .hint: return WZ.allow
        case .mask:         return WZ.mask
        case .warn:         return WZ.warn
        case .block:        return WZ.block
        case .review:       return WZ.review
        }
    }
}
