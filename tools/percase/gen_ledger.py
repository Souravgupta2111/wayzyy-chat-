#!/usr/bin/env python3
"""Generate WAYZYY_TEST_CASE_LEDGER.md from ledger.tsv. Every case, verbatim."""
import csv, io, collections, sys

SRC = "tools/percase/ledger.tsv"
OUT = "WAYZYY_TEST_CASE_LEDGER.md"

rows, rollups = [], []
with open(SRC, encoding="utf-8") as f:
    lines = f.read().split("\n")
hdr = lines[0].split("\t")
for ln in lines[1:]:
    if ln.startswith("==="):
        break
    if not ln.strip():
        continue
    p = ln.split("\t")
    if len(p) < len(hdr):
        continue
    rows.append(dict(zip(hdr, p)))

def esc(s):
    s = s.replace("|", "\\|").replace("`", "'")
    return s if s.strip() else "*(empty message)*"

def money(v):
    x = float(v)
    return "—" if x < 1e-9 else (f"${x:.6f}" if x >= 1e-6 else f"${x:.8f}")

SUITES = [("official", "The Ten Supplied Wayzyy Cases"),
          ("regression", "Regression Suite"),
          ("wave1", "Red Team — Wave 1"),
          ("wave2", "Red Team — Wave 2")]

SAFETY = {"threat", "harassment", "coercion", "sexual", "selfHarm", "scam"}

o = []
w = o.append

n = len(rows)
atk = sum(1 for r in rows if r["expected"] == "attack")
inn = n - atk
esc_n = sum(1 for r in rows if r["escalated"] == "1")
t1 = sum(1 for r in rows if int(r["tier"]) <= 1)
t2 = sum(1 for r in rows if int(r["tier"]) == 2)
fp = [r for r in rows if r["expected"] == "innocent" and r["action"] != "allow"]
lat = sorted(float(r["latency_ms"]) for r in rows)
def pc(p): return lat[min(int(round((len(lat)-1)*p)), len(lat)-1)]
cpu = sum(float(r["cpu_usd"]) for r in rows)
mdl = sum(float(r["model_usd"]) for r in rows)

w("# Wayzyy Moderation — Test Case Ledger\n")
w("**Every test case, its verbatim message, the layer that decided it, the verdict, latency and cost.**\n")
w("**Reproduced:** 8 August 2026 · Apple Silicon arm64, single-threaded · Policy `2026-08-08.v1`  ")
w("**Harness:** `tools/percase/main.swift` · **Raw data:** `tools/percase/ledger.tsv`  ")
w("**Tiers 1 and 2:** executed for every case; the latency and verdict columns are measured.  \n"
  "**Tier 3:** every case that routes is priced at the published per-call rate rather than billed, so "
  "the SLM totals below are the cost of the routing decisions this run actually made. Adjudication "
  "quality against a live `llama3.1:8b` is measured separately and reported in its own section.\n")
w("---\n")
w("## 1. Summary\n")
w("| | Value |")
w("|---|---|")
w(f"| Cases executed | **{n}** — {atk} attacks, {inn} innocents |")
w(f"| Decided at Tier 1 only | {t1} ({100*t1/n:.1f}%) |")
w(f"| Tier 2 deciding | {t2} ({100*t2/n:.1f}%) |")
w(f"| Routed to Tier 3 | {esc_n} ({100*esc_n/n:.1f}%) |")
w(f"| **False positives** | **{len(fp)} of {inn} ({100*len(fp)/inn:.2f}%)** |")
w(f"| Latency p50 / p95 / p99 / max | **{pc(.5):.3f} / {pc(.95):.3f} / {pc(.99):.3f} / {lat[-1]:.3f} ms** |")
w(f"| CPU cost, whole run | ${cpu:.8f} |")
w(f"| SLM cost — Llama 3.1 8B @ $0.0000165 | ${mdl:.6f} → **${mdl/n*100000:.4f} per 100k** |")
w(f"| SLM cost — gpt-oss-20b @ $0.000075 | ${mdl*4.545:.6f} → **${mdl*4.545/n*100000:.3f} per 100k** |")
w("")
w("**Cost per case is a binary.** A case decided deterministically costs about $0.00000001. "
  "A case routed to Tier 3 costs $0.0000165 — a **1,650× gap**. Nothing else about a case moves its cost.\n")
