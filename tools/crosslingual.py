#!/usr/bin/env python3
"""Does the embedding model place Hinglish near its English meaning?

This is the load-bearing assumption behind moving the safety anchor family onto
embeddings. If it holds, English anchors cover Hindi, Marathi and Russian for free and
the hand-written Hinglish anchors can be deleted. If it does not hold, the whole plan
collapses back to writing anchors per language, and it is much better to find that out
in five minutes than after the refactor.

The test that matters is not "are the two sentences similar" in isolation. It is whether
a Hinglish threat is closer to an English *threat* anchor than to an English *innocent*
anchor — because that margin is exactly what the retriever gates on.
"""
import json
import urllib.request

HOST = "http://127.0.0.1:11434/v1/embeddings"
MODEL = __import__("sys").argv[1] if len(__import__("sys").argv) > 1 else "nomic-embed-text"


def embed(text):
    body = json.dumps({"model": MODEL, "input": text}).encode()
    req = urllib.request.Request(HOST, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["data"][0]["embedding"]


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    return dot / (na * nb) if na and nb else 0.0


# English anchors, exactly the register already in IntentExemplars.
THREAT_ANCHORS = [
    "i will kill you",
    "i know where your house is and i will come there",
    "i will trash the place before i leave",
    "i will find you and deal with this in person",
    "i know which school your children go to",
]
INNOCENT_ANCHORS = [
    "what time is check in and check out",
    "the villa is dirty and i want a refund",
    "can you send me photos of the bedroom",
    "we will arrive around seven in the evening",
    "how much do you charge for three nights",
]

# Hinglish probes. Left column is what it means, so the result is readable.
PROBES = [
    ("tujhe maar dunga", "THREAT  (I will kill you)"),
    ("tere ghar aa raha hun", "THREAT  (I'm coming to your house)"),
    ("teri family ko dekh lunga", "THREAT  (I'll deal with your family)"),
    ("tera business barbaad kar dunga", "THREAT  (I'll ruin your business)"),
    ("paisa wapas de warna review kharab kar dunga", "THREAT  (refund or I ruin your rating)"),
    ("checkin ka time kya hai", "INNOCENT (what time is check-in)"),
    ("villa saaf nahi tha paisa wapas chahiye", "INNOCENT (villa wasn't clean, want refund)"),
    ("kitna charge karte hain teen raat ka", "INNOCENT (what do you charge for 3 nights)"),
    ("bhai ac kaam nahi kar raha", "INNOCENT (the ac isn't working)"),
    ("main check karke dekh lunga", "INNOCENT (I'll take a look)"),
]

print("Embedding anchors...")
threat_vecs = [embed(t) for t in THREAT_ANCHORS]
innocent_vecs = [embed(t) for t in INNOCENT_ANCHORS]

print()
print("=" * 96)
print(f"{'probe':46s} {'threat':>8s} {'innocent':>9s} {'margin':>8s}  verdict")
print("=" * 96)

correct = 0
for text, label in PROBES:
    v = embed(text)
    t = max(cosine(v, a) for a in threat_vecs)
    i = max(cosine(v, a) for a in innocent_vecs)
    margin = t - i
    leans_threat = margin > 0
    should_be_threat = label.startswith("THREAT")
    ok = leans_threat == should_be_threat
    correct += ok
    print(f"{text[:44]:46s} {t:8.3f} {i:9.3f} {margin:+8.3f}  "
          f"{'THREAT' if leans_threat else 'innocent':9s} {'ok' if ok else 'WRONG'}   {label}")

print("=" * 96)
print(f"  {correct}/{len(PROBES)} correctly separated by sign of margin")
print()
print("  What this decides: if the margin is positive for Hinglish threats and negative")
print("  for Hinglish innocents, then English anchors cover Hindi with no Hindi data, and")
print("  the hand-written Hinglish anchors are redundant. If the margins are all tiny or")
print("  the signs are mixed, they are not.")
