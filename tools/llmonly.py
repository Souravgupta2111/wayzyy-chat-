#!/usr/bin/env python3
"""LLM-only baseline: the whole corpus, shuffled, no deterministic tiers.

One mixed pool of 480 cases in random order — attacks and innocent traffic together,
no corpus labels, no per-suite framing. That is deliberate. Reporting per-suite invites
cherry-picking the flattering half, and a production system does not know which suite a
message came from either.

This measures the model ALONE. No canonicalisation, no extraction, no numeric-context
suppression, no decoded carriers handed over — just the raw message text and the same
policy prompt. It is the honest answer to "why not just use an LLM".

  python3 tools/llmonly.py                      local llama3.1:8b via Ollama
  python3 tools/llmonly.py --model qwen2.5:3b
  python3 tools/llmonly.py --groq --model openai/gpt-oss-20b
  python3 tools/llmonly.py --limit 120          sample, for a quick read
"""
import json
import os
import random
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

args = sys.argv[1:]
USE_GROQ = "--groq" in args
if USE_GROQ:
    args.remove("--groq")

MODEL = "llama3.1:8b"
if "--model" in args:
    i = args.index("--model")
    MODEL = args[i + 1]
    del args[i:i + 2]

LIMIT = None
if "--limit" in args:
    i = args.index("--limit")
    LIMIT = int(args[i + 1])
    del args[i:i + 2]

if USE_GROQ:
    ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"
    with open(os.path.join(ROOT, "Secrets.json")) as f:
        AUTH = "Bearer " + json.load(f)["groq"]
    PACING = 4.0
else:
    ENDPOINT = "http://127.0.0.1:11434/v1/chat/completions"
    AUTH = None
    PACING = 0.0

# The same policy the engine gives its own Tier 3, minus anything that depends on
# deterministic pre-work. No decoded carriers, because a bare LLM has none.
SYSTEM = (
    "You are a content-moderation classifier for a short-term rental platform. Guests "
    "and hosts may only communicate inside the platform. Decide whether the sender is "
    "trying to move contact details, the conversation, or the payment off the platform.\n\n"
    "Count as exfiltration: stating or hinting at a phone number, email, social handle "
    "or payment identifier, however obfuscated — spelled-out digits, homoglyphs, "
    "leetspeak, split across messages, hidden in acrostics or word lengths, or encoded "
    "in base64, hex, morse or roman numerals; pointing at contact details held elsewhere "
    "(a profile, photo, sign, review or search engine); describing a rule for "
    "reconstructing them; soliciting the other party's details; proposing to take the "
    "booking or its payment off the platform; or laying the ground for going "
    "off-platform (normalising direct dealing, deferring the exchange, naming a channel "
    "obliquely). Also count threats, coercion and scam links.\n\n"
    "Dictating digits as words counts, in any language including Hindi, Marathi, Tamil "
    "and Bengali. Ordinary quantities like 'do teen din' do not.\n\n"
    "Do NOT count as exfiltration: ordinary logistics, prices, dates, times, guest "
    "counts, property specifications, amenity details, or complaints that propose "
    "nothing. The property's own address is benign, pincode included — a listing has to "
    "be findable. Merely naming an identity document is not sharing it; refusing to "
    "share one is benign. On payments the target is the booking's money, not incidental "
    "cash between people such as taxi fares or tips.\n\n"
    'Reply with JSON only: {"decision":"exfiltration"|"benign","confidence":0.0-1.0}'
)