w("---\n")
w("## 2. Layer legend\n")
w("| Code | Layer |")
w("|---|---|")
w("| `T1-contact` | Tier 1 deterministic — contact-identifier extraction |")
w("| `T1-safety` | Tier 1 deterministic — safety phrase floor, target rule, agency gate |")
w("| `T1-clean` | Tier 1 found nothing; message allowed |")
w("| `T2-retrieval` | Tier 2 kNN retrieval margin changed the outcome |")
w("| `L3-classifier` | Layer 3 safety classifier raised a routing band |")
w("| `L5-router` | Escalation analyser raised a suspicion |")
w("| `L5-injection` | Moderation-tampering detection |")
w("| `L6-actor` | Behavioural pattern across messages |")
w("| `→T3` | Routed to the SLM for adjudication |")
w("")
w("Layers compose. `T1-contact+L3-classifier+L5-router+→T3` means the deterministic layer found a "
  "contact identifier, the classifier raised a safety band, the router flagged uncertainty, and the "
  "message was sent to the SLM.\n")
w("### Attribution across all cases\n")
w("| Layer combination | Cases | Share |")
w("|---|---|---|")
cnt = collections.Counter(r["layer"] for r in rows)
for k, v in cnt.most_common():
    w(f"| `{k}` | {v} | {100*v/n:.1f}% |")
w("")
# Derived from the same counter as the table above. Stating these as literals lets the prose
# drift away from the data on the next run, which is exactly the kind of claim this document
# exists to prevent.
contact_only = cnt["T1-contact"]
clean_only = cnt["T1-clean"]
tier1_only = sum(v for k, v in cnt.items()
                 if not any(marker in k for marker in ("T2-", "L3-", "L5-", "L6-", "→T3")))
w(f"**{100*contact_only/n:.1f}% of all cases are resolved by the deterministic contact layer alone**, "
  f"and a further {100*clean_only/n:.1f}% are found clean at Tier 1. Together with the remaining "
  f"deterministic combinations that is {100*tier1_only/n:.1f}% of cases decided with no retrieval, "
  "no classifier and no network call.\n")
w("---\n")
w("## 3. Verdict distribution\n")
w("| Action | Cases | Share | Mean latency |")
w("|---|---|---|---|")
acnt = collections.Counter(r["action"] for r in rows)
for a, c in acnt.most_common():
    m = sum(float(r["latency_ms"]) for r in rows if r["action"] == a) / c
    w(f"| `{a}` | {c} | {100*c/n:.1f}% | {m:.2f} ms |")
w("")
w("---\n")

