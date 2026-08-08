# Wayzyy Chat Moderation

A moderation engine for rental-marketplace chat. It does two different jobs at once:

- **Contact exfiltration** — hosts and guests trying to move a booking off-platform by sharing a phone number, email, social handle or payment rail, usually obfuscated.
- **Safety** — threats, harassment, sexual content, coercion, scams and self-harm, across English, romanised Hindi and native scripts.

Those two problems need opposite instincts. Off-platform steering is mostly a structured-data problem and can be masked span by span. Abuse is a semantic problem and needs judgement. Most of the design follows from keeping them separate.

The engine is **9,815 lines across 25 files and imports nothing but Foundation** — no UIKit, no SwiftUI, no `@MainActor`. It is a pure function of `(text, conversation window, actor context)`, which is what makes it runnable in an iOS app, a Linux service or a CLI harness without a reimplementation.

---

## How it works

```
message + actor context
        │
        ▼
Tier 0   13 canonical views, each preserving offsets back to the original
         Unicode folding, homoglyphs, hidden characters, number words,
         separators, reversal, acrostics, leet
        │
        ▼
Tier 1   deterministic extraction — phones (numbering-plan validated),
         emails, URLs, social handles, UPI/bank/crypto rails,
         encoded and positional carriers, plus a safety phrase floor
        │
        ▼
Tier 2   lexical nearest-neighbour retrieval over 336 labelled anchors,
         with a margin test against an innocent pole
        │
        ▼
Layer 3  multi-label safety classifier — 7 independent sigmoid heads,
         three calibrated bands: allow / route / enforce
        │
        ▼
Fusion   logistic scoring of contact evidence, then versioned policy
         picks an action with thresholds adjusted for trust and stage
        │
        ▼
Router   vocabulary-free structural suspicions. Raises questions only —
         it can never create a finding or enforce on its own
        │
        ▼
VERDICT RETURNED — p50 ~3.4 ms  ·  message delivers
─────────────────────────────────────────────────────── everything below is async
        │
Tier 3   model adjudication for routed messages (~1.7 s), off the
         delivery path, then re-run through the same policy
```

Nothing above the line touches the network. A model-provider outage cannot stop chat from working.

### Design decisions worth knowing

**Sigmoid heads, not softmax.** A message can be a threat *and* sexual harassment simultaneously. Softmax forces seven scores to sum to 1, so two true labels have to divide one unit of belief and one gets lost. Seven independent sigmoids don't compete.

**A positive `legitimateComplaint` head.** Six heads tell you what's wrong; the seventh says "this is an angry customer exercising a right." Without it, innocence is inferred from the *absence* of bad signals, which is fragile — and the failure is invisible, because nobody files a ticket saying "my complaint was softened." It acts as a veto and also excludes a message from behavioural pattern counting, so a guest complaining five times about a genuinely bad stay never accumulates a harassment pattern.

**Innocent anchors are load-bearing.** 125 of the 336 retrieval anchors are innocent examples. They exist so ordinary booking language, angry complaints and code-mixed Hindi have something to win with, rather than losing to whichever attack anchor shares a word.

**Numeric context before masking.** `12,500 for 3 nights`, `WZ4471829`, `27AAPFU0939F1ZV`, `flight AI 2109 lands 14:35` all stay untouched. A system that masks prices makes hosts abandon chat, so the digit path asks what a number *means* before acting on it.

**Routing is not enforcement.** The router answers three structural questions — is a person addressed, does this resemble anything normal here, is there a conditional — and none require knowing the vocabulary. `mai tumhe mar dunga` is in no list in this repository; it routes because it points at a person and looks unlike ordinary booking chat. A word we didn't predict means *ask*, not *allow*.

**Prediction is separate from policy.** Rules, retrieval and the classifier emit evidence. A single versioned `Policy.Configuration` decides the action, and its version is stamped on the verdict so an appeal weeks later can be judged against the rules that actually applied.

**Two invariants live in code and cannot be configured away.** Self-harm can never block. The advisory (live-typing) pass can never enforce.

---

## Measured results

Single core, Apple M1 Pro. Reproduce with `./verify.sh`.

| | |
|---|---|
| Recall / precision, regression corpus | **100% / 100%** |
| False positives, regression innocents | **0 of 41 (0.00%)** |
| False positives, adversarial wave 2 | **0 of 35** |
| Overall catch rate | 95.5% |
| Decided by Tiers 1+2, no model | 73 of 119 (61.3%) |
| Tier 1 alone decides | 94.7% of traffic |
| Write-path latency, ordinary traffic | **p50 3.24 ms · p95 4.67 ms · p99 5.25 ms** |
| Throughput | 285–302 msg/s per core |
| Coverage ceiling | 91.6% |
| Known silent misses | 10, each with the gate that lets it through |

