// Harness: benchmarks Tier-3 models for accuracy, latency and cost.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let engine = ModerationEngine.shared

guard let key = SecretsStore.groq, !key.isEmpty else {
    print("no groq key configured"); exit(1)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }

enum Corpus: String { case wave1, wave2 }

struct Job {
    let corpus: Corpus
    let id: Int
    let family: String
    let messages: [String]
    let shouldFlag: Bool
    var label: String { "\(corpus == .wave1 ? "w1" : "w2") #\(id)" }
}

struct CorpusBaseline {
    let caught: Int
    let attacks: Int
}

func buildJobs() -> (jobs: [Job], baselines: [Corpus: CorpusBaseline]) {
    var jobs: [Job] = []
    let rt = RedTeamSuite.run()
    for m in rt.misses {
        jobs.append(Job(corpus: .wave1, id: m.testCase.id, family: "\(m.testCase.family)",
                        messages: m.testCase.messages.filter { !$0.isEmpty }, shouldFlag: true))
    }
    let w2 = RedTeamWave2Suite.run()
    for r in w2.attacks where r.escalated {
        jobs.append(Job(corpus: .wave2, id: r.testCase.id, family: r.testCase.family.rawValue,
                        messages: r.testCase.messages, shouldFlag: true))
    }
    for r in w2.innocents where r.costsCall {
        jobs.append(Job(corpus: .wave2, id: r.testCase.id, family: "INNOCENT",
                        messages: r.testCase.messages, shouldFlag: false))
    }
    return (jobs, [
        .wave1: CorpusBaseline(caught: rt.caught, attacks: rt.total),
        .wave2: CorpusBaseline(caught: w2.caught, attacks: w2.attacks.count),
    ])
}

struct Tally {
    var rescued: [Corpus: Int] = [:]
    var missed: [Corpus: Int] = [:]
    var innocentHeld = 0
    var innocentBroken = 0
    var abstained = 0
    var latencies: [Double] = []
    var brokenList: [String] = []
    var missedList: [String] = []
}

func configure(_ model: String) {
    var c = RemoteJudge.Configuration.groq(apiKey: key, model: model)
    c.breakerEnabled = false
    c.maxCallsPerMinute = 3_000
    c.maxCallsPerDay = 100_000
    c.timeout = 60
    engine.judge = RemoteJudge(configuration: c, allowModelFallback: false)
}

func run(_ model: String, _ jobs: [Job], verbose: Bool) async -> Tally {
    configure(model)
    var t = Tally()

    for (i, job) in jobs.enumerated() {
        let actor = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "t3-\(UUID().uuidString)", senderID: "s")
        engine.resetBuffer(actor: actor)

        var chosen: Verdict? = nil
        var chosenMessage = job.messages.last ?? ""
        for m in job.messages {
            let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
            if chosen == nil || (!v.suspicions.isEmpty && chosen!.suspicions.isEmpty) {
                chosen = v; chosenMessage = m
            }
            if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
        }
        guard let verdict = chosen, engine.shouldEscalate(verdict) else { continue }
        guard let (revised, j) = await engine.escalate(
            verdict: verdict, message: chosenMessage, actor: actor
        ) else { continue }
        t.latencies.append(j.latencyMs)

        var outcome = ""
        switch (job.shouldFlag, j.decision) {
        case (true, .exfiltration):
            if revised.action != .allow && revised.action != .hint {
                t.rescued[job.corpus, default: 0] += 1; outcome = "RESCUED"
            } else {
                t.missed[job.corpus, default: 0] += 1; outcome = "flagged, no action"
            }
        case (true, .benign):
            t.missed[job.corpus, default: 0] += 1; outcome = "benign"
            t.missedList.append("\(job.label) \(chosenMessage.prefix(58))")
        case (true, .abstain):
            t.missed[job.corpus, default: 0] += 1; t.abstained += 1; outcome = "ABSTAIN"
        case (false, .benign):
            t.innocentHeld += 1; outcome = "held"
        case (false, .exfiltration):
            t.innocentBroken += 1; outcome = "*** FALSE POSITIVE ***"
            t.brokenList.append("\(job.label) \(chosenMessage.prefix(58))")
        case (false, .abstain):
            t.innocentHeld += 1; t.abstained += 1; outcome = "abstain"
        }

        if verbose {
            print("[\(pad(String(i + 1), 3))] \(pad(job.label, 8)) \(pad(job.family, 26)) \(pad(j.decision.rawValue, 13)) \(String(format: "%5.0f", j.latencyMs))ms  \(outcome)")
        }
        try? await Task.sleep(nanoseconds: 5_500_000_000)
    }
    return t
}

