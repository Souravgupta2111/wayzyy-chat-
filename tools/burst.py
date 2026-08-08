#!/usr/bin/env python3
"""Tier 3 throughput under concurrency.

The write path is already measured: 4,977 evaluations/second across 12 threads. That
number says the deterministic tiers absorb a burst trivially. It says nothing about
Tier 3, which is the only component with a real capacity ceiling, and therefore the
only one that decides whether "10,000 messages at once" is survivable.

So this measures the thing that actually binds: how many judge calls a single local
8B serves per second as concurrency rises. Prompt size is held at the measured
production shape (569 input tokens, ~109 output) so the throughput figure transfers.

Localhost HTTP on purpose — urllib has no CA certificates in this environment, but
there is no TLS to verify against 127.0.0.1.
"""
import json
import statistics
import sys
import threading
import time
import urllib.request

HOST = "http://127.0.0.1:11434/v1/chat/completions"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "llama3.1:8b"

# Representative judge prompt. The real one runs 569 input tokens; this reproduces the
# shape and length rather than the exact policy text, because what is being measured is
# tokens-per-second under load, not accuracy.
RULES = " ".join(
    [
        "You are a moderation judge for a short-term rental chat platform.",
        "Decide whether the final message shares off-platform contact information.",
        "Contact information means a phone number, email address, social handle,",
        "messaging app identifier, payment identifier, or a URL that leads off",
        "platform. Numbers that are prices, dates, times, room counts, guest counts,",
        "distances, or government identifiers are not contact information.",
        "Naming a platform is not sharing an identifier. Describing the property",
        "address is not contact information. Asking to pay outside the platform is",
        "only a violation when an off-platform identifier is present.",
        "Respond with strict JSON: {\"verdict\":\"allow\"|\"block\",\"confidence\":0.0-1.0,",
        "\"reason\":\"one sentence\"}. Do not include any other text.",
    ]
    * 3
)
MESSAGE = "Breakfast is 250 per person and dinner is around 600 for two, the villa covers all three floors and check-in is at 2pm."


def one_call(timings, lock, errors):
    body = json.dumps(
        {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": RULES},
                {"role": "user", "content": "Routed here because: numeric density.\n\nMessage: " + MESSAGE},
            ],
            "temperature": 0,
            "max_tokens": 160,
        }
    ).encode()
    req = urllib.request.Request(HOST, data=body, headers={"Content-Type": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            payload = json.load(r)
        elapsed = (time.time() - started) * 1000
        usage = payload.get("usage", {})
        with lock:
            timings.append((elapsed, usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0)))
    except Exception as exc:  # noqa: BLE001
        with lock:
            errors.append(str(exc)[:80])


def level(concurrency, calls):
    """Run `calls` judge requests with `concurrency` in flight at a time."""
    timings, errors, lock = [], [], threading.Lock()
    pending = list(range(calls))
    idx_lock = threading.Lock()

    def worker():
        while True:
            with idx_lock:
                if not pending:
                    return
                pending.pop()
            one_call(timings, lock, errors)

    started = time.time()
    threads = [threading.Thread(target=worker) for _ in range(concurrency)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.time() - started

    if not timings:
        print(f"  concurrency {concurrency:2d}   ALL FAILED   {errors[:1]}")
        return None
    lat = sorted(x[0] for x in timings)
    out_tokens = sum(x[2] for x in timings)
    in_tokens = sum(x[1] for x in timings)
    tput = len(timings) / wall
    print(
        f"  concurrency {concurrency:2d}   {len(timings):3d} ok  {len(errors):2d} err   "
        f"wall {wall:6.1f}s   {tput:5.2f} calls/s   "
        f"p50 {statistics.median(lat):7.0f} ms   p95 {lat[int(len(lat)*0.95)-1]:7.0f} ms   "
        f"{(in_tokens+out_tokens)/wall:6.0f} tok/s"
    )
    return {"concurrency": concurrency, "calls_per_s": tput, "p50_ms": statistics.median(lat),
            "in_tok": in_tokens / len(timings), "out_tok": out_tokens / len(timings)}


print(f"TIER 3 THROUGHPUT — {MODEL}")
print("=" * 78)
results = []
for c, n in [(1, 3), (2, 4), (4, 8), (8, 8)]:
    r = level(c, n)
    if r:
        results.append(r)

if results:
    best = max(results, key=lambda r: r["calls_per_s"])
    print("=" * 78)
    print(f"  peak sustained: {best['calls_per_s']:.2f} calls/s at concurrency {best['concurrency']}")
    print(f"  measured prompt: {best['in_tok']:.0f} in + {best['out_tok']:.0f} out tokens")
    # A 10k-message burst escalates at the measured pipeline rate of 10.2%.
    burst_calls = 10_000 * 0.102
    print(f"\n  10,000-message burst → {burst_calls:.0f} Tier 3 calls")
    print(f"  drain time on ONE local 8B: {burst_calls / best['calls_per_s'] / 60:.1f} min")
    for replicas in (4, 8, 16, 32):
        print(f"    with {replicas:2d} replicas: {burst_calls / (best['calls_per_s'] * replicas) / 60:5.1f} min")
    json.dump(results, open("/tmp/burst.json", "w"), indent=1)
    print("\n  wrote /tmp/burst.json")
