#!/usr/bin/env python3
"""Strip Swift comments using a real lexer, then add one header line per file.

A regex-based stripper corrupts this codebase. It contains raw-string regex
literals such as #"\\b(?:or\\s+else)"# and URL literals such as
"http://127.0.0.1:8080/classify" — a naive //-remover truncates that URL to
"http: and the project stops compiling.

So this scanner tracks lexical state: regular strings with escapes, triple-quoted
multiline strings, raw strings with any number of # delimiters, raw multiline
strings, and nested /* /* */ */ block comments (Swift allows nesting).

Newlines inside block comments are preserved during the scan so the output has
exactly the same line count as the input. That lets each line be compared with
its original: a line that becomes empty but was not empty before was a
comment-only line and is dropped entirely.

Usage:
  strip_comments.py --dry-run
  strip_comments.py --apply
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# One-line headers. Anything not listed falls back to a name-derived sentence.
HEADERS = {
    "Package.swift": "SwiftPM manifest: the moderation engine as a portable library plus a thin HTTP service target.",

    "WayzyyChat/WayzyyChatApp.swift": "App entry point.",
    "WayzyyChat/Theme/Theme.swift": "Colours, typography and spacing tokens shared by every view.",

    "WayzyyChat/Models/ChatStore.swift": "Observable chat state: send path, delivery status, provisional holds, background escalation and the moderation queue.",
    "WayzyyChat/Models/ChatPersistence.swift": "JSON persistence for conversations; stores original text only and re-derives verdicts on load.",

    "WayzyyChat/Moderation/ModerationEngine.swift": "Orchestrates the tiers: canonicalisation, extraction, retrieval, safety classification, fusion, policy, routing and Tier-3 revision.",
    "WayzyyChat/Moderation/ModerationTypes.swift": "Core value types: Detection, Verdict, ModAction, ModCategory, ActorContext and supporting enums.",
    "WayzyyChat/Moderation/Canonicalizer.swift": "Builds offset-preserving character views of a message so a detection can be mapped back to the original span.",
    "WayzyyChat/Moderation/Extractors.swift": "Deterministic extraction of phones, emails, URLs, social handles, payment rails and encoded carriers.",
    "WayzyyChat/Moderation/Lexicons.swift": "Static vocabulary: platforms, TLDs, payment suffixes, profanity, person and property targets, stoplists.",
    "WayzyyChat/Moderation/NumericContext.swift": "Classifies what a number means — price, time, booking reference, dimension — so legitimate digits are not masked.",
    "WayzyyChat/Moderation/PositionalChannels.swift": "Decodes covert positional carriers such as acrostics, word-length runs and list-index digits.",
    "WayzyyChat/Moderation/Scorer.swift": "Logistic fusion of contact-exfiltration features into one score with per-feature contributions.",
    "WayzyyChat/Moderation/Policy.swift": "Versioned policy configuration: thresholds, trust and stage offsets, the enforcement ladder and safety overrides.",
    "WayzyyChat/Moderation/SafetyRules.swift": "Deterministic safety floor for threats, harassment, sexual content, self-harm, scams and brand impersonation.",
    "WayzyyChat/Moderation/SafetyClassifier.swift": "Layer 3 contract: multi-label safety heads, calibration bands, the signal-derived default and a remote backend.",
    "WayzyyChat/Moderation/SemanticRetrieval.swift": "Tier 2 nearest-neighbour retrieval over labelled anchors with separate positive and innocent poles.",
    "WayzyyChat/Moderation/IntentExemplars.swift": "The labelled anchor corpus: contact, safety and innocent exemplars used by retrieval.",
    "WayzyyChat/Moderation/EmbeddingVectoriser.swift": "Optional embedding backend for retrieval, with degradation to the lexical vector space.",
    "WayzyyChat/Moderation/Escalation.swift": "The router: vocabulary-free structural suspicions that decide what Tier 3 is asked about.",
    "WayzyyChat/Moderation/ActorSignals.swift": "Actor and behavioural signals over a 24-hour window: velocity, fan-out, reports and sub-threshold safety patterns.",
    "WayzyyChat/Moderation/ConversationBuffers.swift": "Bounded, locked per-conversation message windows used for cross-message assembly.",
    "WayzyyChat/Moderation/SemanticJudge.swift": "Tier 3 judge contract with an offline fixture and a remote model client carrying budgets, a circuit breaker and prompt sanitisation.",
    "WayzyyChat/Moderation/PooledJudge.swift": "Fans Tier-3 requests across several judges to raise effective throughput.",
    "WayzyyChat/Moderation/SecretsStore.swift": "Loads provider credentials from Secrets.json or the environment.",
    "WayzyyChat/Moderation/Baselines.swift": "Regex-only and hybrid baselines used to measure what each tier actually adds.",
    "WayzyyChat/Moderation/RedTeamSuite.swift": "The primary adversarial corpus with expected outcomes per case.",
    "WayzyyChat/Moderation/RedTeamWave2.swift": "Second adversarial wave: obfuscation families found after the first suite was passing.",
    "WayzyyChat/Moderation/AdversarialSuite.swift": "Attack-family definitions and grading used by the adversarial harnesses.",
    "WayzyyChat/Moderation/AdversarialLoop.swift": "Generates and grades new attack variants against the engine.",

    "WayzyyChat/Views/RootView.swift": "Root tab container.",
    "WayzyyChat/Views/ChatListView.swift": "Conversation list.",
    "WayzyyChat/Views/ChatView.swift": "Message thread with composer, live hints and delivery status.",
    "WayzyyChat/Views/MessageBubble.swift": "Renders one message, applying the verdict at display time.",
    "WayzyyChat/Views/InspectorView.swift": "Shows the verdict behind a message: detections, reason codes, features and timings.",
    "WayzyyChat/Views/LabView.swift": "Interactive harness for probing the engine with arbitrary text.",
    "WayzyyChat/Views/OpsView.swift": "Moderation queue and Tier-3 operational state.",
    "WayzyyChat/Views/NewChatSheet.swift": "Sheet for starting a conversation with a chosen trust tier and booking stage.",
}

TOOL_HEADERS = {
    "audit": "Harness: performance and memory audit of the engine's hot paths.",
    "calibrate": "Harness: sweeps retrieval similarity and margin thresholds against the corpus.",
    "concurrency": "Harness: proves conversation-buffer isolation and thread safety under parallel load.",
    "diag": "Harness: prints the full verdict for one or more messages.",
    "dumpcorpus": "Harness: exports the anchor and adversarial corpora.",
    "embcompare": "Harness: compares lexical and embedding retrieval backends.",
    "embcorpus": "Harness: scores the embedding backend over the corpus.",
    "finalrun": "Harness: end-to-end run reporting recall, precision and false positives.",
    "fullpipeline": "Harness: measures every tier over the production-shaped corpus.",
    "fuzzprobe": "Harness: fuzzes innocent sentences looking for false positives.",
    "hybridonly": "Harness: measures the Tier 1 plus Tier 2 configuration alone.",
    "metrics": "Harness: the headline regression metrics used by verify.sh.",
    "portcheck": "Harness: checks the engine builds and behaves without Apple frameworks.",
    "probes": "Harness: targeted behavioural probes for individual engine guarantees.",
    "profile": "Harness: times each stage of the write path.",
    "promptsize": "Harness: measures the Tier-3 prompt size for a representative request.",
    "tier3": "Harness: benchmarks Tier-3 models for accuracy, latency and cost.",
    "tradeoff": "Harness: computes the recall-versus-escalation-cost curve.",
    "traffic": "Harness: replays ordinary traffic to measure throughput and tier share.",
    "wave2": "Harness: runs the second adversarial wave.",
}

VERIFY_HEADERS = {
    ".verify/blind/blind.swift": "Harness: realistic-prevalence run over 45 benign and 5 faulty messages, end to end including Tier 3.",
    ".verify/safety-audit.swift": "Harness: multilingual safety audit plus a forced provider outage, end to end through Tier 3.",
    ".verify/stats/main.swift": "Harness: tier share, latency percentiles, throughput and corpus inventory.",
    ".verify/ctx/policy/main.swift": "Harness: proves policy is versioned configuration and that its two invariants cannot be configured away.",
    ".verify/ctx/layer6src/main.swift": "Harness: proves the actor and behavioural signal guarantees, including complaint exclusion.",
    ".verify/ctx/handlesrc/main.swift": "Harness: 30 handle-sharing phrasings that must act and 20 controls that must not.",
}


def strip(src: str) -> str:
    """Remove comments, preserving line count. Returns text with same newlines."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]

        # Raw string: one or more '#' then '"' or '"""'.
        if c == "#":
            j = i
            while j < n and src[j] == "#":
                j += 1
            hashes = j - i
            if j < n and src[j] == '"':
                if src.startswith('"""', j):
                    close = '"""' + "#" * hashes
                    k = src.find(close, j + 3)
                    k = n if k < 0 else k + len(close)
                else:
                    close = '"' + "#" * hashes
                    k = src.find(close, j + 1)
                    k = n if k < 0 else k + len(close)
                out.append(src[i:k])
                i = k
                continue
            # Compiler directive such as #if / #available.
            out.append(src[i:j])
            i = j
            continue

        # Multiline string.
        if src.startswith('"""', i):
            k = src.find('"""', i + 3)
            k = n if k < 0 else k + 3
            out.append(src[i:k])
            i = k
            continue

        # Regular string with escapes.
        if c == '"':
            k = i + 1
            while k < n:
                if src[k] == "\\":
                    k += 2
                    continue
                if src[k] == '"':
                    k += 1
                    break
                if src[k] == "\n":
                    break
                k += 1
            out.append(src[i:k])
            i = k
            continue

        # Line comment: stop before the newline so line count is unchanged.
        if src.startswith("//", i):
            k = src.find("\n", i)
            i = n if k < 0 else k
            continue

        # Block comment, nesting. Keep its newlines.
        if src.startswith("/*", i):
            depth, k = 1, i + 2
            while k < n and depth:
                if src.startswith("/*", k):
                    depth += 1
                    k += 2
                elif src.startswith("*/", k):
                    depth -= 1
                    k += 2
                else:
                    k += 1
            out.append("\n" * src.count("\n", i, k))
            i = k
            continue

        out.append(c)
        i += 1
    return "".join(out)


