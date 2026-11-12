#!/bin/bash
# Builds tile caches with scripts/poll from the sample API responses, moves
# them to today's date (the tile compares the cache day with the clock), then
# runs tile-test.php. Needs php-cli.
#
#   test/run-tile-test.sh [PREVIEW_HTML]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
command -v php >/dev/null || { echo "php not found; install php-cli to run the tile test" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/cloudflare.usage-tile.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/out"

export CF_USAGE_CURL=$ROOT/test/fake-curl CF_USAGE_NOTIFY=$ROOT/test/fake-notify CF_USAGE_LOGGER=$ROOT/test/fake-logger
export CF_USAGE_NOW=$(date -u -d 2026-11-12T18:05:00Z +%s) CF_TEST_TODAY=2026-11-12 CF_TEST_SINCE=2026-11-06

poll_case() { # poll_case NAME [configured] -> $W/out/NAME.json (still dated 2026-11-12)
  local e=$W/$1
  mkdir -p "$e/flash" "$e/ram" "$e/fx"
  cp "$ROOT"/test/fixtures/normal/*.json "$e/fx/"
  export CF_TEST_DIR=$e CF_TEST_FIXTURES=$e/fx CF_USAGE_CFG_DIR=$e/flash CF_USAGE_STATE_DIR=$e/ram
  if [[ ${2:-} == configured ]]; then
    printf 'ACCOUNT_ID="0123456789abcdef0123456789abcdef"\nTOKEN_FILE="%s/tok"\n' "$e/flash" >"$e/flash/cloudflare.usage.cfg"
    printf 'tEsT-ToKeN_0123456789abcdefghijklmnopqrs\n' >"$e/flash/tok"
  fi
  [[ -z ${PREP:-} ]] || $PREP "$e/fx"
  "$ROOT/src/scripts/poll"
  cp "$e/ram/usage.json" "$W/out/$1.json"
}

today_rows() { # FILE NODE FIELD VALUE: set 2026-11-12's total for FIELD in a week fixture
  jq --arg n "$2" --arg f "$3" --argjson v "$4" '
    def day: .dimensions.date // (.dimensions.datetimeHour // "")[0:10];
    .data.viewer.accounts[0][$n] |= ((map(select(day == "2026-11-12")) | .[0]) as $row
      | map(select(day != "2026-11-12")) + [$row | .sum[$f] = $v])' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}
levels() { # 80% orange, 60% yellow, 120% and 92% red
  today_rows "$1/workers-week.json" workersInvocationsAdaptive requests 80000
  today_rows "$1/do-week.json" durableObjectsInvocationsAdaptiveGroups requests 60000
  today_rows "$1/d1-week.json" d1AnalyticsAdaptiveGroups rowsWritten 120000
  today_rows "$1/d1-week.json" d1AnalyticsAdaptiveGroups rowsRead 4600000
}

poll_case normal configured
PREP=levels poll_case levels configured
poll_case unconfigured

# Move a cache to day D (UTC) with data fetched AGE seconds ago.
move_to() { # SRC DST D AGE
  local d=$3 now dates
  now=$(date -u +%s)
  dates=$(for i in 6 5 4 3 2 1 0; do date -u -d "$d -$i days" +%F; done | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq --arg d "$d" --argjson reset "$(date -u -d "$d +1 day" +%s)" --argjson now "$now" --argjson age "$4" --argjson dates "$dates" '
    .day = $d | .reset = $reset | .generated = ($now - $age) | .next = ($now - $age + (.interval // 900))
    | .metrics |= map(if .fetched == null then . else .fetched = ($now - $age) end)
    | .history |= [to_entries[] | .value.day = $dates[.key] | .value]' "$W/out/$1.json" >"$W/tmp.json"
  mv "$W/tmp.json" "$W/out/$2.json"
}
TODAY=$(date -u +%F)
move_to normal normal "$TODAY" 120
move_to levels levels "$TODAY" 120
move_to unconfigured unconfigured "$TODAY" 0
move_to normal old "$(date -u -d "$TODAY -1 day" +%F)" 90000
jq '.metrics[1].error = "<script>alert(1)</script> HTTP 503: upstream unavailable"' "$W/out/normal.json" >"$W/out/error.json"

rc=0
php "$ROOT/test/tile-test.php" "$W/out" "${1:-}" || rc=1
mkdir -p "$W/settings"
php "$ROOT/test/settings-test.php" "$W/settings" || rc=1
exit $rc
