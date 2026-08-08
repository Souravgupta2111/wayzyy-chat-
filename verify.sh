#!/bin/bash
# One-shot verification for the moderation engine.
#
#   ./verify.sh        metrics + wave 2 + hand-reported regression probes
#   ./verify.sh app    also build and install the iOS app
#
# Harnesses live in tools/ and compile against the shipping sources in
# WayzyyChat/Moderation, so there is no second implementation to drift. They sit
# outside the app source directory on purpose: the Xcode project uses synchronised
# file groups, so a main.swift inside it would be added to the app target and break
# the build with top-level code.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/WayzyyChat/Moderation"
OUT="$ROOT/.verify"
mkdir -p "$OUT"

hr() { printf '\n%s\n' "────────────────────────────────────────────────────────────"; }
fail=0

hr; echo "BUILDING HARNESSES"
for name in metrics wave2 probes audit fuzzprobe diag; do
  if swiftc -swift-version 5 -O -o "$OUT/$name" "$SRC"/*.swift "$ROOT/tools/$name/main.swift" 2>"$OUT/$name.err"; then
    echo "  ok   $name"
  else
    echo "  FAIL $name"
    grep -m8 "error:" "$OUT/$name.err" | sed 's/^/       /'
    fail=1
  fi
done
[ "$fail" = 1 ] && { hr; echo "COMPILE FAILED — stopping."; exit 1; }

hr; echo "HAND-REPORTED REGRESSION PROBES"
"$OUT/probes" || fail=1

hr; echo "SELF-AUDIT (performance, growth, determinism, leaks)"
"$OUT/audit" | grep -E "FAULT|ok |ms/call|assembly with|tracked =|NO FAULTS|FAULTS FOUND"
"$OUT/audit" | grep -q "NO FAULTS FOUND" || fail=1

hr; echo "FUZZY-MATCH FALSE POSITIVE SWEEP"
"$OUT/fuzzprobe" | tail -4
"$OUT/fuzzprobe" | grep -q "0 of 11 ordinary sentences masked" || fail=1

hr; echo "HEADLINE METRICS"
"$OUT/metrics"

hr; echo "WAVE 2"
"$OUT/wave2"

# ---------------------------------------------------------------------------
# Hard invariants. A change that moves any of these is a bad change.
# ---------------------------------------------------------------------------
hr; echo "INVARIANTS"
M="$("$OUT/metrics" 2>&1)"
W="$("$OUT/wave2" 2>&1)"

check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1 = $2"
  else echo "  FAIL  $1 = $2 (expected $3)"; fail=1; fi
}

check "regression FPR"       "$(echo "$M" | grep -m1 'FPR:'        | awk '{print $2}')" "0.00%"
check "regression recall"    "$(echo "$M" | grep -m1 'recall:'     | awk '{print $2}')" "100.0%"
check "wave-2 false positives" "$(echo "$W" | grep -m1 'false positives:' | awk '{print $3}')" "0/35"

echo "$M" | grep -m1 'catch rate:'
echo "$W" | grep -m1 'caught by T1+T2:'
echo "$W" | grep -m1 'coverage ceiling:'
echo "$W" | grep -m1 'silent misses:'

if [ "${1:-}" = "app" ]; then
  hr; echo "BUILDING iOS APP"
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
  UDID=20246FF0-CFF2-416A-8017-E99BFEE02AB2
  cd "$ROOT" || exit 1
  if xcodebuild -project WayzyyChat.xcodeproj -scheme WayzyyChat \
      -sdk iphonesimulator -destination "id=$UDID" -configuration Debug \
      CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/wzdd build 2>&1 \
      | tail -4 | grep -q "BUILD SUCCEEDED"; then
    echo "  BUILD SUCCEEDED"
    xcrun simctl terminate "$UDID" com.wayzyy.chatmoderation >/dev/null 2>&1
    xcrun simctl install "$UDID" /tmp/wzdd/Build/Products/Debug-iphonesimulator/WayzyyChat.app >/dev/null 2>&1
    xcrun simctl launch "$UDID" com.wayzyy.chatmoderation >/dev/null 2>&1
    echo "  installed and launched"
  else
    echo "  BUILD FAILED"; fail=1
  fi
fi

hr
[ "$fail" = 0 ] && echo "ALL INVARIANTS HELD" || echo "SOMETHING REGRESSED — see FAIL lines above"
exit $fail
