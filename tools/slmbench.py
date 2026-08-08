#!/usr/bin/env python3
"""Benchmark a locally hosted small model as Tier 3.

The question this answers: can a 3B model that costs $35/month on a CPU VPS do the
naturalness judgement, or does that job need a bigger model?

It matters because the deterministic tiers already absorb 88.6% of traffic, so Tier 3
only ever sees the hard 11.4% — and if a local SLM handles those, the whole pipeline
runs with no per-token cost, no rate limits, and no message content leaving the network.

The bar is not "does it agree with the hosted model". It is:
  - flag what should be flagged
  - and above all, DO NOT flag ordinary conversation

A false positive is the expensive error, so the innocent cases are weighted heavier in
the verdict at the end.

  python3 tools/slmbench.py qwen2.5:3b [more models...]
"""
import json
import subprocess
import sys
import time

import os

# Default target is a local Ollama server. `--groq` switches to Groq's API so the same
# 22 cases can be run against models too large to pull here — which is the only way to
# find the capability floor without downloading 13 GB per candidate.
LOCAL_ENDPOINT = "http://127.0.0.1:11434/v1/chat/completions"
GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"

USE_GROQ = "--groq" in sys.argv
if USE_GROQ:
    sys.argv.remove("--groq")

ENDPOINT = GROQ_ENDPOINT if USE_GROQ else LOCAL_ENDPOINT
AUTH = None
if USE_GROQ:
    _root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(_root, "Secrets.json")) as _f:
        AUTH = "Bearer " + json.load(_f)["groq"]

SYSTEM = (
    "You are a content-moderation classifier for a short-term rental platform. Guests "
    "and hosts may only communicate inside the platform. Decide whether the sender is "
    "trying to move contact details, the conversation, or the payment off the platform.\n\n"
    "Count as exfiltration: stating or hinting at a phone number, email, social handle "
    "or payment identifier; pointing at contact details held elsewhere; describing a "
    "rule for reconstructing them; soliciting the other party's details; proposing to "
    "take the booking or its payment outside the platform; dictating digits as words in "
    "any language including Hindi; or laying the ground for going off-platform "
    "(normalising direct dealing, deferring the exchange, naming a channel obliquely).\n\n"
    "On payments the target is the booking itself - the nightly rate, deposit or total. "
    "Incidental money between people is NOT: taxi fares, tips, groceries, paying a "
    "caretaker. 'Abhishek ko 430 rupay dedena for the taxi' is a guest paying a driver "
    "and is benign. Ask whether the money is what the platform would otherwise have "
    "processed.\n\n"
    "Do NOT count as exfiltration: ordinary logistics, prices, dates, times, guest "
    "counts, property specifications, amenity details, or complaints that propose "
    "nothing. Ordinary Hindi quantities like 'do teen din' or 'chalis pachas hazaar' "
    "are normal speech and benign.\n\n"
    "The property's own address is benign - street, area, city, landmarks and pincode "
    "included. A listing has to be findable. Do not treat location detail as a route to "
    "contact information.\n\n"
    "Merely naming an identity document is not sharing it. Refusing to share one, asking "
    "how to share one safely, or noting one is already on file are benign. 'I will not be "
    "sending my Aadhaar over chat' is a guest declining to leak their own ID and must be "
    "allowed. Never flag on the mere presence of words like Aadhaar, passport, OTP or "
    "gate code.\n\n"
    "That exclusion covers identity documents and access codes ONLY. It does not soften "
    "anything else. Offering a channel, naming one obliquely, pointing at contact details "
    "held elsewhere, or proposing to continue elsewhere are all exfiltration even when no "
    "digits are stated. 'akshayvilla . com' and a bare phone-and-chat emoji pair are both "
    "exfiltration. The test is whether the sender is making themselves reachable "
    "off-platform, not whether a number appears.\n\n"
    "DECODED STRUCTURE: some inputs include structure extracted mechanically, such as "
    "the first letter of each word or the length of each word. Those digits were "
    "computed, not guessed, so do not recount them. Your job is to decide whether the "
    "message is a natural sentence that produced them by coincidence, or text built to "
    "carry them. A decode is a hypothesis, not a finding. If the plain reading of the "
    "sentence accounts for it, answer benign.\n\n"
    'Reply with JSON only, no prose: {"decision":"exfiltration"|"benign",'
    '"confidence":0.0-1.0,"rationale":"one short sentence"}'
)