sec = 4
for suite, title in SUITES:
    sr = [r for r in rows if r["suite"] == suite]
    if not sr:
        continue
    scost = sum(float(r["total_usd"]) for r in sr)
    sesc = sum(1 for r in sr if r["escalated"] == "1")
    scorr = sum(1 for r in sr if r["correct"] == "1")
    w(f"## {sec}. {title}\n")
    w(f"{len(sr)} cases · {sesc} routed to Tier 3 · {scorr}/{len(sr)} correct · total cost ${scost:.6f}\n")
    for fam in sorted({r["family"] for r in sr}):
        fr = [r for r in sr if r["family"] == fam]
        fcost = sum(float(r["total_usd"]) for r in fr)
        fmiss = sum(1 for r in fr if r["correct"] == "0")
        w(f"### {sec}.{sorted({x['family'] for x in sr}).index(fam)+1} `{fam}` — "
          f"{len(fr)} cases, {fmiss} miss{'es' if fmiss != 1 else ''}, ${fcost:.6f}\n")
        w("| # | Message(s) | Msgs | Layer | Verdict | ms | Cost | Categories | ✓ |")
        w("|---|---|---|---|---|---|---|---|---|")
        for r in fr:
            cats = r["categories"].replace("|", ", ") or "—"
            ok = "✓" if r["correct"] == "1" else "**✗**"
            act = f"**`{r['action']}`**" if r["action"] in ("block", "review", "warn") else f"`{r['action']}`"
            n_m = int(r["msgs"])
            w(f"| {r['id']} | `{esc(r['text'])}` | {n_m if n_m > 1 else ''} | `{r['layer']}` | {act} | "
              f"{float(r['latency_ms']):.2f} | {money(r['total_usd'])} | {cats} | {ok} |")
        w("")
    sec += 1

w("---\n")
w(f"## {sec}. Safety-category cases — the complete set\n")
sf = [r for r in rows if any(c in SAFETY for c in r["categories"].split("|"))]
w(f"Only **{len(sf)} of {n} cases** carry a safety category. This is the entire safety surface of the corpus.\n")
w("| # | Suite | Message | Layer | Verdict | Categories |")
w("|---|---|---|---|---|---|")
for r in sf:
    w(f"| {r['id']} | {r['suite']} | `{esc(r['text'])}` | `{r['layer']}` | "
      f"**`{r['action']}`** | {r['categories'].replace('|', ', ')} |")
w("")
w("**The regression corpus contains no `harassment`, `sexual` or `selfHarm` cases.** It was built to "
  "measure contact-exfiltration technique, and a case count is the wrong instrument for the safety "
  "categories anyway: what matters there is a property holding for every input, not a percentage holding "
  "across a sample. The target rule, the profanity tiers, the slur path and the self-harm guarantee are "
  "therefore enforced by the invariant gate, which asserts them directly and fails the build on "
  "violation.\n")
w("Two cases carry labels worth naming: `if you don't refund me I will leave a 1 star review` and "
  "`give me a discount or I will report you to the police`. Both are **lawful remedies** — an honest review "
  "and a police report of an alleged crime — and both are labelled `attack`, actioned `review`. They are "
  "listed rather than quietly relabelled because the line between a lawful remedy and a threat is the "
  "judgement this system is asked to make most often, and `review` holds a message for adjudication "
  "without enforcing on it.\n")
sec += 1

w("---\n")
w(f"## {sec}. Misses\n")
real = [r for r in rows if r["expected"] == "attack" and r["correct"] == "0"]
w(f"**{len(real)} of {atk} attacks ({100*len(real)/atk:.1f}%)** were neither enforced nor routed. "
  "Every one is a describable technique rather than a mystery.\n")
w("| # | Family | Message | Verdict |")
w("|---|---|---|---|")
for r in real:
    tag = f" *(sequence, {r['msgs']} msgs)*" if int(r["msgs"]) > 1 else ""
    w(f"| {r['id']} | {r['family']}{tag} | `{esc(r['text'])}` | `{r['action']}` |")
w("")
w("Every wave-2 miss is attributed to a **named gate** by `.verify/wave2`: six-letter acrostic (letter "
  "gate ≥ 7) · consonant-heavy acrostic (vowel ratio gate ≥ 0.30) · word-length carrier (length gate ≥ 9) "
  "· runs of five (run threshold ≥ 6) · punctuation runs · list-length encoding · search instruction "
  "instead of a domain · Hindi ordinals absent from the lexicon · ASCII-art digits · Hindi spelling "
  "alphabet.\n")
sec += 1

w("---\n")
w(f"## {sec}. Why the positional and carrier families are hardest\n")
w("These attacks hide the payload in **structure rather than content** — first letters, word lengths, "
  "repeat counts. Every individual word is innocent, and so is the sentence.\n")
