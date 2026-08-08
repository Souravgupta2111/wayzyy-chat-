// Harness: proves conversation-buffer isolation and thread safety under parallel load.

import Foundation
setvbuf(stdout, nil, _IONBF, 0)

let engine = ModerationEngine.shared
let threads = 12
let iterations = 250

print("=== 1. HAMMER: \(threads) threads x \(iterations) iterations ===")
do {
    let group = DispatchGroup()
    let errors = NSMutableArray()
    let errorLock = NSLock()
    let started = Date()

    for t in 0..<threads {
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            for i in 0..<iterations {
                let actor = ActorContext(
                    trust: .standard, stage: .inquiry,
                    conversationID: "thread-\(t)-conv-\(i % 7)", senderID: "s\(t)"
                )
                let text = i % 3 == 0
                    ? "call me on 98765 43210"
                    : (i % 3 == 1 ? "we are 4 adults and 2 kids" : "nine eight seven")
                let v = engine.evaluate(text, actor: actor, useConversationBuffer: true)
                if !v.action.withholdsMessage { engine.remember(text, actor: actor) }
                if i % 25 == 0 { engine.resetBuffer(actor: actor) }
                if v.maskedText.isEmpty && !text.isEmpty {
                    errorLock.lock(); errors.add("empty maskedText for '\(text)'"); errorLock.unlock()
                }
            }
        }
    }
    let done = group.wait(timeout: .now() + 120)
    let elapsed = Date().timeIntervalSince(started)
    if done == .timedOut {
        print("  FAULT  deadlocked or hung")
        exit(1)
    }
    print(String(format: "  ok     %d evaluations across %d threads in %.2f s (%.0f/s)",
                 threads * iterations, threads, elapsed,
                 Double(threads * iterations) / elapsed))
    if errors.count > 0 {
        print("  FAULT  \(errors.count) inconsistent verdicts")
        exit(1)
    }
    print("  ok     no inconsistent verdicts")
}

print("\n=== 2. CORRECTNESS UNDER CONCURRENCY ===")
do {
    let probe = "whatsapp me on 9876543210"
    let expected = engine.evaluate(
        probe,
        actor: ActorContext(trust: .standard, stage: .inquiry,
                            conversationID: "baseline", senderID: "s"),
        useConversationBuffer: false
    )
    let results = NSMutableArray()
    let lock = NSLock()
    let group = DispatchGroup()
    for t in 0..<threads {
        DispatchQueue.global().async(group: group) {
            for i in 0..<60 {
                let actor = ActorContext(trust: .standard, stage: .inquiry,
                                         conversationID: "c-\(t)-\(i)", senderID: "s")
                let v = engine.evaluate(probe, actor: actor, useConversationBuffer: false)
                lock.lock(); results.add(v.action.rawValue); lock.unlock()
            }
        }
    }
    _ = group.wait(timeout: .now() + 60)
    let distinct = Set(results.compactMap { $0 as? String })
    print("  baseline action: \(expected.action.rawValue)")
    print("  distinct actions across \(results.count) concurrent evaluations: \(distinct)")
    if distinct.count == 1, distinct.first == expected.action.rawValue {
        print("  ok     verdict is stable under concurrency")
    } else {
        print("  FAULT  verdict varies with concurrency")
        exit(1)
    }
}

print("\n=== 3. CONVERSATION ISOLATION ===")
do {
    let group = DispatchGroup()
    let leaked = NSMutableArray()
    let lock = NSLock()

    for round in 0..<40 {
        DispatchQueue.global().async(group: group) {
            let a = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "iso-a-\(round)", senderID: "alice")
            engine.resetBuffer(actor: a)
            for m in ["98765", "hello there"] {
                let v = engine.evaluate(m, actor: a, useConversationBuffer: true)
                engine.remember(m, actor: a)
                if v.action != .allow && v.action != .hint {
                    lock.lock(); leaked.add("alice-\(round): \(m) -> \(v.action.rawValue)"); lock.unlock()
                }
            }
        }
        DispatchQueue.global().async(group: group) {
            let b = ActorContext(trust: .standard, stage: .inquiry,
                                 conversationID: "iso-b-\(round)", senderID: "bob")
            engine.resetBuffer(actor: b)
            for m in ["43210", "thanks a lot"] {
                let v = engine.evaluate(m, actor: b, useConversationBuffer: true)
                engine.remember(m, actor: b)
                if v.action != .allow && v.action != .hint {
                    lock.lock(); leaked.add("bob-\(round): \(m) -> \(v.action.rawValue)"); lock.unlock()
                }
            }
        }
    }
    _ = group.wait(timeout: .now() + 60)
    if leaked.count == 0 {
        print("  ok     80 interleaved conversations, no cross-window assembly")
    } else {
        print("  FAULT  \(leaked.count) cross-conversation leaks:")
        for l in leaked.prefix(5) { print("           \(l)") }
        exit(1)
    }
}

print("\nALL CONCURRENCY CHECKS PASSED")
exit(0)