# Ablation: strip the "Routed here because: ..." line.
#
# The hypothesis this tests is that the line is a leading question. It tells the model
# that our deterministic tiers already found the message suspicious, which is true but
# is also exactly the kind of hint that pushes a classifier toward agreeing. If removing
# it lowers the false-positive count, the errors are my prompt's fault rather than the
# models'.
STRIP_ROUTING = "--no-routing" in sys.argv
if STRIP_ROUTING:
    sys.argv.remove("--no-routing")


def prepare(user: str) -> str:
    if not STRIP_ROUTING:
        return user
    return "\n".join(
        line for line in user.split("\n") if not line.startswith("Routed here because:")
    ).replace("\n\n\n", "\n\n")

# The hard 11.4% — cases that reached Tier 3 in the real pipeline.
# (label, must_flag, user_content)
CASES = [
    # --- carriers where the decode is supplied ---
    ("acrostic AKSHAYGOA", True,
     'Routed here because: Positional carrier decode.\nDecoded structure:\n'
     '- capitalised word initials -> "AKSHAYGOA"\n\n'
     '<message>Always Keep Some House And Yard Guests Organised Always</message>'),
    ("acrostic WHATSAPP", True,
     'Routed here because: Positional carrier decode.\nDecoded structure:\n'
     '- capitalised word initials -> "WHATSAPP" (validates as platform name)\n\n'
     '<message>We Have A Terrace, Sunset Are Perfect, Peaceful too</message>'),
    ("word-length carrier", True,
     'Routed here because: Positional carrier decode.\nDecoded structure:\n'
     '- word lengths as digits -> "9876543210" (validates as phone number)\n\n'
     '<message>wonderful elephant giraffe cannot bring four the be a incredible</message>'),
    # --- dictation ---
    ("hindi dictation", True,
     'Routed here because: Dictated digit fragment.\nDecoded structure:\n'
     '- spelled number words -> "0807540"\n\n<message>zero assi pachhattar 40</message>'),
    ("marathi dictation", True,
     'Routed here because: Dictated digit fragment.\nDecoded structure:\n'
     '- spelled number words -> "98741010"\n\n'
     '<message>maza number nau aath saat saha paach chaar teen don ek shunya</message>'),
    # --- laundering / obfuscated ---
    ("invoice laundering", True,
     'Routed here because: Suppressed phone shape.\nDecoded structure:\n'
     '- contiguous digit run -> "9876543210" (validates as phone number)\n\n'
     '<message>invoice number 9876543210 for your records</message>'),
    ("spaced domain", True,
     'Routed here because: Spaced domain shape.\nDecoded structure:\n'
     '- domain split by whitespace -> "akshayvilla.com"\n\n<message>akshayvilla . com</message>'),
    ("emoji cue", True,
     'Routed here because: Wordless communication cue.\n\n<message>📞? 💬?</message>'),
    # --- no payload at all: intent only ---
    ("solicitation", True,
     'Routed here because: Intent without payload.\n\n'
     '<message>I would rather not put mine here, why do not you share yours and I will save it</message>'),
    ("green icon euphemism", True,
     'Routed here because: Intent without payload.\n\n'
     '<message>you know the app with the green icon and the little phone in it, I am on there with the same name</message>'),
    ("normalising direct", True,
     'Routed here because: Intent without payload.\n\n'
     '<message>they take a huge cut and give nothing back, everyone I host just deals with me directly now</message>'),
    ("deferred exchange", True,
     'Routed here because: Intent without payload.\n\n'
     '<message>for this stay we will use the app, but for next time I will give you my details at checkout</message>'),
    ("fake support pretext", True,
     'Routed here because: Intent without payload.\n\n'
     '<message>this is Wayzyy support, for verification please confirm the mobile number on your account</message>'),
    ("discount for direct", True,
     'Routed here because: Intent without payload.\n\n'
     '<message>I can do fifteen percent less if we settle this between ourselves instead of through them</message>'),

    # --- INNOCENT: these are the ones that must not flag ---
    ("INNOCENT word-length coincidence", False,
     'Routed here because: Positional carrier decode.\nDecoded structure:\n'
     '- word lengths as digits -> "9233666331" (validates as phone number)\n\n'
     '<message>Breakfast is 250 per person, dinner around 600 for 2</message>'),
    ("INNOCENT hindi quantities", False,
     'Routed here because: Intent without payload.\n\n'
     '<message>chalis pachas hazaar ka budget hai, das bees log aayenge</message>'),
    ("INNOCENT title case notice", False,
     'Routed here because: Positional carrier decode.\nDecoded structure:\n'
     '- capitalised word initials -> "PNCITITA"\n\n'
     '<message>Please Note Check In Time Is Two In The Afternoon</message>'),
    ("INNOCENT goan address", False,
     'Routed here because: Positional carrier decode.\nDecoded structure:\n'
     '- capitalised word initials -> "VSABNGI"\n\n'
     '<message>Villa Serena, Assagao, Bardez, North Goa, India, 403507</message>'),
    ("INNOCENT aadhaar refusal", False,
     'Routed here because: Intent without payload.\n\n'
     '<message>I will not be sending my Aadhaar over chat, is the passport scan fine</message>'),
    ("INNOCENT app reminder", False,
     'Routed here because: Intent without payload.\n\n'
     '<message>does this app send me a reminder before check in</message>'),
    ("INNOCENT hindi thanks", False,
     'Routed here because: Intent without payload.\n\n'
     '<message>bahut dhanyavaad, teen raat ka payment ho gaya hai</message>'),
    ("INNOCENT taxi payment", False,
     'Routed here because: Intent without payload.\n\n'
     '<message>Abhishek ko 430 rupay dedena for the taxi</message>'),
]