def header_for(rel: str) -> str:
    if rel in HEADERS:
        return HEADERS[rel]
    if rel in VERIFY_HEADERS:
        return VERIFY_HEADERS[rel]
    m = re.match(r"tools/([^/]+)/main\.swift$", rel)
    if m and m.group(1) in TOOL_HEADERS:
        return TOOL_HEADERS[m.group(1)]
    name = os.path.splitext(os.path.basename(rel))[0]
    return f"{name}."


def process(path: str, rel: str):
    original = open(path, encoding="utf-8").read()
    cleaned = strip(original)

    o_lines = original.split("\n")
    c_lines = cleaned.split("\n")
    if len(o_lines) != len(c_lines):
        raise RuntimeError(f"line count drift in {rel}")

    kept = []
    for o, c in zip(o_lines, c_lines):
        s = c.rstrip()
        if not s and o.strip():
            continue  # was a comment-only line
        kept.append(s)

    # Collapse runs of blank lines and trim the ends.
    body = []
    blanks = 0
    for line in kept:
        if line:
            blanks = 0
            body.append(line)
        else:
            blanks += 1
            if blanks == 1:
                body.append("")
    while body and not body[0]:
        body.pop(0)
    while body and not body[-1]:
        body.pop()

    tools_version = ""
    for line in o_lines[:3]:
        if "swift-tools-version" in line:
            tools_version = line.strip() + "\n"
            break

    text = tools_version + f"// {header_for(rel)}\n\n" + "\n".join(body) + "\n"

    # Safety invariants: no literal may be lost.
    for token in ('"http', '#"', '"""'):
        if original.count(token) != text.count(token):
            raise RuntimeError(
                f"{rel}: literal count changed for {token!r} "
                f"({original.count(token)} -> {text.count(token)})"
            )
    return original, text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    targets = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in {".build", "DerivedData", "build"}]
        for fn in filenames:
            if fn.endswith(".swift"):
                full = os.path.join(dirpath, fn)
                targets.append((full, os.path.relpath(full, ROOT)))
    targets.sort(key=lambda t: t[1])

    before = after = 0
    failures = []
    for full, rel in targets:
        try:
            original, text = process(full, rel)
        except RuntimeError as e:
            failures.append(str(e))
            continue
        b, a = len(original.split("\n")), len(text.split("\n"))
        before += b
        after += a
        if args.apply:
            open(full, "w", encoding="utf-8").write(text)
        else:
            print(f"{rel:58s} {b:5d} -> {a:5d}")

    print()
    print(f"files   : {len(targets)}")
    print(f"lines   : {before} -> {after}  ({before - after} removed, "
          f"{100.0 * (before - after) / max(before, 1):.1f}%)")
    if failures:
        print(f"\nBLOCKED ({len(failures)}):")
        for f in failures:
            print("  " + f)
        return 1
    print("all literal-preservation checks passed")
    print("APPLIED" if args.apply else "dry run only — nothing written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
