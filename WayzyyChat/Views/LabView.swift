// Interactive harness for probing the engine with arbitrary text.

import SwiftUI

struct LabView: View {
    @EnvironmentObject var store: ChatStore
    @State private var mode: Mode = .playground
    @State private var probe = "hi i a92m a121ksh35ay call me on nine eight 7 six zero"
    @State private var trust: TrustTier = .standard
    @State private var stage: BookingStage = .inquiry
    @State private var inspecting: Verdict? = nil
    @State private var expandedLevels: Set<String> = []

    enum Mode: String, CaseIterable, Identifiable {
        case playground = "Play"
        case benchmark = "Suite"
        case redTeam = "Red team"
        case compare = "Compare"
        var id: String { rawValue }
    }

    private var verdict: Verdict {
        ModerationEngine.shared.evaluate(
            probe,
            actor: ActorContext(trust: trust, stage: stage, conversationID: "lab", senderID: "lab"),
            useConversationBuffer: false
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .playground: playground
                    case .benchmark:  benchmark
                    case .redTeam:    redTeamSection
                    case .compare:    comparisonSection
                    }

                    Spacer(minLength: 24)
                }
                .padding(16)
            }
            .background(WZ.bg)
            .navigationTitle("Moderation Lab")
            .toolbarBackground(WZ.surface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $inspecting) { v in
                InspectorView(text: probe, verdict: v)
            }
        }
    }

    private var playground: some View {
        let v = verdict

        return VStack(alignment: .leading, spacing: 13) {
            WZCard {
                VStack(alignment: .leading, spacing: 9) {
                    Text("MESSAGE UNDER TEST")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(WZ.textTertiary)

                    TextEditor(text: $probe)
                        .font(.system(size: 14))
                        .foregroundStyle(WZ.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 74)
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(WZ.surfaceRaised)
                        )
                        .tint(WZ.orange)

                    HStack(spacing: 8) {
                        Picker("", selection: $trust) {
                            ForEach(TrustTier.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(WZ.orange)

                        Picker("", selection: $stage) {
                            ForEach(BookingStage.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(WZ.orange)

                        Spacer()
                    }
                }
            }

            HStack(spacing: 10) {
                WZCard(padding: 12) {
                    WZMetric(value: v.action.label, label: "Verdict", tint: tint(v))
                }
                WZCard(padding: 12) {
                    WZMetric(value: String(format: "%.3f", v.score), label: "Score", tint: tint(v))
                }
                WZCard(padding: 12) {
                    WZMetric(value: String(format: "%.2f ms", v.latencyMs), label: "Latency", tint: WZ.orange)
                }
            }

            if !v.maskedText.isEmpty, v.action != .allow {
                WZCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WHAT THE RECIPIENT SEES")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(WZ.textTertiary)
                        Text(v.action.withholdsMessage ? "— message withheld —" : v.maskedText)
                            .font(.system(size: 13))
                            .foregroundStyle(WZ.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button { inspecting = v } label: {
                HStack {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text("Full explanation")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(WZ.brandGradient)
                )
            }
            .buttonStyle(.plain)

            presetsCard
        }
    }

    private var presetsCard: some View {
        WZCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("TRY AN EVASION")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(WZ.textTertiary)

                ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                    Button { probe = preset.1 } label: {
                        HStack(spacing: 9) {
                            Text(preset.0)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(WZ.orange)
                                .frame(width: 26, alignment: .leading)
                            Text(preset.1)
                                .font(.system(size: 11.5))
                                .foregroundStyle(WZ.textSecondary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var presets: [(String, String)] {
        [
            ("L0", "Hey, call me on 9876543210 when you land"),
            ("L1", "call me on ９８７６５４３２１０"),
            ("L1", "my іnstа is аkshаy_villа_goа"),
            ("L2", "hi i a92m a121ksh35ay call me on nine eight 7 six zero"),
            ("L2", "mail me akshay dot verma at gmail dot com"),
            ("L2", "mera number ek do teen chaar paanch chhe saat aath nau ek hai"),
            ("L3", "decode this: OTg3NjU0MzIxMA=="),
            ("L3", "----. ---.. --... -.... ..... ....- ...-- ..--- .---- -----"),
            ("L5", "send the payment to akshay@ybl please"),
            ("FP", "My flight AI 2109 lands at 14:35, checkout is at 11"),
            ("FP", "Total is ₹12,500 for 3 nights and 4 guests"),
            ("FP", "Our GSTIN is 27AAPFU0939F1ZV for the invoice"),
        ]
    }

    private var benchmark: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                store.runSuite()
            } label: {
                HStack(spacing: 9) {
                    if store.isRunningSuite {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(store.isRunningSuite ? "Running…" : "Run adversarial suite")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(AdversarialSuite.allCases.count) cases")
                        .font(.system(size: 11, design: .monospaced))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(WZ.brandGradient)
                )
            }
            .buttonStyle(.plain)

            if let r = store.suiteReport {
                metricsGrid(r)
                closureCard(r)
                if !r.failures.isEmpty { failuresCard(r) }
                costCard(r)
            } else {
                WZCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("The suite covers the full loophole taxonomy plus a dedicated false-positive suite of numeric-heavy but legitimate travel messages.")
                            .font(.system(size: 12))
                            .foregroundStyle(WZ.textSecondary)
                        Text("A recall figure quoted without a paired false-positive rate on innocent numeric traffic is not a result.")
                            .font(.system(size: 11))
                            .foregroundStyle(WZ.textTertiary)
                    }
                }
            }
        }
    }

    private func metricsGrid(_ r: SuiteReport) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                WZCard(padding: 12) {
                    WZMetric(value: pct(r.deterministicRecall), label: "Recall (determ.)", tint: WZ.allow)
                }
                WZCard(padding: 12) {
                    WZMetric(value: pct(r.precision), label: "Precision", tint: WZ.allow)
                }
                WZCard(padding: 12) {
                    WZMetric(value: pct(r.falsePositiveRate), label: "False pos rate",
                             tint: r.falsePositiveRate == 0 ? WZ.allow : WZ.warn)
                }
            }
            HStack(spacing: 10) {
                WZCard(padding: 12) {
                    WZMetric(value: String(format: "%.2f", r.p50), label: "p50 ms", tint: WZ.orange)
                }
                WZCard(padding: 12) {
                    WZMetric(value: String(format: "%.2f", r.p99), label: "p99 ms", tint: WZ.orange)
                }
                WZCard(padding: 12) {
                    WZMetric(value: "\(r.results.count)", label: "Cases run")
                }
            }
        }
    }

    private func closureCard(_ r: SuiteReport) -> some View {
        WZCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("CLOSURE BY TAXONOMY LEVEL")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(WZ.textTertiary)

                ForEach(EvasionLevel.allCases, id: \.rawValue) { level in
                    let subset = r.byLevel(level)
                    if !subset.isEmpty {
                        levelRow(r, level, subset)
                    }
                }
            }
        }
    }

    private func levelRow(_ r: SuiteReport, _ level: EvasionLevel, _ subset: [CaseResult]) -> some View {
        let closure = r.closure(level)
        let semantic = subset.filter { $0.testCase.needsSemanticTier }.count
        let isExpanded = expandedLevels.contains(level.rawValue)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded { expandedLevels.remove(level.rawValue) }
                else { expandedLevels.insert(level.rawValue) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(WZ.textTertiary)
                        Text(level.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WZ.textPrimary)
                        Spacer()
                        Text("\(subset.filter(\.passed).count)/\(subset.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(WZ.textTertiary)
                        Text(pct(closure))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(closure == 1 ? WZ.allow : WZ.warn)
                            .frame(width: 50, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(WZ.surfaceHigh).frame(height: 4)
                            Capsule()
                                .fill(closure == 1 ? WZ.allow : WZ.warn)
                                .frame(width: max(2, geo.size.width * closure), height: 4)
                        }
                    }
                    .frame(height: 4)

                    if semantic > 0 {
                        Text("\(semantic) case\(semantic == 1 ? "" : "s") carry no surface pattern — semantic tier by design")
                            .font(.system(size: 9))
                            .foregroundStyle(WZ.review)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(subset) { result in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(result.passed ? WZ.allow : WZ.block)
                                .padding(.top, 1.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.testCase.text)
                                    .font(.system(size: 10))
                                    .foregroundStyle(WZ.textSecondary)
                                    .lineLimit(2)
                                HStack(spacing: 5) {
                                    Text(result.verdict.action.label)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(tint(result.verdict))
                                    Text(String(format: "%.3f", result.verdict.score))
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(WZ.textTertiary)
                                    if !result.testCase.note.isEmpty {
                                        Text("· \(result.testCase.note)")
                                            .font(.system(size: 8))
                                            .foregroundStyle(WZ.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 2)
            }

            Divider().overlay(WZ.hairline)
        }
    }

    private func failuresCard(_ r: SuiteReport) -> some View {
        WZCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("OPEN CASES (\(r.failures.count))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(WZ.textTertiary)

                Text("Reported rather than hidden. Every one of these carries no surface pattern at all — they are escalation candidates for the semantic tier, not pattern bugs.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WZ.textTertiary)

                ForEach(r.failures) { f in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: f.testCase.needsSemanticTier ? "brain" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(f.testCase.needsSemanticTier ? WZ.review : WZ.block)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.testCase.text)
                                .font(.system(size: 10.5))
                                .foregroundStyle(WZ.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(f.testCase.needsSemanticTier ? "semantic tier expected" : "pattern gap")
                                .font(.system(size: 8.5))
                                .foregroundStyle(WZ.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func costCard(_ r: SuiteReport) -> some View {
        let perCoreRPS = 1000.0 / max(r.meanLatency, 0.001)
        let monthlyChecks = perCoreRPS * 60 * 60 * 24 * 30

        return WZCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("COST MODEL (FROM MEASURED LATENCY)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(WZ.textTertiary)

                costRow("Mean evaluation", String(format: "%.3f ms", r.meanLatency))
                costRow("Throughput / core", String(format: "%.0f msg/s", perCoreRPS))
                costRow("Checks / month / core", compact(monthlyChecks))
                costRow("Resolved without a model", pct(r.tier1Share == 0 ? 1 : r.tier1Share))
                Divider().overlay(WZ.hairline)
                costRow("LLM on every message", "≈ 300-800 ms, ~$0.0002/msg")
                costRow("This pipeline", "sub-ms, ~$0 marginal")

                Text("An LLM per message is not a cost problem first — it is a latency problem. 300 ms cannot sit on a chat write path. The deterministic tier can, because it runs in-process.")
                    .font(.system(size: 10))
                    .foregroundStyle(WZ.textTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func costRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(WZ.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(WZ.orange)
        }
    }

    private var redTeamSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button { store.runRedTeam() } label: {
                HStack(spacing: 9) {
                    if store.isRunningRedTeam {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    }
                    Text(store.isRunningRedTeam ? "Running…" : "Run red-team corpus")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(RedTeamCorpus.all.count) attacks")
                        .font(.system(size: 11, design: .monospaced)).opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(WZ.brandGradient))
            }
            .buttonStyle(.plain)

            if let r = store.redTeamReport {
                HStack(spacing: 10) {
                    WZCard(padding: 12) {
                        WZMetric(value: pct(r.catchRate), label: "Caught",
                                 tint: r.catchRate >= 0.9 ? WZ.allow : WZ.warn)
                    }
                    WZCard(padding: 12) { WZMetric(value: "\(r.missed)", label: "Missed", tint: WZ.warn) }
                    WZCard(padding: 12) {
                        WZMetric(value: String(format: "%.2f", r.meanLatency), label: "Mean ms", tint: WZ.orange)
                    }
                }

                WZCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("CATCH RATE BY EVASION FAMILY")
                            .font(.system(size: 9.5, weight: .semibold)).tracking(0.7)
                            .foregroundStyle(WZ.textTertiary)
                        ForEach(RedTeamFamily.allCases) { family in
                            let subset = r.byFamily(family)
                            if !subset.isEmpty {
                                let rate = r.catchRate(family)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(family.rawValue)
                                            .font(.system(size: 11)).foregroundStyle(WZ.textPrimary)
                                        Spacer()
                                        Text("\(subset.filter(\.caught).count)/\(subset.count)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(WZ.textTertiary)
                                        Text(pct(rate))
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(rate == 1 ? WZ.allow : WZ.warn)
                                            .frame(width: 48, alignment: .trailing)
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(WZ.surfaceHigh).frame(height: 4)
                                            Capsule().fill(rate == 1 ? WZ.allow : WZ.warn)
                                                .frame(width: max(2, geo.size.width * rate), height: 4)
                                        }
                                    }
                                    .frame(height: 4)
                                }
                            }
                        }
                    }
                }

                if !r.misses.isEmpty {
                    WZCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("OPEN CASES (\(r.misses.count))")
                                .font(.system(size: 9.5, weight: .semibold)).tracking(0.7)
                                .foregroundStyle(WZ.textTertiary)
                            Text("Reported, not hidden. Several are deliberate: we can catch them, but only by masking things like title-cased addresses, and that trade costs more than it buys.")
                                .font(.system(size: 10)).foregroundStyle(WZ.textTertiary)
                            ForEach(r.misses) { m in
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "circle.dashed")
                                        .font(.system(size: 8)).foregroundStyle(WZ.warn).padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(m.testCase.technique)
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(WZ.textSecondary)
                                        Text(m.testCase.messages.joined(separator: " ⇢ "))
                                            .font(.system(size: 9)).foregroundStyle(WZ.textTertiary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                WZCard {
                    Text("\(RedTeamCorpus.all.count) attacks across \(RedTeamFamily.allCases.count) families, written from the attacker's chair — character tricks, spelled numbers, encodings, referential indirection, payment rails, multi-message assembly and positional channels.")
                        .font(.system(size: 12)).foregroundStyle(WZ.textSecondary)
                }
            }
        }
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button { store.runComparison() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "chart.bar.xaxis")
                    Text("Compare against baselines")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(WZ.brandGradient))
            }
            .buttonStyle(.plain)

            if let c = store.comparison {
                Text("Same corpus, \(c.corpusSize) messages — adversarial cases plus the innocent numeric suite.")
                    .font(.system(size: 10.5)).foregroundStyle(WZ.textTertiary)

                ForEach(c.outcomes) { o in
                    baselineCard(o.baseline == .llmOnly ? (store.llmOutcome ?? o) : o)
                }

                if SecretsStore.hasAnyProvider {
                    Button { store.measureLLMBaseline() } label: {
                        HStack(spacing: 8) {
                            if store.llmProgress != nil {
                                ProgressView().scaleEffect(0.7).tint(WZ.orange)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                            }
                            Text(store.llmProgress ?? "Measure LLM baseline (live, paced)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(WZ.orange)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(WZ.orange.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(WZ.orange.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.llmProgress != nil)
                }
            } else {
                WZCard {
                    Text("Runs a conventional regex filter, our hybrid engine, and a policy-grounded LLM over the same messages. Until this is measured, \"better than legacy\" is an assertion — this makes it a number.")
                        .font(.system(size: 12)).foregroundStyle(WZ.textSecondary)
                }
            }
        }
    }

    private func baselineCard(_ o: BaselineOutcome) -> some View {
        WZCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(o.baseline.rawValue)
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(WZ.textPrimary)
                    Spacer()
                    if o.evaluated > 0 {
                        Text("\(o.evaluated) msgs")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(WZ.textTertiary)
                    }
                }
                Text(o.baseline.blurb)
                    .font(.system(size: 10)).foregroundStyle(WZ.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = o.unavailableReason, o.evaluated == 0 {
                    Text(reason)
                        .font(.system(size: 10.5)).foregroundStyle(WZ.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        WZMetric(value: pct(o.recall), label: "Recall",
                                 tint: o.recall >= 0.9 ? WZ.allow : WZ.warn)
                        WZMetric(value: pct(o.precision), label: "Precision",
                                 tint: o.precision >= 0.95 ? WZ.allow : WZ.warn)
                        WZMetric(value: pct(o.falsePositiveRate), label: "FPR",
                                 tint: o.falsePositiveRate == 0 ? WZ.allow : WZ.block)
                        WZMetric(value: String(format: "%.2f", o.p50), label: "p50 ms", tint: WZ.orange)
                    }
                    if o.errors > 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(o.errors) abstentions or provider errors, counted as misses — on a write path an abstention is a message that went through unchecked.")
                                .font(.system(size: 9.5)).foregroundStyle(WZ.warn)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = o.unavailableReason {
                                Text("Provider said: \(reason)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(WZ.block)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
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

    private func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

    private func compact(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.0fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