def classify(messages):
    convo = "\n".join("<message>%s</message>" % m for m in messages)
    body = {
        "model": MODEL,
        "temperature": 0,
        "stream": False,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": convo + "\n\nClassify. JSON only."},
        ],
    }
    if USE_GROQ:
        body["response_format"] = {"type": "json_object"}
        if "gpt-oss" in MODEL:
            body["reasoning_effort"] = "low"
    with open("/tmp/_lo.json", "w") as f:
        json.dump(body, f)
    cmd = ["curl", "-s", "-m", "120", "-X", "POST", ENDPOINT,
           "-H", "Content-Type: application/json"]
    if AUTH:
        cmd += ["-H", "Authorization: " + AUTH]
    cmd += ["--data", "@/tmp/_lo.json"]

    t = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    wall = (time.time() - t) * 1000
    if p.returncode != 0:
        return None, wall, "curl %d" % p.returncode
    try:
        d = json.loads(p.stdout)
    except Exception:
        return None, wall, "unparseable"
    if isinstance(d, list):
        d = d[0] if d else {}
    if "error" in d:
        return None, wall, str(d["error"])[:60]
    c = d["choices"][0]["message"]["content"]
    try:
        return json.loads(c[c.index("{"):c.rindex("}") + 1]).get("decision"), wall, None
    except Exception:
        low = c.lower()
        if "exfiltration" in low:
            return "exfiltration", wall, None
        if "benign" in low:
            return "benign", wall, None
        return None, wall, "no decision"


with open("/tmp/corpus.json") as f:
    corpus = json.load(f)

random.seed(20260805)          # shuffled, but reproducibly
random.shuffle(corpus)
if LIMIT:
    corpus = corpus[:LIMIT]

attacks = sum(1 for c in corpus if c["shouldFlag"])
print("=" * 70)
print("LLM-ONLY BASELINE — %s%s" % (MODEL, " (hosted)" if USE_GROQ else " (local)"))
print("=" * 70)
print("%d cases, shuffled: %d attacks, %d innocent" % (len(corpus), attacks, len(corpus) - attacks))
print("no canonicalisation, no extraction, no decoded carriers — raw text only\n")

tp = fn = tn = fp = err = 0
lat = []
fp_examples, fn_examples = [], []
t0 = time.time()

for n, case in enumerate(corpus, 1):
    decision, wall, e = classify(case["messages"])
    lat.append(wall)
    if e:
        err += 1
    else:
        flagged = decision == "exfiltration"
        if case["shouldFlag"]:
            if flagged:
                tp += 1
            else:
                fn += 1
                if len(fn_examples) < 14:
                    fn_examples.append((case["family"], case["messages"][-1][:62]))
        else:
            if flagged:
                fp += 1
                if len(fp_examples) < 14:
                    fp_examples.append((case["family"], case["messages"][-1][:62]))
            else:
                tn += 1
    if n % 40 == 0:
        el = time.time() - t0
        print("  %3d/%d  %.0fs elapsed, ~%.0fs left" %
              (n, len(corpus), el, el / n * (len(corpus) - n)))
    if PACING:
        time.sleep(PACING)

lat.sort()
pos, neg = tp + fn, tn + fp
recall = tp / pos if pos else 0
precision = tp / (tp + fp) if (tp + fp) else 0
fpr = fp / neg if neg else 0
acc = (tp + tn) / (tp + tn + fp + fn) if (tp + tn + fp + fn) else 0

print("\n" + "=" * 70)
print("RESULT — one mixed pool, no per-suite breakdown")
print("=" * 70)
print("  recall     %6.1f%%   (%d of %d attacks caught)" % (recall * 100, tp, pos))
print("  precision  %6.1f%%" % (precision * 100))
print("  FPR        %6.1f%%   (%d of %d innocent messages flagged)" % (fpr * 100, fp, neg))
print("  accuracy   %6.1f%%" % (acc * 100))
print("  errors     %6d" % err)
if lat:
    print("  latency    p50 %.0f ms   p95 %.0f ms   total %.0f s"
          % (lat[len(lat)//2], lat[int(len(lat)*0.95)], sum(lat)/1000))

print("\n  FALSE POSITIVES — innocent messages it blocked (%d):" % fp)
for fam, txt in fp_examples:
    print("    [%s] %s" % (fam[:22], txt))
print("\n  MISSED ATTACKS (%d shown of %d):" % (len(fn_examples), fn))
for fam, txt in fn_examples:
    print("    [%s] %s" % (fam[:22], txt))
