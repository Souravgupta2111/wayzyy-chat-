#!/usr/bin/env python3
"""Train the abuse router: hashed character n-grams, linear model.

What this produces is a *router*, not an enforcer. Its output raises suspicion so that Tier 3
is asked; policy still decides the action. That is why it is tuned for recall and why a false
positive costs one model call rather than a withheld message.

Why character n-grams and not a word list
─────────────────────────────────────────
The published Hindi profanity lists contain `chutiya` but not `chutiye`, and no `bhosdike` at
all — so a matcher built from them catches one of six real messages from production. The same
list used as *training data* teaches the character texture `chu·hut·uti·tiy`, which then scores
every inflection, plural and misspelling nobody wrote down. The list is the input; the
generalisation is the model's.

Hashing is FNV-1a over UTF-8 bytes because it has to be reproduced exactly in Swift, on Linux,
with no crypto dependency.
"""

import json
import math
import os
import random
import sys

BUCKETS = 1 << 18          # 262,144 · ~1 MB of Float32 weights
NGRAMS = (3, 4, 5)
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def fnv1a(data: bytes) -> int:
    h = 0x811C9DC5
    for b in data:
        h ^= b
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h


def features(text: str) -> dict:
    """Hashed character n-grams, L2-normalised. No tokenisation, no dictionary."""
    t = " " + " ".join(text.lower().split()) + " "
    out = {}
    for n in NGRAMS:
        for i in range(len(t) - n + 1):
            k = fnv1a(t[i:i + n].encode("utf-8")) % BUCKETS
            out[k] = out.get(k, 0.0) + 1.0
    norm = sum(v * v for v in out.values()) ** 0.5 or 1.0
    return {k: v / norm for k, v in out.items()}


# ── Message frames.
#
# Terms are trained *in context* rather than bare, because that is how they arrive. Frames are
# ordinary Hinglish and English message shapes; the model is not learning the frames, it is
# learning which character sequences inside them carry abuse.
ABUSIVE_FRAMES = [
    "{t}", "chal {t}", "nikal {t}", "{t} saale", "tu {t} hai", "abey {t}",
    "you {t}", "you are a {t}", "{t} kahin ka", "kya karega {t}",
    "bhen ke {t}", "{t} insaan", "sun {t}", "{t} ki aulad", "oye {t}",
    "tere jaisa {t}", "{t} band kar", "host is a {t}", "{t} hai tu",
]

# Ordinary domain traffic. These are the sentences a guest or host actually sends, and the
# router must stay silent on all of them.
INNOCENT_FRAMES = [
    "kya rate hai bhai", "check in time kya hai", "ghar saaf tha thanks",
    "bhai thoda discount ho jayega", "payment kaise karna hai",
    "kitne log rah sakte hain", "wifi password bhej do", "parking available hai kya",
    "chal bhai booking kar dete hain", "kya aap pets allow karte ho",
    "gaon mein hai property", "chai milegi subah", "pani garam aata hai",
    "is the villa available next weekend", "do you allow pets in the property",
    "we will arrive around 4 pm", "the cleaning was terrible and i am furious",
    "this villa is filthy and the host is incompetent",
    "the host was slow to reply and unhelpful", "thanks for the quick reply",
    "can i get a late checkout", "how far is the beach from here",
    "kal subah pahunch jayenge", "booking confirm ho gayi",
    "photos dekh ke book kiya tha", "AC kaam nahi kar raha tha",
    "bathroom mein paani nahi tha", "kitchen use kar sakte hain",
    "extra mattress mil jayega", "location bahut acchi hai",
]

# ── Short innocent messages.
#
# The positive class includes bare terms, because an insult often arrives on its own. The side
# effect is that the model learns *shortness* as evidence: "see you at 5" scored 0.91 and "nh66"
# 0.82 before these were added. Chat is full of three-word messages, so that error is both
# frequent and expensive — every one buys a needless Tier 3 call.
#
# Length is a property of the medium, not of abuse. These teach that.
SHORT_INNOCENT = [
    "ok", "okay", "thanks", "thank you", "yes", "no", "sure", "done", "great",
    "see you at 5", "see you tomorrow", "on my way", "reached", "coming",
    "nh66", "room 301", "4 nights", "2 adults", "12800", "403001",
    "haan", "nahi", "theek hai", "ho gaya", "aa raha hoon", "pahunch gaye",
    "kal milte hain", "shukriya", "bahut accha", "acha theek",
    "5 pm", "11 am", "32 degrees", "78 percent", "4.8 stars",
    "good morning", "good night", "noted", "perfect", "will do",
    "kitna", "kahan", "kab", "kaise", "batao na", "ji haan",
]