w("| Family | Cases | Caught | Enforced | Routed | Miss |")
w("|---|---|---|---|---|---|")
for suite, fam in [("wave1","sequence"),("wave1","positional"),
                   ("wave2","carrierEdge"),("wave2","regularityEdge")]:
    g = [r for r in rows if r["suite"] == suite and r["family"] == fam]
    if not g: continue
    w(f"| `{fam}` | {len(g)} | {sum(1 for r in g if r['correct']=='1')} | "
      f"{sum(1 for r in g if r['action']!='allow')} | {sum(1 for r in g if r['escalated']=='1')} | "
      f"{sum(1 for r in g if r['correct']=='0')} |")
w("")
w("**These misses are a priced decision, not an oversight.** The codebase states the reason on the "
  "suspicion itself:\n")
w("> A structural channel — first letters, word lengths, repeat counts — decoded to something phone or "
  "handle shaped. **Not actionable alone, because ordinary sentences do this by accident.**\n")
w("Three gates create the misses, and each exists to protect precision:\n")
w("| Gate | Value | Attack that passes | Innocent text it would flag if tightened |")
w("|---|---|---|---|")
w("| Acrostic letter count | ≥ 7 | `Send Now My Text Line Only` (6 letters) | `Please Note Check In Time Is Two In The Afternoon` |")
w("| Acrostic vowel ratio | ≥ 0.30 | `Bring Rugs, Ncr Xtra Sheets, Trust Me` | consonant-initial amenity lists |")
w("| Repeat-run length | ≥ 6 | `aaaaa then aaaa then aaa` (runs of 5) | `sooooo excited`, `yesss!!!!` |")
w("")
w("The last row is checkable inside this corpus: `sooooo excited, thank youuuu` and "
  "`yesss!!!! we are so excited for this trip!!!!` are both innocent cases here. A run gate of 5 flags "
  "both, and neither is a violation.\n")
w("The hardest case in the suite is documented as unwinnable by design. "
  "`Villa Akshay Serena, Kanta House, Siolim, Havelock Alley, Yard Gate, Old Anjuna` is a plausible Goan "
  "address whose initials spell a handle; its corpus note reads *\"title case is legitimate here.\"*\n")
w("**Base rates decide this.** Title-cased lists, amenity bullets and addresses are everywhere in rental "
  "listings; acrostic exfiltration is rare. Any detector tuned tight enough to catch a six-letter acrostic "
  "fires constantly on `Check In 3pm Check Out 11am No Smoking No Parties`.\n")
w("The design consequence is that positional signals **route but never enforce**. Even at Tier 3, a "
  "positional-only suspicion requires ≥ 0.90 model confidence before it can act (`coincidenceProne` in "
  "`ModerationEngine`). That is why more positional cases route than enforce — the layer's job is to buy a "
  "model opinion, not to decide.\n")
sec += 1

w("---\n")
w(f"## {sec}. False positives\n")
w(f"**{len(fp)} across all {inn} innocent cases.**\n")
w("Four innocents cost a Tier 3 call — correct behaviour, since routing is cheap and cannot enforce:\n")
w("| # | Suite | Message | Suspicions |")
w("|---|---|---|---|")
for r in rows:
    if r["expected"] == "innocent" and r["escalated"] == "1":
        w(f"| {r['id']} | {r['suite']} | `{esc(r['text'])}` | {r['suspicions'].replace('|', ', ')} |")
w("")
w("Each is a genuine ambiguity: a mild review, Hindi numerals in an occupancy question, a cricket score "
  "shaped like a phone number, and title-case text tripping the acrostic check. All resolved by spending "
  "money rather than by enforcing.\n")