func runPooled(_ jobs: [Job]) async -> Tally {
    guard let key = SecretsStore.groq else { return Tally() }
    let pool = PooledJudge(apiKey: key, models: RemoteJudge.Configuration.groqSchemaCompliantModels)
    engine.judge = pool

    struct Prepared {
        let job: Job
        let verdict: Verdict
        let message: String
        let actor: ActorContext
        let request: JudgeRequest
    }
    var prepared: [Prepared] = []
    for job in jobs {
        let actor = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "t3-\(UUID().uuidString)", senderID: "s")
        engine.resetBuffer(actor: actor)
        var chosen: Verdict? = nil
        var chosenMessage = job.messages.last ?? ""
        for m in job.messages {
            let v = engine.evaluate(m, actor: actor, useConversationBuffer: true)
            if chosen == nil || (!v.suspicions.isEmpty && chosen!.suspicions.isEmpty) {
                chosen = v; chosenMessage = m
            }
            if !v.action.withholdsMessage { engine.remember(m, actor: actor) }
        }
        guard let verdict = chosen, engine.shouldEscalate(verdict) else { continue }
        prepared.append(Prepared(
            job: job, verdict: verdict, message: chosenMessage, actor: actor,
            request: engine.judgeRequest(for: verdict, message: chosenMessage, actor: actor)
        ))
    }

    let started = Date()
    var judgements: [(Int, JudgeVerdict)] = []
    await withTaskGroup(of: (Int, JudgeVerdict).self) { group in
        var index = 0
        let limit = pool.laneCount
        func submit() {
            guard index < prepared.count else { return }
            let slot = index
            let request = prepared[slot].request
            index += 1
            group.addTask { (slot, await pool.judge(request)) }
        }
        let gapNanos = UInt64(1_000_000_000.0 / pool.sustainableCallsPerSecond)
        for _ in 0..<min(limit, prepared.count) {
            submit()
            try? await Task.sleep(nanoseconds: gapNanos)
        }
        while let r = await group.next() {
            judgements.append(r)
            try? await Task.sleep(nanoseconds: gapNanos)
            submit()
        }
    }
    let wall = Date().timeIntervalSince(started)

    var results: [(Job, JudgeVerdict, ModAction)] = []
    for (slot, judgement) in judgements.sorted(by: { $0.0 < $1.0 }) {
        let p = prepared[slot]
        let revised = engine.applyJudgement(
            judgement, to: p.verdict, message: p.message, actor: p.actor
        )
        results.append((p.job, judgement, revised.action))
    }

    var t = Tally()
    var failureReasons: [String] = []
    for (job, j, action) in results {
        t.latencies.append(j.latencyMs)
        switch (job.shouldFlag, j.decision) {
        case (true, .exfiltration):
            if action != .allow && action != .hint { t.rescued[job.corpus, default: 0] += 1 }
            else { t.missed[job.corpus, default: 0] += 1 }
        case (true, .benign):
            t.missed[job.corpus, default: 0] += 1
            t.missedList.append("\(job.label)")
        case (true, .abstain):
            t.missed[job.corpus, default: 0] += 1; t.abstained += 1
            failureReasons.append("\(job.label): \(j.rationale.prefix(110))")
        case (false, .benign): t.innocentHeld += 1
        case (false, .exfiltration):
            t.innocentBroken += 1; t.brokenList.append("\(job.label)")
        case (false, .abstain):
            t.innocentHeld += 1; t.abstained += 1
            failureReasons.append("\(job.label): \(j.rationale.prefix(110))")
        }
    }
    if !failureReasons.isEmpty {
        print("  failure reasons (\(failureReasons.count)):")
        for r in failureReasons.prefix(8) { print("    \(r)") }
    }
    print(String(format: "  pooled %d calls across %d lanes in %.1f s (%.1f calls/s)",
                 results.count, pool.laneCount, wall, Double(results.count) / max(wall, 0.001)))
    return t
}

