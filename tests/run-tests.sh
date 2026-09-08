#!/usr/bin/env bash
# Data-source tests for claude-quota-json. No network and no ccusage install:
# the local path runs against pre-seeded cache files.
#
# Run: ./tests/run-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT=package/contents/scripts/claude-quota-json
FIX=tests/fixtures
pass=0; fail=0

# Pin the zone so the formatted reset times are deterministic.
export TZ=Europe/Paris

check() { # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"
  fi
}

get() { printf '%s' "$OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1],{"d":d}))' "$1" 2>/dev/null; }

echo "local mode reads the cached scans (no ccusage needed)"
# Also the regression guard for E2BIG: these files are handed to node as paths,
# so a scan larger than MAX_ARG_STRLEN (128 KiB) must still go through.
CACHE=$(mktemp -d)
cp "$FIX/ccusage-blocks.json" "$CACHE/claude-quota-blocks-$(id -u).json"
cp "$FIX/ccusage-weekly.json" "$CACHE/claude-quota-weekly-$(id -u).json"
OUT=$(TMPDIR="$CACHE" CLAUDE_QUOTA_MODE=local CLAUDE_QUOTA_CACHE_TTL=600 \
      CLAUDE_QUOTA_TOKEN_LIMIT=1000000 CLAUDE_QUOTA_WEEKLY_LIMIT=2000000 bash "$SCRIPT")
check "local source"           "local"  "$(get 'd["source"]')"
check "local window pct"       "25"     "$(get 'd["window"]["pct"]')"
check "local window tokens"    "250000" "$(get 'd["window"]["tokens"]')"
check "local burn rate"        "500"    "$(get 'd["window"]["burn"]')"
check "local week pct"         "25"     "$(get 'd["week"]["pct"]')"

# A scan past the 128 KiB argv limit: padded so the file is ~400 KiB.
python3 - "$CACHE/claude-quota-blocks-$(id -u).json" <<'PAD'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["blocks"][0]["_pad"] = "x" * 400000
json.dump(d, open(p, "w"))
PAD
OUT=$(TMPDIR="$CACHE" CLAUDE_QUOTA_MODE=local CLAUDE_QUOTA_CACHE_TTL=600 \
      CLAUDE_QUOTA_TOKEN_LIMIT=1000000 CLAUDE_QUOTA_WEEKLY_LIMIT=2000000 bash "$SCRIPT")
check "400 KiB scan survives"  "25"     "$(get 'd["window"]["pct"]')"
rm -rf "$CACHE"

echo "local mode picks the week containing today (ccusage 18.x 'week' field)"
# The current week sits in the MIDDLE of the array, so selecting it proves the
# lookup works rather than the trailing-entry fallback.
WCACHE=$(mktemp -d)
cp "$FIX/ccusage-blocks.json" "$WCACHE/claude-quota-blocks-$(id -u).json"
python3 - "$WCACHE/claude-quota-weekly-$(id -u).json" <<'GEN'
import json, sys, datetime
today = datetime.date.today()
monday = today - datetime.timedelta(days=today.weekday())
weeks = [
    {"week": str(monday - datetime.timedelta(days=14)), "totalTokens": 111, "totalCost": 1.0},
    {"week": str(monday),                               "totalTokens": 500000, "totalCost": 2.5},
    {"week": str(monday - datetime.timedelta(days=7)),  "totalTokens": 222, "totalCost": 3.0},
]
json.dump({"weekly": weeks}, open(sys.argv[1], "w"))
GEN
OUT=$(TMPDIR="$WCACHE" CLAUDE_QUOTA_MODE=local CLAUDE_QUOTA_CACHE_TTL=600 \
      CLAUDE_QUOTA_TOKEN_LIMIT=1000000 CLAUDE_QUOTA_WEEKLY_LIMIT=2000000 bash "$SCRIPT")
check "current week selected"  "500000" "$(get 'd["week"]["tokens"]')"
check "reset days in 1..7"     "True"   "$(get '1 <= d["week"]["remainingDays"] <= 7')"

echo "local mode still accepts the older 'period' field"
python3 - "$WCACHE/claude-quota-weekly-$(id -u).json" <<'GEN'
import json, sys, datetime
today = datetime.date.today()
monday = today - datetime.timedelta(days=today.weekday())
json.dump({"weekly": [{"period": str(monday), "totalTokens": 500000, "totalCost": 2.5}]},
          open(sys.argv[1], "w"))
GEN
OUT=$(TMPDIR="$WCACHE" CLAUDE_QUOTA_MODE=local CLAUDE_QUOTA_CACHE_TTL=600 \
      CLAUDE_QUOTA_TOKEN_LIMIT=1000000 CLAUDE_QUOTA_WEEKLY_LIMIT=2000000 bash "$SCRIPT")
check "legacy period field"    "True"   "$(get '1 <= d["week"]["remainingDays"] <= 7')"

echo "local mode reports unknown reset instead of a bogus 0 days"
python3 - "$WCACHE/claude-quota-weekly-$(id -u).json" <<'GEN'
import json, sys
json.dump({"weekly": [{"whatever": "2026-09-06", "totalTokens": 500000, "totalCost": 2.5}]},
          open(sys.argv[1], "w"))
GEN
OUT=$(TMPDIR="$WCACHE" CLAUDE_QUOTA_MODE=local CLAUDE_QUOTA_CACHE_TTL=600 \
      CLAUDE_QUOTA_TOKEN_LIMIT=1000000 CLAUDE_QUOTA_WEEKLY_LIMIT=2000000 bash "$SCRIPT")
check "unknown reset is null"  "True"   "$(get 'd["week"]["remainingDays"] is None')"
rm -rf "$WCACHE"

echo "an interrupted scan leaves no scratch file behind"
# plasmashell can tear the script down between ticks; /tmp must not collect
# zero-byte leftovers over months of uptime.
ICACHE=$(mktemp -d)
timeout 0.7 env TMPDIR="$ICACHE" CLAUDE_QUOTA_MODE=local bash "$SCRIPT" >/dev/null 2>&1
leftovers=$(find "$ICACHE" -name 'claude-quota-??????' | wc -l)
check "no scratch file left"   "0"      "$leftovers"
rm -rf "$ICACHE"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