Multilingual safety, end to end through Tier 3 with `llama3.1:8b`: **18 of 18** unseen cases across English, romanised Hindi, Devanagari and Cyrillic, with zero false positives on six controls, plus a forced-outage case that correctly fails closed to human review.

A realistic-prevalence run of 45 benign and 5 faulty messages — written after the engine was frozen, and covering angry complaints, romanised Hindi, digit carriers and platform names — produced **0 false positives** and caught 4 of 5. The miss was a romanised-Hindi threat that routed correctly and was then called benign by the 8B judge.

### Reading these numbers honestly

The regression and adversarial corpora shaped this engine's rules, anchors and thresholds. They are strong evidence that known attacks stay caught; they are **not** an estimate of production error on live traffic. `0 of 41` is zero on that control set, not a zero-percent population false-positive rate — with no errors in 41 samples the rough 95% upper bound is still about 7%.

The 50-case prevalence run was genuinely held out when written, but two of its failures caused code changes, so it is now a regression set too and is reported as one.

---

## Layout

```
WayzyyChat/Moderation/     the engine — Foundation only, portable
  Canonicalizer.swift      offset-preserving views
  Extractors.swift         phones, emails, URLs, handles, payment rails
  Lexicons.swift           static vocabulary
  NumericContext.swift     what a number means
  PositionalChannels.swift acrostics, word-length runs
  SemanticRetrieval.swift  Tier 2 kNN
  IntentExemplars.swift    the 336 labelled anchors
  SafetyRules.swift        deterministic safety floor
  SafetyClassifier.swift   Layer 3 heads and bands
  Escalation.swift         the router
  ActorSignals.swift       behavioural signals over 24 h
  Scorer.swift             logistic fusion
  Policy.swift             versioned thresholds and the action ladder
  SemanticJudge.swift      Tier 3 client, budgets, breaker, sanitisation
  RedTeamSuite.swift       adversarial corpora
  RedTeamWave2.swift

WayzyyChat/Views/          SwiftUI demo app with a verdict inspector
tools/                     measurement harnesses
.verify/                   harness sources (binaries gitignored)
verify.sh                  the suite, with invariants that must hold
Package.swift              engine as a library + HTTP service target
```

---

## Running it

Requires a Swift toolchain. No package dependencies for the engine itself.

```bash
# full suite: metrics, adversarial waves, probes, fuzzing, invariants
./verify.sh

# inspect the verdict for any message
swiftc -swift-version 5 -O -o .verify/diag \
  WayzyyChat/Moderation/*.swift tools/diag/main.swift
./.verify/diag "call me on 98765 43210"
./.verify/diag "total is 12,500 for 3 nights"

# tier share, latency percentiles, throughput, corpus inventory
swiftc -swift-version 5 -O -o .verify/stats/tierstats \
  WayzyyChat/Moderation/*.swift .verify/stats/main.swift
./.verify/stats/tierstats
```

`verify.sh` fails if any invariant breaks: regression false-positive rate above zero, recall below 100%, or any wave-2 false positive.

### Tier 3 (optional)

Tier 3 is **off by default** and the engine runs fully on Tiers 0–2 without it. To enable live adjudication, copy `Secrets.example.json` to `Secrets.json` and add a key — Groq and Gemini both have free tiers. With no key the judge falls back to recorded fixtures, so nothing breaks.

For a fully local setup, point it at Ollama:

```bash
ollama serve
ollama pull llama3.1:8b
```

---

## Status

Built and measured:

- Tiers 0–2 in full, with the corpora and harnesses above
- The Layer 3 classifier contract, calibration bands and both backends
- Versioned policy, the router, actor signals, provisional holds for critical severity
- Tier 3 client with budgets, a circuit breaker, prompt sanitisation and abstention handling

Not built yet, and named here so nothing is implied:

- **The trained multilingual classifier.** Layer 3's contract and bands are live on every message, but the resident implementation is signal-derived from existing deterministic and retrieval signals, not a trained model. It is deliberately allowed to route and not to enforce, because it has never been swept against a labelled corpus. Trained weights slot in behind the same protocol.
- **A server-side authority boundary.** Moderation currently runs in the client, which makes it advisory rather than enforceable. This is the next architectural step.
- **Durable review and appeals.** The moderation queue is in-memory and does not survive a restart.
- **URL reputation.** External links are parsed and classified structurally, but not checked against a live phishing/malware feed.