func report(_ model: String, _ t: Tally, _ baselines: [Corpus: CorpusBaseline], _ jobs: [Job]) {
    print("")
    print("── \(model) ──")
    for corpus in [Corpus.wave1, .wave2] {
        guard let b = baselines[corpus] else { continue }
        let r = t.rescued[corpus] ?? 0
        let m = t.missed[corpus] ?? 0
        guard r + m > 0 else { continue }
        let end = Double(b.caught + r) / Double(b.attacks)
        print("  \(corpus.rawValue): escalated \(r + m), rescued \(r), missed \(m)")
        print("            deterministic \(pct(Double(b.caught) / Double(b.attacks))) → with T3 \(pct(end))")
    }
    let innocents = jobs.filter { !$0.shouldFlag }.count
    print("  innocents: \(t.innocentHeld)/\(innocents) held, \(t.innocentBroken) broken")
    print("  abstentions: \(t.abstained)")
    if !t.latencies.isEmpty {
        let s = t.latencies.sorted()
        print(String(format: "  latency p50/p95: %.0f / %.0f ms", s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))]))
    }
    if !t.brokenList.isEmpty {
        print("  FALSE POSITIVES:")
        for b in t.brokenList { print("    \(b)") }
    }
    if !t.missedList.isEmpty {
        print("  called benign:")
        for m in t.missedList { print("    \(m)") }
    }
}

let args = Array(CommandLine.arguments.dropFirst())

Task {
    if args.first == "--baseline" {
        let model = args.count > 1 ? args[1] : "openai/gpt-oss-safeguard-20b"
        configure(model)
        print("=== LLM-ONLY BASELINE — \(model) ===")
        let outcome = await BaselineComparison.measureLLM(
            sampleSize: 240,
            progress: { done, total in
                if done % 10 == 0 { print("  \(done)/\(total)") }
            }
        )
        print("")
        if let reason = outcome.unavailableReason {
            print("unavailable: \(reason)")
        } else {
            print("  evaluated : \(outcome.evaluated)")
            print("  recall    : \(pct(outcome.recall))")
            print("  precision : \(pct(outcome.precision))")
            print("  FPR       : \(pct(outcome.falsePositiveRate))")
            print(String(format: "  p50       : %.0f ms", outcome.p50))
            print("  errors    : \(outcome.errors)")
        }
        exit(0)
    }

    let (jobs, baselines) = buildJobs()

    if args.first == "--pool" {
        print("=== LIVE TIER 3, POOLED ===")
        print("jobs: \(jobs.count)  (\(jobs.filter(\.shouldFlag).count) attacks, \(jobs.filter { !$0.shouldFlag }.count) innocent)")
        let t = await runPooled(jobs)
        report("pool", t, baselines, jobs)
        exit(0)
    }

    let models: [String]
    if args.first == "--compare" {
        models = Array(args.dropFirst())
    } else if let m = args.first {
        models = [m]
    } else {
        models = ["openai/gpt-oss-safeguard-20b"]
    }

    print("=== LIVE TIER 3 ===")
    print("jobs: \(jobs.count)  (\(jobs.filter(\.shouldFlag).count) attacks, \(jobs.filter { !$0.shouldFlag }.count) innocent)")
    print("models: \(models.joined(separator: ", "))")

    for model in models {
        let t = await run(model, jobs, verbose: models.count == 1)
        report(model, t, baselines, jobs)
    }
    exit(0)
}

dispatchMain()