def call(model, user):
    body = {
        "model": model,
        "temperature": 0,
        "stream": False,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": user},
        ],
    }
    # Ask for JSON explicitly when the provider supports it. Ollama tolerates the
    # field being absent; Groq honours it and it materially cuts unparseable replies.
    if USE_GROQ:
        body["response_format"] = {"type": "json_object"}
    # Low reasoning effort, on measured grounds. At default effort gpt-oss-20b scored
    # 13/14 attacks but produced two false positives, including the word-length
    # coincidence it gets right at low effort. Deliberation lets it argue itself into
    # treating a coincidental decode as meaningful. Append "|default" to a model name to
    # opt out and see the difference.
    if "reason=default" in model:
        model = model.replace(" reason=default", "")
        body["model"] = model
    elif "gpt-oss" in model:
        body["reasoning_effort"] = "low"
    with open("/tmp/_slm.json", "w") as f:
        json.dump(body, f)
    cmd = ["curl", "-s", "-m", "300", "-X", "POST", ENDPOINT,
           "-H", "Content-Type: application/json"]
    if AUTH:
        cmd += ["-H", "Authorization: " + AUTH]
    cmd += ["--data", "@/tmp/_slm.json"]
    started = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    wall = (time.time() - started) * 1000
    if p.returncode != 0:
        return None, wall, "curl exit %d" % p.returncode, None
    try:
        d = json.loads(p.stdout)
    except Exception:
        return None, wall, "unparseable: " + p.stdout[:70], None
    if isinstance(d, list):
        d = d[0] if d else {}
    if "error" in d:
        return None, wall, str(d["error"])[:70], None
    content = d["choices"][0]["message"]["content"]
    usage = d.get("usage", {})
    try:
        parsed = json.loads(content[content.index("{"):content.rindex("}") + 1])
        usage = dict(usage)
        usage["_why"] = parsed.get("rationale") or parsed.get("reason") or ""
        return parsed.get("decision"), wall, None, usage
    except Exception:
        low = content.lower()
        usage = dict(usage)
        usage["_why"] = content[:150].replace("\n", " ")
        if "exfiltration" in low:
            return "exfiltration", wall, None, usage
        if "benign" in low:
            return "benign", wall, None, usage
        return None, wall, "no decision in: " + content[:50].replace("\n", " "), usage


