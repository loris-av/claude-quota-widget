#!/usr/bin/env bash
# Data-source tests for claude-quota-json. No network: the online path reads a
# recorded API response through CLAUDE_QUOTA_USAGE_FILE.
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

echo "online mode, session + weekly_all + weekly_scoped"
OUT=$(CLAUDE_QUOTA_MODE=online CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-session-weekly-scoped.json" bash "$SCRIPT")

check "source"                 "online"                    "$(get 'd["source"]')"
check "timezone reported"      "Europe/Paris"              "$(get 'd["tz"]')"
check "3 limits emitted"       "3"                         "$(get 'len(d["limits"])')"
# /usage wording, driven by kind + scope
check "label session"          "Current session"           "$(get 'd["limits"][0]["label"]')"
check "label weekly_all"       "Current week (all models)" "$(get 'd["limits"][1]["label"]')"
check "label weekly_scoped"    "Current week (Fable)"      "$(get 'd["limits"][2]["label"]')"
check "pct session"            "20"                        "$(get 'd["limits"][0]["pct"]')"
check "pct weekly_all"         "36"                        "$(get 'd["limits"][1]["pct"]')"
check "pct weekly_scoped"      "10"                        "$(get 'd["limits"][2]["pct"]')"
# session shows a bare time, weekly shows a date + time (both local)
check "reset session"          "18:59"                     "$(get 'd["limits"][0]["resetHuman"]')"
check "reset weekly_all"       "Sep 12, 14:59"             "$(get 'd["limits"][1]["resetHuman"]')"
# compact panel view still needs these
check "window.pct (compact)"   "20"                        "$(get 'd["window"]["pct"]')"
check "week.pct (compact)"     "36"                        "$(get 'd["week"]["pct"]')"
# monthly_limit 0 and used_credits 0 => the extra-usage line stays hidden
check "extra hidden when zero" "False"                     "$(get 'd["extra"]["enabled"]')"

echo "online mode, unknown limit kind still surfaces"
OUT=$(CLAUDE_QUOTA_MODE=online CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-unknown-kind.json" bash "$SCRIPT")
check "unknown kind kept"      "2"                         "$(get 'len(d["limits"])')"
check "unknown kind labelled"  "Current week (Opus)"       "$(get 'd["limits"][1]["label"]')"

echo "online mode, garbage response falls back to an error (no cache present)"
EMPTY=$(mktemp -d)
OUT=$(TMPDIR="$EMPTY" CLAUDE_QUOTA_MODE=online CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-garbage.json" bash "$SCRIPT")
check "error on garbage"       "True"                      "$(get '"error" in d')"

echo "online mode, the API's own error type is reported as-is"
OUT=$(TMPDIR="$EMPTY" CLAUDE_QUOTA_MODE=online CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-rate-limited.json" bash "$SCRIPT")
check "429 named as rate limit"  "True"  "$(get '"rate limited" in d["error"]')"
check "429 not blamed on token"  "False" "$(get '"token" in d["error"]')"

OUT=$(TMPDIR="$EMPTY" CLAUDE_QUOTA_MODE=online CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-auth-error.json" bash "$SCRIPT")
check "401 named as token issue" "True"  "$(get '"token" in d["error"]')"
rm -rf "$EMPTY"

echo "auto mode falls back to local when online is rate limited"
# Cache pre-seeded so the fallback resolves from files instead of invoking ccusage.
ACACHE=$(mktemp -d)
cp "$FIX/ccusage-blocks.json" "$ACACHE/claude-quota-blocks-$(id -u).json"
cp "$FIX/ccusage-weekly.json" "$ACACHE/claude-quota-weekly-$(id -u).json"
OUT=$(TMPDIR="$ACACHE" CLAUDE_QUOTA_CACHE_TTL=600 CLAUDE_QUOTA_MODE=auto \
      CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-rate-limited.json" bash "$SCRIPT")
check "auto degrades to local"    "local" "$(get 'd["source"]')"
rm -rf "$ACACHE"

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
check "current week selected"    "500000" "$(get 'd["week"]["tokens"]')"
check "reset days in 1..7"       "True"   "$(get '1 <= d["week"]["remainingDays"] <= 7')"

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
check "legacy period field"      "True"   "$(get '1 <= d["week"]["remainingDays"] <= 7')"

echo "local mode reports unknown reset instead of a bogus 0 days"
python3 - "$WCACHE/claude-quota-weekly-$(id -u).json" <<'GEN'
import json, sys
json.dump({"weekly": [{"whatever": "2026-09-06", "totalTokens": 500000, "totalCost": 2.5}]},
          open(sys.argv[1], "w"))
GEN
OUT=$(TMPDIR="$WCACHE" CLAUDE_QUOTA_MODE=local CLAUDE_QUOTA_CACHE_TTL=600 \
      CLAUDE_QUOTA_TOKEN_LIMIT=1000000 CLAUDE_QUOTA_WEEKLY_LIMIT=2000000 bash "$SCRIPT")
check "unknown reset is null"    "True"   "$(get 'd["week"]["remainingDays"] is None')"
rm -rf "$WCACHE"

echo "a successful online call is cached, then replayed when the API refuses"
OCACHE=$(mktemp -d)
# 1. success -> cache written, reading is fresh
OUT=$(TMPDIR="$OCACHE" CLAUDE_QUOTA_MODE=online \
      CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-session-weekly-scoped.json" bash "$SCRIPT")
check "fresh reading age 0"     "0"      "$(get 'd["ageSeconds"]')"
check "cache file written"      "True"   "$([ -s "$OCACHE/claude-quota-online-$(id -u).json" ] && echo True || echo False)"

# 2. API now refuses -> same layout replayed, flagged with its age
OUT=$(TMPDIR="$OCACHE" CLAUDE_QUOTA_MODE=online \
      CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-rate-limited.json" bash "$SCRIPT")
check "replayed as online"      "online"                    "$(get 'd["source"]')"
check "replay keeps 3 limits"   "3"                         "$(get 'len(d["limits"])')"
check "replay keeps labels"     "Current week (Fable)"      "$(get 'd["limits"][2]["label"]')"
check "replay has no error"     "False"                     "$(get '"error" in d')"
check "reset time recomputed"   "Sep 12, 14:59"             "$(get 'd["limits"][1]["resetHuman"]')"

# 3. auto must NOT drop to the local proxy while a usable cache exists
cp "$FIX/ccusage-blocks.json" "$OCACHE/claude-quota-blocks-$(id -u).json"
cp "$FIX/ccusage-weekly.json" "$OCACHE/claude-quota-weekly-$(id -u).json"
OUT=$(TMPDIR="$OCACHE" CLAUDE_QUOTA_CACHE_TTL=600 CLAUDE_QUOTA_MODE=auto \
      CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-rate-limited.json" bash "$SCRIPT")
check "auto prefers stale online" "online" "$(get 'd["source"]')"

# 4. past the age ceiling, the cache is abandoned
OUT=$(TMPDIR="$OCACHE" CLAUDE_QUOTA_ONLINE_MAX_AGE=0 CLAUDE_QUOTA_CACHE_TTL=600 \
      CLAUDE_QUOTA_MODE=auto CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-rate-limited.json" bash "$SCRIPT")
check "expired cache ignored"     "local"  "$(get 'd["source"]')"

# 5. an old cache is reported with its real age
touch -d "-20 minutes" "$OCACHE/claude-quota-online-$(id -u).json"
OUT=$(TMPDIR="$OCACHE" CLAUDE_QUOTA_MODE=online \
      CLAUDE_QUOTA_USAGE_FILE="$FIX/usage-rate-limited.json" bash "$SCRIPT")
check "age reported ~20 min"      "True"   "$(get '1150 <= d["ageSeconds"] <= 1250')"
rm -rf "$OCACHE"

echo "an interrupted scan leaves no scratch file behind"
# plasmashell can tear the script down between ticks; /tmp must not collect
# zero-byte leftovers over months of uptime.
ICACHE=$(mktemp -d)
timeout 0.7 env TMPDIR="$ICACHE" CLAUDE_QUOTA_MODE=local bash "$SCRIPT" >/dev/null 2>&1
leftovers=$(find "$ICACHE" -name 'claude-quota-??????' | wc -l)
check "no scratch file left"     "0"      "$leftovers"
rm -rf "$ICACHE"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