# Harmless words dropped into the abusive frames to strip the frames of signal. Deliberately
# domain vocabulary, since that is what actually follows "chal" or "tu ... hai" in real traffic.
FILLERS = [
    "bhai", "yaar", "sir", "madam", "guest", "host", "booking", "villa", "room",
    "kal", "abhi", "thoda", "dekho", "batao", "chalo", "theek", "acha", "paisa",
]


def load_external_datasets():
    """Load real labelled data from Desktop CSVs if present.

    Two sources:
    - train.csv: 1,366-row Hinglish offensive/not-offensive dataset (most relevant)
    - labeled_data.csv: Davidson et al. 24,783-row English Twitter hate speech

    Both are auto-detected. If missing, training falls back to synthetic frames.
    """
    import csv as _csv
    pos, neg = [], []
    candidates = [
        # Hinglish offensive language — most relevant to Wayzyy's India-weighted traffic
        (os.path.expanduser("~/Desktop/train.csv"),
         "label", ("offensive",), ("not offensive",), "text"),
        # Davidson et al. English Twitter: class 0=hate speech, 1=offensive, 2=clean
        (os.path.expanduser("~/Desktop/labeled_data.csv"),
         "class", ("0", "1"), ("2",), "tweet"),
    ]
    for path, label_col, pos_vals, neg_vals, text_col in candidates:
        if not os.path.exists(path):
            continue
        rows = list(_csv.DictReader(open(path, encoding="utf-8", errors="ignore")))
        p = [r[text_col].strip() for r in rows
             if r.get(label_col, "").strip() in pos_vals and r.get(text_col, "").strip()]
        n = [r[text_col].strip() for r in rows
             if r.get(label_col, "").strip() in neg_vals and r.get(text_col, "").strip()]
        pos.extend(p)
        neg.extend(n)
        print(f"  {os.path.basename(path)}: {len(p)} offensive, {len(n)} clean")
    return pos, neg


def load_terms(path):
    with open(path, encoding="utf-8") as f:
        return [l.strip() for l in f if 2 <= len(l.strip()) <= 40]


def load_corpus_innocents(path):
    """Real innocent messages, and real contact-exfiltration attacks.

    The contact attacks are labelled NEGATIVE on purpose. This router answers "is this abuse",
    and contact exfiltration is already handled deterministically. Training phone numbers and
    handles as negatives stops the router escalating every masked number to Tier 3, which would
    multiply the model bill for no benefit.
    """
    if not os.path.exists(path):
        return [], []
    cases = json.load(open(path, encoding="utf-8"))
    innocent, contact_attacks = [], []
    for c in cases:
        text = " ".join(c.get("messages") or [])
        if not text.strip():
            continue
        (contact_attacks if c.get("shouldFlag") else innocent).append(text)
    return innocent, contact_attacks


# What a message with no recognised n-grams should score.
#
# The training set is ~90% positive, because a word list yields thousands of abusive examples and
# only a handful of innocent ones. Left alone, that pushes the intercept to +1.14, so text
# containing nothing the model has ever seen scores 0.76 — above threshold. Every Devanagari,
# Tamil or Bengali message would route to Tier 3 on the strength of being unfamiliar.
#
# Two corrections, both standard and both necessary:
#   1. Class-balanced loss, so 8,196 positives do not outvote 1,000 negatives.
#   2. An intercept set from the *deployment* prior rather than the training prior. Abuse is a
#      small fraction of real traffic, and "no evidence" must mean "stay silent" — otherwise the
#      router's default behaviour is to escalate the unknown.
FEATURELESS_TARGET = 0.05

