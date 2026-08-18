#!/usr/bin/env python3
"""Does a character n-gram router need a profanity list? Demonstration.

The training input is LABELLED MESSAGES, never a vocabulary. Nobody writes down
"chutiya". Someone marks the message "Chal chutiye" as abusive -- or a recipient blocks
the sender, which labels it automatically -- and the model extracts character n-grams
from it.

The question this answers: do unseen spellings, inflections and compounds of those
words then score high WITHOUT anyone having written them?
"""

import hashlib
import random

BUCKETS = 1 << 16
NGRAMS = (3, 4, 5)


def features(text):
    """Hashed character n-grams. No tokenisation, no dictionary, no language model."""
    t = " " + text.lower().strip() + " "
    out = {}
    for n in NGRAMS:
        for i in range(len(t) - n + 1):
            gram = t[i:i + n]
            h = int(hashlib.md5(gram.encode()).hexdigest()[:8], 16) % BUCKETS
            out[h] = out.get(h, 0) + 1.0
    norm = sum(v * v for v in out.values()) ** 0.5 or 1.0
    return {k: v / norm for k, v in out.items()}


def train(rows, epochs=400, lr=0.5, l2=1e-5):
    w = [0.0] * BUCKETS
    b = 0.0
    data = [(features(t), y) for t, y in rows]
    for _ in range(epochs):
        random.shuffle(data)
        for f, y in data:
            z = b + sum(w[k] * v for k, v in f.items())
            p = 1.0 / (1.0 + pow(2.718281828, -z))
            g = p - y
            b -= lr * g
            for k, v in f.items():
                w[k] -= lr * (g * v + l2 * w[k])
    return w, b


def score(model, text):
    w, b = model
    f = features(text)
    z = b + sum(w[k] * v for k, v in f.items())
    return 1.0 / (1.0 + pow(2.718281828, -z))


# ── Training set: labelled MESSAGES. This is what a recipient's block, a sender's
#    edit-after-warning, or a batch LLM labelling pass produces. Note that it is
#    ordinary traffic with a flag on it -- not a curated word list.
TRAIN = [
    ("Chal chutiye", 1),
    ("Nikal bhosdike", 1),
    ("Kya karogee bkl", 1),
    ("Gand mara", 1),
    ("tu ek number ka chutiya hai", 1),
    ("abey saale bhosdike bahar aa", 1),
    ("teri maa ki aankh", 1),
    ("Pussy ass bitch", 1),
    ("you dogshit peace of crack", 1),
    ("randi ka baccha", 1),
    ("harami kutta", 1),
    ("bhen ke lode", 1),

    ("Kya rate hai bhai", 0),
    ("ghar saaf tha, thanks", 0),
    ("check in time kya hai", 0),
    ("is the villa available next weekend", 0),
    ("do you allow pets in the property", 0),
    ("the cleaning was terrible and i am furious", 0),
    ("this villa is filthy and the host is incompetent", 0),
    ("bhai thoda discount ho jayega", 0),
    ("payment kaise karna hai", 0),
    ("kitne log rah sakte hain", 0),
    ("we will arrive around 4 pm", 0),
    ("wifi password bhej do", 0),
    ("parking available hai kya", 0),
    ("thanks for the quick reply bhai", 0),
]

# ── Held-out: NONE of these strings appear above. Spellings, inflections, compounds
#    and obfuscations nobody wrote down.
HELD_OUT = [
    ("chutiyapa band kar", 1, "inflection of a trained root"),
    ("tu chutiyaa hai", 1, "doubled vowel"),
    ("ch00tiye", 1, "leet obfuscation"),
    ("bhosda", 1, "different inflection"),
    ("bhosadike saale", 1, "inserted vowel"),
    ("chutiyo ki fauj", 1, "plural form"),
    ("gaand mardo", 1, "spelling + conjugation"),
    ("kutte harami", 1, "reordered compound"),
    ("randi rona band kar", 1, "compound of a trained root"),
    ("you are a dogshit host", 1, "recombined English"),

    ("bhai rate kya hai", 0, "reordered innocent"),
    ("ghar bahut saaf tha", 0, "innocent variant"),
    ("kya aap pets allow karte ho", 0, "innocent Hinglish"),
    ("the host was slow to reply and unhelpful", 0, "harsh but legitimate"),
    ("chai milegi subah", 0, "innocent, shares 'cha' with chutiye"),
    ("chal bhai booking kar dete hain", 0, "innocent 'chal'"),
    ("gaon mein hai property", 0, "innocent, shares 'gaa' with gaand"),
]

if __name__ == "__main__":
    random.seed(7)
    model = train(TRAIN)

    print(f"trained on {len(TRAIN)} labelled messages "
          f"({sum(y for _, y in TRAIN)} abusive, {sum(1 for _, y in TRAIN if not y)} innocent)")
    print("NO word list was written. Features are hashed character n-grams.\n")

    print(f"{'held-out message':34} {'score':>6}  {'routes?':7} {'expected':9} why")
    print("-" * 96)
    tp = fp = fn = tn = 0
    for text, label, why in HELD_OUT:
        s = score(model, text)
        routes = s >= 0.5
        ok = "OK " if routes == bool(label) else "MISS"
        if label and routes: tp += 1
        elif label and not routes: fn += 1
        elif not label and routes: fp += 1
        else: tn += 1
        print(f"{text:34} {s:6.3f}  {str(routes):7} {ok:9} {why}")

    pos = tp + fn
    neg = tn + fp
    print("-" * 96)
    print(f"recall on unseen abusive forms: {tp}/{pos}   "
          f"false positives on unseen innocent: {fp}/{neg}")
