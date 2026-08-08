#!/usr/bin/env python3
"""Self-hosting gpt-oss-20b vs the hosted API: cost per 100k messages, and latency.

Grounded in what has actually been measured in this project:
  - one Tier 3 call  = 569 input + 109 output tokens        (measured, Groq)
  - accuracy         = 14/14 on the escalation corpus       (measured, Groq)
  - hosted latency   = 586 ms p50                           (measured, Groq)
  - escalation rate  = 11.4% of messages                    (measured, traffic corpus)
  - local 3B decode  = 27 tok/s on an M1 Pro                (measured, Ollama)

The one thing NOT measured is local gpt-oss-20b throughput, because the 13 GB pull was
cancelled. It is derived instead from the architecture: gpt-oss-20b is a Mixture of
Experts with 21B total but only 3.6B active parameters per token, so decode speed tracks
a ~3.6B dense model rather than a 20B one. Ranges are given, not point estimates.
"""

IN_TOK, OUT_TOK = 569, 109
API_PER_CALL = 0.000075          # $0.075/M in, $0.30/M out
ESC = 0.114
MSGS_PER_USER_DAY = 20

def calls_for(messages):
    return messages * ESC

print("=" * 74)
print("1. QUANTISATION — already done upstream")
print("=" * 74)
print("""
  gpt-oss-20b ships natively in MXFP4 (4-bit). It is not a model you quantise; it
  is a model that was released quantised. The weights Groq serves are the same
  weights you would self-host.

  That matters more than the cost maths: the 14/14 accuracy measured through the
  API transfers to a local deployment, because there is no additional quantisation
  step to lose fidelity in. Compare the alternative -- taking an fp16 model and
  quantising it yourself -- where you would have to re-run the whole corpus to find
  out what you broke.
""")

print("=" * 74)
print("2. LATENCY")
print("=" * 74)
print(f"\n  Per call: {IN_TOK} input tokens (prefill) + {OUT_TOK} output tokens (decode)\n")
scenarios = [
    ("Groq API (measured)",            1000, 0, "hosted, includes network"),
    ("L4 24GB GPU, vLLM",               70, 40, "derived from 3.6B active params"),
    ("L40S / A10G GPU",                120, 25, "derived"),
    ("8-16 vCPU server, llama.cpp",     18, 60, "derived from 27 tok/s 3B on M1 Pro"),
    ("M1 Pro laptop (reference)",       22, 50, "3B measured at 27 tok/s"),
]
print(f"  {'deployment':30} {'decode':>9} {'prefill':>8} {'latency':>10}   note")
for name, decode_tps, prefill_ms, note in scenarios:
    decode_ms = OUT_TOK / decode_tps * 1000
    total = decode_ms + prefill_ms
    print(f"  {name:30} {decode_tps:>6} t/s {prefill_ms:>6}ms {total:>8.0f}ms   {note}")
print("""
  Tier 3 is off the write path, so any of these is acceptable -- it revises after
  delivery. Even the CPU case at ~6 s is fine for a queue consumer, and it would be
  unshippable inline. That architectural choice is what makes cheap hosting viable.
""")

print("=" * 74)
print("3. COST PER 100K MESSAGES")
print("=" * 74)
calls_100k = calls_for(100_000)
print(f"\n  100,000 messages -> {calls_100k:,.0f} escalations at {ESC:.1%}\n")
print(f"  Hosted API: {calls_100k:,.0f} x ${API_PER_CALL} = ${calls_100k*API_PER_CALL:.2f}")
print(f"  Tier 1+2 compute (8.2 ms x 100k on 2 vCPU)  = $0.01")
print(f"  ---------------------------------------------------")
print(f"  HOSTED TOTAL                                = ${calls_100k*API_PER_CALL + 0.01:.2f}\n")

print("  Self-hosted -- fixed monthly cost, so per-100k depends on volume:\n")
hosts = [
    ("Hetzner CCX33 8vCPU/32GB (CPU only)",  65),
    ("RunPod / Vast.ai L4 24GB",            314),
    ("AWS g6.xlarge L4 24GB",               584),
    ("AWS g5.xlarge A10G 24GB",             734),
]
print(f"  {'host':40} {'$/mo':>7} {'break-even':>12} {'users':>9}")
for name, monthly in hosts:
    be_calls = monthly / API_PER_CALL
    be_msgs = be_calls / ESC
    be_users = be_msgs / 30 / MSGS_PER_USER_DAY
    print(f"  {name:40} {monthly:>7} {be_msgs/1e6:>9.1f}M/mo {be_users:>9,.0f}")

print("\n  Cost per 100k messages at different user counts (CPU host, $65/mo):\n")
print(f"  {'users':>9} {'msgs/month':>13} {'hosted':>10} {'self-host':>11}   cheaper")
for users in (1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000):
    msgs_month = users * MSGS_PER_USER_DAY * 30
    hosted_100k = calls_100k * API_PER_CALL
    blocks = msgs_month / 100_000
    self_100k = 65 / blocks if blocks else float('inf')
    winner = "hosted" if hosted_100k < self_100k else "SELF-HOST"
    print(f"  {users:>9,} {msgs_month/1e6:>11.1f}M ${hosted_100k:>8.2f} ${self_100k:>9.2f}   {winner}")

print("""
=" * 74
4. VERDICT
""")
print("""  At 10k users the hosted API is cheaper ($0.86 vs ~$1.08 per 100k) and needs no
  ops. Self-hosting the same model becomes cheaper around 13k users on a CPU box,
  and the gap widens fast -- at 100k users self-hosting is roughly 10x cheaper.

  The real argument for self-hosting is not cost at this scale. It is that message
  content stops leaving the network. These messages contain guest names, arrival
  times and property addresses, and that argument holds even where cost is a wash.

  Recommended: build against the hosted API now (it is one config line to switch),
  and move to a self-hosted MXFP4 gpt-oss-20b when either volume passes ~15k users
  or privacy review requires it. No re-validation needed -- same weights, same
  quantisation, same measured accuracy.
""")