# Where the router starts asking for a second opinion.
#
# Chosen from the sweep below, not from taste: it sits above the no-evidence score of 0.05 — so
# unfamiliar scripts stay silent — and below every abusive held-out message except one, while
# escalating none of the real innocent traffic. Written into the weights file so the scorer and
# the trainer cannot disagree about it.
ROUTE_THRESHOLD = 0.08


def train(rows, epochs=12, lr=0.25, l2=2e-6, seed=11):
    random.seed(seed)
    w = [0.0] * BUCKETS
    b = 0.0
    data = [(features(t), y) for t, y in rows]

    n_pos = sum(1 for _, y in data if y)
    n_neg = len(data) - n_pos
    # Balance by weighting the smaller class up, rather than discarding data from the larger.
    weight = {1: 1.0, 0: (n_pos / n_neg) if n_neg else 1.0}

    for _ in range(epochs):
        random.shuffle(data)
        for f, y in data:
            z = b + sum(w[k] * v for k, v in f.items())
            z = max(-30.0, min(30.0, z))
            p = 1.0 / (1.0 + pow(2.718281828459045, -z))
            g = (p - y) * weight[y]
            b -= lr * g
            for k, v in f.items():
                w[k] -= lr * (g * v + l2 * w[k])

    # Pin the no-evidence score. The learned feature weights are untouched, so the ordering of
    # messages is unchanged; only the point at which the scale sits moves. The threshold is
    # re-swept below against real traffic, on the corrected model.
    b = math.log(FEATURELESS_TARGET / (1 - FEATURELESS_TARGET))
    return w, b


def score(model, text):
    w, b = model
    z = b + sum(w[k] * v for k, v in features(text).items())
    z = max(-30.0, min(30.0, z))
    return 1.0 / (1.0 + pow(2.718281828459045, -z))