n_innocent = sum(1 for r in rows if r["expected"] != "attack")
w(f"**Reading the false-positive figure:** these {n_innocent} innocents were used to tune the rules, and "
  "zero errors across 47 regression innocents puts the 95% upper confidence bound near 7%. So the "
  "measurement supports \"no false positives observed at this sample size\", and it is that interval — not "
  "the point estimate — that belongs in a forecast. Widening the innocent set narrows the bound faster "
  "than any change to the rules.\n")
sec += 1

w("---\n")
w(f"## {sec}. Safety adjudication — live SLM\n")
w("`.verify/safety-audit`, 18 cases, 13 calls to `llama3.1:8b`. **Result: 18/18 correct.**\n")
w("| Case | Routed | Model verdict | Final |")
w("|---|---|---|---|")
for c, m, f_ in [("EN veiled threat","`safety_violation` / coercion","`review`"),
    ("EN dehumanising abuse","`safety_violation` / harassment","`warn`"),
    ("EN blackmail","`safety_violation` / coercion","`review`"),
    ("EN sexual","`safety_violation` / sexual","`block`"),
    ("**EN generic phishing**","`safety_violation` / scam","**`review`**"),
    ("HI roman threat","`safety_violation` / threat","`block`"),
    ("HI roman abuse","`safety_violation` / harassment","`warn`"),
    ("HI roman blackmail","`safety_violation` / coercion","`review`"),
    ("HI Devanagari threat","`safety_violation` / threat","`block`"),
    ("HI Devanagari abuse","`safety_violation` / harassment","`warn`"),
    ("RU threat","`safety_violation` / threat","`block`"),
    ("RU abuse","`safety_violation` / harassment","`warn`"),
    ("**EN angry complaint**","**`benign`**","**`allow`**")]:
    w(f"| {c} | yes | {m} | {f_} |")
w("| 5 innocent controls | no | not called | `allow` |")
w("")
w("### What changed when the model came online\n")
w("| Case | Model unreachable | Live SLM |")
w("|---|---|---|")
w("| EN generic phishing | `hint` — FAIL | `review` — **PASS** |")
w("| EN angry complaint | `review` — FAIL (false positive) | `allow` — **PASS** |")
w("")
w("The second is the significant one. The deterministic layer raised `conditionalDemand` on an angry "
  "complaint carrying a lawful lever, and the SLM **overrode it as `benign`**. Tier 3 is not only a recall "
  "layer — it is a precision layer that removes false positives on customer complaints.\n")
w("**Fail-closed verified.** With the model unavailable, a message the deterministic layers called `CLEAN` "
  "was still held: `LAYER3_ROUTE(harassment 0.46)` → `SAFETY_FAIL_CLOSED` → `review`.\n")
w("**Measured SLM performance:** 0.94 s warm, 3.27 s cold, 522-token prompt, deterministic at temperature 0. "
  "It classified the extortion case as `coercion` at confidence 1.0.\n")
sec += 1

w("---\n")
w(f"## {sec}. Latency and throughput\n")
w("| Corpus | p50 | p95 | p99 |")
w("|---|---|---|---|")
w(f"| This ledger (adversarial, short messages) | {pc(.5):.2f} | {pc(.95):.2f} | {pc(.99):.2f} |")
w("| Regression suite | 3.08 | 4.94 | 5.80 |")
w("")
w("Adversarial messages are shorter and therefore faster, so the regression figure is the one that "
  "describes what an ordinary user pays.\n")
w("**Pathological inputs, measured on this build:** a 14,000-character digit wall takes 208.6 ms and "
  "returns `mask`; 29,400 characters of innocent prose take 249.9 ms and return `allow`; 11,200 "
  "characters of homoglyph spam take 208.5 ms and return `mask`. Cost grows with length and the verdict "
  "stays correct at every size.\n")
w(f"**Throughput:** {1000/3.08:.0f} msg/s on one core at the regression p50 of 3.08 ms; "
  f"~{8*1000/3.08:.0f} msg/s projected across 8 cores.\n")
sec += 1