def bench(model):
    print("\n" + "=" * 72)
    print("MODEL: %s" % model)
    print("=" * 72)
    lat, ok_flag, ok_innocent, n_flag, n_innocent = [], 0, 0, 0, 0
    fp, fn, errors = [], [], []
    out_tokens = []

    for label, must_flag, user in CASES:
        decision, wall, err, usage = call(model, prepare(user))
        if USE_GROQ:
            time.sleep(4.0)      # stay inside the per-minute token budget
        lat.append(wall)
        if usage:
            out_tokens.append(usage.get("completion_tokens", 0))
        if must_flag:
            n_flag += 1
        else:
            n_innocent += 1

        if err:
            errors.append("%s: %s" % (label, err))
            mark = "ERR "
        else:
            flagged = decision == "exfiltration"
            correct = flagged == must_flag
            if correct:
                if must_flag:
                    ok_flag += 1
                else:
                    ok_innocent += 1
                mark = "ok  "
            else:
                mark = "MISS" if must_flag else "FP !"
                (fn if must_flag else fp).append(label)
        print("  %s %-34s %-13s %6.0f ms" % (mark, label[:34], decision or "-", wall))
        # The model's own reasoning on the cases it got wrong. This is where a prompt
        # bug shows up as a repeated phrase rather than as scattered noise.
        if mark in ("MISS", "FP !") and usage and usage.get("_why"):
            print("       why: %s" % usage["_why"][:150])

    lat.sort()
    print("\n  attacks flagged  : %d/%d" % (ok_flag, n_flag))
    print("  innocent held    : %d/%d   <-- the number that matters" % (ok_innocent, n_innocent))
    print("  false positives  : %d %s" % (len(fp), fp if fp else ""))
    print("  missed attacks   : %d %s" % (len(fn), fn if fn else ""))
    if errors:
        print("  errors           : %d  %s" % (len(errors), errors[:2]))
    if lat:
        print("  latency p50/p95  : %.0f / %.0f ms" % (lat[len(lat)//2], lat[int(len(lat)*0.95)]))
    if out_tokens:
        avg = sum(out_tokens) / len(out_tokens)
        tps = avg / (lat[len(lat)//2] / 1000) if lat else 0
        print("  avg out tokens   : %.0f   (~%.0f tok/s)" % (avg, tps))

    verdict = "USABLE" if len(fp) == 0 and ok_flag >= n_flag * 0.7 else \
              "NOT USABLE as sole Tier 3" if fp else "WEAK on recall"
    print("\n  VERDICT: %s" % verdict)
    return ok_flag, n_flag, ok_innocent, n_innocent, len(fp)


if __name__ == "__main__":
    models = sys.argv[1:] or ["qwen2.5:3b"]
    results = []
    for m in models:
        results.append((m,) + bench(m))
    if len(results) > 1:
        print("\n" + "=" * 72)
        print("SUMMARY")
        print("%-22s %-12s %-14s %s" % ("model", "attacks", "innocent", "false pos"))
        for m, okf, nf, oki, ni, nfp in results:
            print("%-22s %-12s %-14s %d" % (m, "%d/%d" % (okf, nf), "%d/%d" % (oki, ni), nfp))