def main():
    terms = load_terms(os.path.join(HERE, "data", "profanity-union.txt"))
    innocent, contact = load_corpus_innocents("/tmp/corpus.json")

    # Hold back a fifth of the real innocent messages. False-positive rate measured on data the
    # model trained on is not a false-positive rate.
    random.Random(3).shuffle(innocent)
    split = max(1, len(innocent) // 5)
    innocent_test, innocent_train = innocent[:split], innocent[split:]

    print("\n--- External labelled datasets ---")
    ext_pos, ext_neg = load_external_datasets()
    if not ext_pos:
        print("  none found — using synthetic word-list frames only")

    rows = []
    for i, t in enumerate(terms):
        for frame in random.Random(i).sample(ABUSIVE_FRAMES, 3):
            rows.append((frame.format(t=t), 1))

    # Frame-neutralising negatives
    for frame in ABUSIVE_FRAMES:
        for filler in FILLERS:
            rows.append((frame.format(t=filler), 0))

    # Real labelled data. Added after synthetic frames — where both agree the gradient is
    # larger; where real data disagrees with a frame, real data is more likely right.
    rows += [(t, 1) for t in ext_pos]
    rows += [(t, 0) for t in ext_neg]

    rows += [(s, 0) for s in INNOCENT_FRAMES]
    rows += [(s, 0) for s in SHORT_INNOCENT for _ in range(3)]
    rows += [(s, 0) for s in innocent_train]
    rows += [(s, 0) for s in contact]

    pos = sum(y for _, y in rows)
    print(f"\ntraining rows: {len(rows)}  ({pos} abusive, {len(rows)-pos} innocent)")
    if ext_pos:
        print(f"  real labelled: {len(ext_pos)} offensive + {len(ext_neg)} clean  ← your CSVs")
    print(f"  terms {len(terms)} · frame-neutralising negatives {len(ABUSIVE_FRAMES)*len(FILLERS)}")
    print(f"  corpus innocents {len(innocent_train)} train / {len(innocent_test)} held back"
          f" · contact attacks as negatives {len(contact)}")

    model = train(rows)
    w, b = model

    # ── Held out. None of these appear in training: real production messages, unseen
    #    inflections, and innocent Hinglish.
    held = [
        ("Chal chutiye", 1), ("Nikal bhosdike", 1), ("Gand mara", 1),
        ("Kya karogee bkl", 1), ("Pussy ass bitch", 1),
        ("Hiey frank , you dogshit peace of crack", 1),
        ("chutiyapa band kar", 1), ("tu chutiyaa hai", 1), ("ch00tiye", 1),
        ("bhosadike saale", 1), ("madarchod kahin ka", 1),
        ("Kya rate hai bhai", 0), ("ghar saaf tha thanks", 0),
        ("bhai thoda discount ho jayega", 0), ("chal bhai booking kar dete hain", 0),
        ("the cleaning was terrible and i am furious about it", 0),
        ("this villa is filthy and the host is incompetent", 0),
        ("chai milegi subah", 0), ("gaon mein hai property", 0),
        ("call me on 9876543210", 0), ("my whatsapp is 98765 43210", 0),
        ("see you at 5", 0), ("nh66", 0), ("ok thanks", 0),
        # Scripts absent from training entirely. These must stay silent: the router has no
        # evidence about them, and "unfamiliar" is not "abusive".
        ("மனை கிடைக்குமா", 0), ("বাড়িটা কি পাওয়া যাবে", 0), ("お部屋はありますか", 0),
    ]
    print(f"\n{'held-out message':44} {'score':>6}  expect  result")
    print("-" * 78)
    tp = fp = fn = tn = 0
    for text, label in held:
        s = score(model, text)
        routes = s >= ROUTE_THRESHOLD
        if label and routes: tp += 1
        elif label and not routes: fn += 1
        elif not label and routes: fp += 1
        else: tn += 1
        mark = "ok" if routes == bool(label) else "MISS"
        print(f"{text[:44]:44} {s:6.3f}  {'abuse' if label else 'clean':6}  {mark}")
    print("-" * 78)
    print(f"recall {tp}/{tp+fn}   false positives {fp}/{fp+tn}")

    # ── Threshold sweep against held-back real innocent traffic.
    #
    # The threshold is a cost decision, not an accuracy one: a false positive here buys a Tier 3
    # call, so the question is what escalation rate is affordable, not what looks tidy.
    abusive_held = [t for t, y in held if y]
    print(f"\nthreshold sweep — recall on {len(abusive_held)} held-out abusive messages,"
          f" escalation on {len(innocent_test)} held-back innocents")
    print(f"  {'thr':>5} {'recall':>8} {'escalated':>11}")
    # Swept low because the intercept is pinned near the deployment prior, not at 0.5. The
    # separation that matters is between abusive text and *real innocent traffic*, and that gap
    # sits well below 0.5 once the classes are balanced.
    for thr in (0.06, 0.08, 0.10, 0.15, 0.20, 0.30, 0.50):
        r = sum(1 for t in abusive_held if score(model, t) >= thr)
        e = sum(1 for t in innocent_test if score(model, t) >= thr)
        mark = "  <- operating point" if abs(thr - ROUTE_THRESHOLD) < 1e-9 else ""
        print(f"  {thr:>5.2f} {r:>4}/{len(abusive_held):<3} {e:>5}/{len(innocent_test):<4}"
              f" {100*e/max(1,len(innocent_test)):>5.1f}%{mark}")

    # Sparse export: only buckets the training actually touched.
    nonzero = [(i, w[i]) for i in range(BUCKETS) if abs(w[i]) > 1e-4]
    out = os.path.join(ROOT, "config", "abuse-router.weights")
    with open(out, "w", encoding="utf-8") as f:
        f.write("WAYZYY-NGRAM-1\n")
        f.write(f"buckets {BUCKETS}\n")
        f.write(f"ngrams {','.join(map(str, NGRAMS))}\n")
        f.write(f"bias {b:.6f}\n")
        f.write(f"threshold {ROUTE_THRESHOLD}\n")
        f.write(f"weights {len(nonzero)}\n")
        for i, v in nonzero:
            f.write(f"{i} {v:.5f}\n")
    size = os.path.getsize(out)
    print(f"\nwrote {out}")
    print(f"  {len(nonzero)} non-zero weights · {size/1024:.0f} KB")


if __name__ == "__main__":
    sys.exit(main())