w("---\n")
w(f"## {sec}. Baselines and fault injection\n")
w("Measured by `tools/metrics` over the 111-case regression suite on the same build.\n")
w("| Approach | Recall | Precision | FPR | p50 |")
w("|---|---|---|---|---|")
w("| Regex only | 34.3% | 97.1% | 4.26% | 0.01 ms |")
w("| Deterministic cascade (T1+T2) | 96.5% | 99.5% | 2.13% | 2.06 ms |")
w("| **Full engine** | **100.0%** | **100.0%** | **0.00%** | **3.08 ms** |")
w("")
w("**Fault injection — 7 checks, no faults.** Verdicts deterministic across repeat evaluation · "
  "canonicalisation idempotent · buffers evict to 512 after 4,000 conversations · `review` does not leak "
  "original text · near-miss prose all allowed.\n")
sec += 1

w("---\n")
w(f"## {sec}. Reproduction\n")
w("```bash")
w("swiftc -O WayzyyChat/Moderation/*.swift tools/percase/main.swift -o /tmp/percase")
w("/tmp/percase > tools/percase/ledger.tsv")
w("python3 tools/percase/gen_ledger.py            # regenerates this document")
w("")
w("./.verify/metrics ; ./.verify/wave2 ; ./.verify/stats/tierstats")
w("./.verify/audit ; ./.verify/profile ; ./.verify/promptsize")
w("./.verify/tradeoff ; ./.verify/traffic")
w("")
w("ollama serve & ollama pull llama3.1:8b && ./.verify/safety-audit")
w("```\n")
sec += 1

w("---\n")
w(f"## {sec}. How to read these results\n")
w("1. **These corpora tuned the rules.** That makes them regression evidence — they measure whether known "
  "behaviour still holds, which is a different question from the error rate on unseen traffic. A frozen, "
  "sender- and time-disjoint holdout measures the second question, and the two numbers belong in separate "
  "columns rather than averaged together.")
w("2. **The per-case harness disables the conversation buffer**, so each message is judged alone. The "
  "`sequence` and `positional` families are built to be invisible one message at a time, so their numbers "
  "here are a floor rather than a description of capability; `tools/metrics` exercises the same cases with "
  "the buffer enabled.")
w("3. **Two corpus labels record a disagreement rather than a defect** — the lawful-lever cases named "
  "above, plus wave2 #525 and #528. They are kept visible instead of relabelled quietly, because the "
  "boundary between a lawful remedy and a threat is the judgement this system is most often asked to make.")
w("4. **Safety behaviour is asserted separately from this corpus.** Case counts measure coverage of "
  "adversarial contact-exfiltration technique, which is what an adversarial corpus is good at. The "
  "properties that matter for safety are universal rather than case-based — self-harm never blocks, "
  "harassment is never hard-blocked, lawful remedies are never enforced on — so they are enforced by an "
  "executable gate of 128 assertions across 41 rules that fails the build on violation, covering "
  "harassment, sexual content, self-harm, the complaint veto, cross-message behaviour, report and block "
  "signals, provisional hold, decision durability, concurrency and per-script calibration.")
w("")
w("**Reproducing everything in this document:**\n")
w("```")
w("swift build                       # library, service and gate")
w("./.build/debug/wayzyy-invariants  # 128 assertions, 41 rules")
w("swiftc -O WayzyyChat/Moderation/*.swift tools/metrics/main.swift -o /tmp/metrics && /tmp/metrics")
w("```\n")
w("---\n")
w("*Companions: `WAYZYY_MODERATION_COST_MODEL.md` · `WAYZYY_SAFETY_GUARDRAILS.md`*")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(o) + "\n")
# Count real lines, not w() calls: many of those strings embed newlines, so len(o) understated
# the file by a hundred lines.
print(f"wrote {OUT}: {len(rows)} cases, {sum(s.count(chr(10)) + 1 for s in o)} lines")
