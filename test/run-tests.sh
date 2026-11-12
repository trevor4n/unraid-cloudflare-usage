#!/bin/bash
# Runs scripts/poll against saved sample API responses (test/fixtures/normal),
# with stand-ins for curl, notify and logger. Needs bash, jq, coreutils and
# python3 (for the .plg check). No network and no Unraid needed.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
POLL=$ROOT/src/scripts/poll
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cloudflare.usage-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

TOKEN="tEsT-ToKeN_0123456789abcdefghijklmnopqrs"   # fake; only checked for leaks
ACCT=0123456789abcdef0123456789abcdef
T0=$(date -u -d 2026-11-12T18:05:00Z +%s)          # fixtures are built around this moment
DAY=86400

CALLS_ALL="workers-week pages-week do-week do_store-week kv-week ai-week d1-week"
ALL_VALUES='[12345, 300, 250, 900, 12.3, 2500, 1234567, 120, 4, 0, 2, 0]'
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
q()     { jq -e "$1" "$CACHE" >/dev/null 2>&1; }                 # assertion on the cache
lines() { [[ -f $1 ]] && wc -l <"$1" || echo 0; }
notes() { lines "$E/notify.log"; }
calls() { paste -sd' ' "$E/curl-calls.log" 2>/dev/null; }

# new_env NAME [configured]: fresh flash + RAM dirs and a copy of the fixtures.
new_env() {
  echo "$1"
  E=$WORK/$1
  mkdir -p "$E/flash" "$E/ram" "$E/fx"
  export CF_TEST_DIR=$E CF_TEST_FIXTURES=$E/fx
  export CF_USAGE_CFG_DIR=$E/flash CF_USAGE_STATE_DIR=$E/ram
  export CF_USAGE_CURL=$ROOT/test/fake-curl CF_USAGE_NOTIFY=$ROOT/test/fake-notify CF_USAGE_LOGGER=$ROOT/test/fake-logger
  CACHE=$E/ram/usage.json
  cp "$ROOT"/test/fixtures/normal/*.json "$E/fx/"
  if [[ ${2:-} == configured ]]; then
    printf 'ACCOUNT_ID="%s"\nTOKEN_FILE="%s"\n' "$ACCT" "$E/flash/cf-api-token" >"$E/flash/cloudflare.usage.cfg"
    printf '%s\n' "$TOKEN" >"$E/flash/cf-api-token"
    touch -d 2026-01-01 "$E/flash/cf-api-token"   # older than the fake clock, so only age triggers token checks
  fi
}

run_at() { # run_at EPOCH [poll args]
  local t=$1; shift
  export CF_USAGE_NOW=$t
  CF_TEST_TODAY=$(date -u -d "@$t" +%F)
  CF_TEST_SINCE=$(date -u -d "$CF_TEST_TODAY -6 days" +%F)
  export CF_TEST_TODAY CF_TEST_SINCE
  : >"$E/curl-calls.log"
  "$POLL" "$@"
}

# set_value DATASET FIELD DAY VALUE: make DAY's total for FIELD equal VALUE in both fixtures.
set_value() {
  local ds=$1 field=$2 day=$3 v=$4 node r f
  case $ds in
    workers) node=workersInvocationsAdaptive ;;
    pages)   node=pagesFunctionsInvocationsAdaptiveGroups ;;
    do)      node=durableObjectsInvocationsAdaptiveGroups ;;
    do_store) node=durableObjectsPeriodicGroups ;;
    d1)      node=d1AnalyticsAdaptiveGroups ;;
    ai)      node=aiInferenceAdaptiveGroups ;;
  esac
  for r in week today; do
    f=$CF_TEST_FIXTURES/$ds-$r.json
    jq --arg n "$node" --arg f "$field" --arg d "$day" --argjson v "$v" '
      def day: .dimensions.date // (.dimensions.datetimeHour // "")[0:10];
      .data.viewer.accounts[0][$n] |= (
        (map(select(day == $d)) | .[0] // {sum: {}, dimensions:
          (if $n == "workersInvocationsAdaptive" then {datetimeHour: ($d + "T10:00:00Z")} else {date: $d} end)}) as $row
        | map(select(day != $d)) + [$row | .sum[$f] = $v])' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
}

fail_all() { # fail_all CODE BODY: every dataset/range answers with this
  local ds r
  for ds in workers pages do do_store kv ai d1; do for r in week today; do
    printf '%s' "$2" >"$CF_TEST_FIXTURES/$ds-$r.json"
    printf '%s' "$1" >"$CF_TEST_FIXTURES/$ds-$r.code"
  done; done
  for v in verify-account verify-user; do
    printf '%s' "$2" >"$CF_TEST_FIXTURES/$v.json"; printf '%s' "$1" >"$CF_TEST_FIXTURES/$v.code"
  done
}

no_token_leak() { # the token appears only in the token file and in curl's stdin
  ! grep -rqF -- "$TOKEN" "$E/ram" "$E/flash/cloudflare.usage.cfg" "$E/flash"/*.json "$E/flash/alerts.sent" \
      "$E/curl-argv.log" "$E/syslog.log" "$E/notify.log" 2>/dev/null
}

# ---------------------------------------------------------------------------
new_env unconfigured
run_at "$T0"
check "exits cleanly and writes a cache" test -s "$CACHE"
check "cache explains the missing setup" q '.error | startswith("Not set up: no Cloudflare account ID yet. Open Settings → Cloudflare Usage")'
check "no API calls without config" test -z "$(calls)"
check "no values, no alerts" q 'all(.metrics[]; .value == null)'
check "no notifications" test "$(notes)" = 0

# ---------------------------------------------------------------------------
new_env normal configured
run_at "$T0"
check "UTC day and next reset" q ".day == \"2026-11-12\" and .reset == $(date -u -d 2026-11-13T00:00:00Z +%s)"
check "Workers requests today = 12,345 (summed from hourly rows)" q '.metrics[] | select(.id == "workers") | .value == 12345 and .cap == 100000'
check "Durable Objects requests today = 300" q '.metrics[] | select(.id == "do") | .value == 300'
check "D1 rows written today = 2,500" q '.metrics[] | select(.id == "d1_write") | .value == 2500'
check "D1 rows read today = 1,234,567 (cap 5M)" q '.metrics[] | select(.id == "d1_read") | .value == 1234567 and .cap == 5000000'
check "DO storage rows and duration today (SQLite-backed DOs)" q '[.metrics[] | select(.id | startswith("do_")) | [.id, .value, .cap]] == [["do_write", 250, 100000], ["do_read", 900, 5000000], ["do_gbs", 12.3, 13000]]'
check "twelve caps, in display order" q '[.metrics[].id] == ["workers", "do", "do_write", "do_read", "do_gbs", "d1_write", "d1_read", "kv_read", "kv_write", "kv_delete", "kv_list", "ai"]'
check "KV and Workers AI values" q '[.metrics[7:][] | .value] == [120, 4, 0, 2, 0]'
check "unused optional caps are hidden, used ones shown" q '[.metrics[] | select(.visible | not) | .id] == ["kv_delete", "ai"]'
check "Worker errors counted, below the alert threshold" q '.metrics[0] | .errors == 12 and .requests_only == 12345 and .pages == 0 and .errors_high == false'
check "token expiry read from the verify endpoint" q ".token.status == \"active\" and .token.expires == $(date -u -d 2027-11-12 +%s)"
check "every metric fetched now, no errors" q "all(.metrics[]; .fetched == $T0 and .error == \"\")"
check "7 history days, oldest first" q '[.history[].day] == ["2026-11-06","2026-11-07","2026-11-08","2026-11-09","2026-11-10","2026-11-11","2026-11-12"]'
check "day with no rows is filled with 0" q '.history[2] == {day: "2026-11-08", workers: 0, do: 0, do_write: 0, do_read: 0, do_gbs: 0, d1_write: 0, d1_read: 0, kv_read: 0, kv_write: 0, kv_delete: 0, kv_list: 0, ai: 0}'
check "history values from the API" q '.history[0].workers == 8200 and .history[5].d1_read == 3900000 and .history[4].do == 1200'
check "one 7-day query per dataset, plus one token check" test "$(calls)" = "$CALLS_ALL verify-account"
check "auth header sent on stdin" grep -qxF "header = \"Authorization: Bearer $TOKEN\"" "$E/curl-stdin.log"
check "token never in argv, cache, history, logs" no_token_leak
check "no notifications below 75%" test "$(notes)" = 0
check "nothing logged when all is well" test "$(lines "$E/syslog.log")" = 0
check "completed days saved to flash, today excluded" jq -e 'keys == ["2026-11-06","2026-11-07","2026-11-08","2026-11-09","2026-11-10","2026-11-11"]' "$E/flash/history.json"
check "cache readable by the web UI (0644)" test "$(stat -c %a "$CACHE")" = 644
before=$(stat -c %Y.%s "$E/flash/history.json")
touch -d '2 hours ago' "$E/flash/history.json"; before=$(stat -c %Y "$E/flash/history.json")
run_at $((T0 + 600))
check "unchanged history is not rewritten to flash" test "$(stat -c %Y "$E/flash/history.json")" = "$before"

# ---------------------------------------------------------------------------
new_env thresholds configured
set_value workers requests 2026-11-12 76000
run_at "$T0"
check "75% sends one warning" test "$(notes)" = 1
check "warning text" grep -qxF "warning | Workers requests at 76% of the free daily cap | 76,000 of 100,000 used today (UTC). Resets at 00:00 UTC, in 5 h 55 min." "$E/notify.log"
check "alert recorded on flash" grep -qx "2026-11-12 workers 75" "$E/flash/alerts.sent"
run_at $((T0 + 600))
check "same threshold, same day: no repeat" test "$(notes)" = 1
set_value workers requests 2026-11-12 91000
run_at $((T0 + 1200))
check "90% sends one alert" test "$(notes)" = 2
check "alert text" grep -qF "alert | Workers requests at 91% of the free daily cap" "$E/notify.log"
run_at $((T0 + 1800))
check "no repeat at 90% either" test "$(notes)" = 2
set_value d1 rowsRead 2026-11-12 4750000
run_at $((T0 + 2400))
check "jump straight past 90% sends only the 90% alert" test "$(notes)" = 3
check "D1 alert text" grep -qF "alert | D1 rows read at 95% of the free daily cap | 4,750,000 of 5,000,000" "$E/notify.log"
check "both thresholds marked as sent" bash -c "grep -qx '2026-11-12 d1_read 75' '$E/flash/alerts.sent' && grep -qx '2026-11-12 d1_read 90' '$E/flash/alerts.sent'"
set_value do_store rowsWritten 2026-11-12 80000
run_at $((T0 + 3000))
check "DO storage rows written alert" grep -qF "warning | DO storage rows written at 80% of the free daily cap | 80,000 of 100,000" "$E/notify.log"
# Next UTC day: alerts re-arm, yesterday's records are pruned.
set_value workers requests 2026-11-13 80000
run_at $((T0 + DAY))
check "new UTC day re-arms the 75% alert" bash -c "test \$(wc -l <'$E/notify.log') = 5 && tail -n 1 '$E/notify.log' | grep -qF 'warning | Workers requests at 80% of the free daily cap'"
check "yesterday's alert records pruned" bash -c "! grep -q '^2026-11-12' '$E/flash/alerts.sent' && grep -qx '2026-11-13 workers 75' '$E/flash/alerts.sent'"
check "history rolls forward a day" q '.day == "2026-11-13" and .history[0].day == "2026-11-07" and .history[6].day == "2026-11-13" and .history[5].workers == 91000'
check "token never leaked" no_token_leak

# ---------------------------------------------------------------------------
new_env fallback configured
range_err='{"data":null,"errors":[{"message":"number of seconds in the time range exceeds the limit","path":["viewer","accounts",0,"node"]}]}'
for ds in workers pages do do_store kv ai d1; do printf '%s' "$range_err" >"$E/fx/$ds-week.json"; done
printf '{"2026-11-10":{"workers":5000,"do":7,"d1_read":10,"d1_write":1}}\n' >"$E/flash/history.json"
run_at "$T0"
check "rejected 7-day range falls back to today" test "$(calls)" = "workers-week workers-today pages-week pages-today do-week do-today do_store-week do_store-today kv-week kv-today ai-week ai-today d1-week d1-today verify-account"
check "today's values still correct" q "[.metrics[].value] == $ALL_VALUES and all(.metrics[]; .error == \"\")"
check "earlier days come from the saved history" q '.history[4] | .day == "2026-11-10" and .workers == 5000 and .do == 7 and .d1_read == 10 and .d1_write == 1 and .do_write == null'
check "days never seen show as no data" q '.history[2] | .day == "2026-11-08" and ([to_entries[] | select(.key != "day") | .value] | all(. == null))'

# ---------------------------------------------------------------------------
new_env auth configured
fail_all 403 '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"messages":[],"result":null}'
run_at "$T0"
check "HTTP error shown per metric" q 'all(.metrics[]; (.error | contains("HTTP 403: Authentication error")) and .value == null and .fetched == null)'
check "HTTP errors do not retry with a smaller range" test "$(calls)" = "$CALLS_ALL verify-account verify-user"
check "error logged once" test "$(lines "$E/syslog.log")" = 1
run_at $((T0 + 600))
check "same error not logged again" test "$(lines "$E/syslog.log")" = 1
check "no failure notice before ~50 min" test "$(notes)" = 0
run_at $((T0 + 3000))
check "failure notice after ~50 min of total failure" grep -qF "warning | Cloudflare usage check is failing" "$E/notify.log"
run_at $((T0 + 3600))
check "failure notice sent once a day" test "$(notes)" = 1
rm -f "$E"/fx/*; cp "$ROOT"/test/fixtures/normal/*.json "$E/fx/"
run_at $((T0 + 4200))
check "recovery clears the failure streak" test ! -e "$E/ram/failing-since"
check "recovery logged" grep -qF "Cloudflare usage check OK again" "$E/syslog.log"
check "values back after recovery" q "[.metrics[].value] == $ALL_VALUES"
check "token never leaked" no_token_leak

new_env graphql-denied configured
fail_all 200 '{"data":null,"errors":[{"message":"not authorized for that account","path":["viewer","accounts"]}]}'
run_at "$T0"
check "GraphQL error message shown" q 'all(.metrics[]; .error | contains("not authorized for that account"))'

new_env wrong-account configured
fail_all 200 '{"data":{"viewer":{"accounts":[]}},"errors":null}'
run_at "$T0"
check "empty account list explained" q 'all(.metrics[]; .error | contains("Account not found"))'

# ---------------------------------------------------------------------------
new_env partial configured
run_at "$T0"
rm -f "$E/fx/do-week.json" "$E/fx/do-today.json"
run_at $((T0 + 600))
check "network failure on one dataset is shown on it" q '.metrics[] | select(.id == "do") | .error == "do: Could not reach Cloudflare: curl: (6) Could not resolve host: api.cloudflare.com"'
check "its last value stays, with the old timestamp" q ".metrics[] | select(.id == \"do\") | .value == 300 and .fetched == $T0"
check "other datasets still refresh" q ".metrics[] | select(.id == \"workers\") | .fetched == $((T0 + 600))"
check "partial failure is not a total failure" test ! -e "$E/ram/failing-since"

# ---------------------------------------------------------------------------
new_env check configured
out=$(run_at "$T0" --check); rc=$?
check "--check succeeds" test "$rc" = 0
check "--check reports limits and fields" grep -qxF "workersInvocationsAdaptive: enabled=true, max range 31 days, history 92 days, needed fields present" <<<"$out"
check "--check covers DO storage" grep -qxF "durableObjectsPeriodicGroups: enabled=true, max range 31 days, history 92 days, needed fields present" <<<"$out"
check "--check reports today's totals" grep -qxF 'workers: today {"workers":12345,"workers_err":12}, days returned: 7' <<<"$out"
check "--check reports the token's expiry" grep -qxF 'Token: active, expires 2027-11-12 (in 364 days)' <<<"$out"
check "--check covers KV and Workers AI" bash -c 'grep -qx "kvOperationsAdaptiveGroups: enabled=true, .*needed fields present" <<<"$1" && grep -qxF "ai: today {\"ai\":0}, days returned: 7" <<<"$1"' _ "$out"
check "--check writes no cache" test ! -e "$CACHE"
check "--check never prints the token" bash -c '! grep -qF -- "$1" <<<"$2"' _ "$TOKEN" "$out"
jq '.data.viewer.accounts[0].settings.workersInvocationsAdaptive.availableFields -= ["dimensions_datetimeHour"]' \
  "$E/fx/settings-today.json" >"$E/fx/s.tmp" && mv "$E/fx/s.tmp" "$E/fx/settings-today.json"
out=$(run_at "$T0" --check)
check "--check flags a missing field" grep -qF "MISSING fields: dimensions_datetimeHour" <<<"$out"

# ---------------------------------------------------------------------------
new_env crlf configured
printf 'ACCOUNT_ID="%s"\r\nTOKEN_FILE="%s"\r\n' "$ACCT" "$E/flash/cf-api-token" >"$E/flash/cloudflare.usage.cfg"
printf '%s\r\n' "$TOKEN" >"$E/flash/cf-api-token"
run_at "$T0"
check "config and token with CRLF line endings work" q '.error == "" and (.metrics[0].value == 12345)'

new_env bad-token configured
printf 'abc"def\n' >"$E/flash/cf-api-token"
run_at "$T0"
check "unsafe token rejected before any call" q '.error | contains("saved API token isn'"'"'t valid")'
check "no API calls with a bad token" test -z "$(calls)"

new_env empty-token configured
printf '\n' >"$E/flash/cf-api-token"
run_at "$T0"
check "empty token file gets its own message" q '.error | contains("The saved API token is empty")'

new_env caps configured
printf 'CAP_WORKERS="50000"\nCAP_D1_READ="oops"\n' >>"$E/flash/cloudflare.usage.cfg"
run_at "$T0"
check "cap override applies, bad value falls back" q '(.metrics[] | select(.id == "workers") | .cap == 50000) and (.metrics[] | select(.id == "d1_read") | .cap == 5000000)'

# ---------------------------------------------------------------------------
new_env schedule configured
run_at "$T0" --cron
check "first cron wake-up with no cache checks" test "$(calls)" = "$CALLS_ALL verify-account"
check "below 75%: next check in 15 min" q ".interval == 900 and .next == $((T0 + 900))"
run_at $((T0 + 600)) --cron
check "wake-up before it's due makes no API calls" test -z "$(calls)"
check "and leaves the cache alone" q ".generated == $T0"
run_at $((T0 + 780)) --cron
check "wake-up up to 2 min early counts as due (cron jitter)" test "$(calls)" = "$CALLS_ALL"
run_at $((T0 + 840))
check "a plain run always checks (token looked up once a day, not every run)" test "$(calls)" = "$CALLS_ALL"

new_env tier-75 configured
set_value workers requests 2026-11-12 76000
run_at "$T0"
check "from 75%: every 10 min" q '.interval == 600'

new_env tier-85 configured
set_value d1 rowsRead 2026-11-12 4300000
run_at "$T0"
check "from 85% of any cap: every 5 min" q '.interval == 300'

new_env not-set-up
run_at "$T0"
check "not set up: re-read settings every 5 min" q '.interval == 300'

new_env rate configured
set_value workers requests 2026-11-12 50000
run_at "$T0"
set_value workers requests 2026-11-12 65000
run_at $((T0 + 900))
check "growth that reaches 75% in 10 min brings the check forward" q '.interval == 600'
set_value workers requests 2026-11-12 65000
run_at $((T0 + 1500))
check "flat usage goes back to the usage tier" q '.interval == 900'

new_env spike configured
set_value workers requests 2026-11-12 20000
run_at "$T0"
set_value workers requests 2026-11-12 70000
run_at $((T0 + 900))
check "fast spike: next check in 5 min (the floor)" q '.interval == 300'

# ---------------------------------------------------------------------------
expire_in() { # expire_in DAYS: the verify endpoint reports an expiry DAYS after T0
  jq -n --arg e "$(date -u -d "@$((T0 + $1 * DAY + 3600))" +%FT%TZ)" \
    '{success: true, errors: [], result: {id: "x", status: "active", expires_on: $e}}' >"$E/fx/verify-account.json"
  rm -f "$E/ram/token.json"   # look it up again on the next run
}

new_env token-expiry configured
expire_in 20
run_at "$T0"
check "token expiring within 30 days: one warning" grep -qxF "warning | Cloudflare API token expires in 20 days | The read-only token Cloudflare Usage uses expires on $(date -u -d "@$((T0 + 20 * DAY + 3600))" +%F) (UTC). After that, usage checks and cap alerts stop." "$E/notify.log"
run_at $((T0 + DAY + 60))
check "not repeated the next day" test "$(notes)" = 1
check "the record survives the daily cleanup" grep -q '^token ' "$E/flash/alerts.sent"
expire_in 5
run_at $((T0 + DAY + 120))
check "within 7 days: an alert" bash -c "tail -n 1 '$E/notify.log' | grep -qF 'alert | Cloudflare API token expires in 4 days'"
expire_in 400
run_at $((T0 + DAY + 180))
check "a new token clears the warnings" test "$(notes)" = 2
check "tile data carries the new expiry" q ".token.expires == $((T0 + 400 * DAY + 3600))"

new_env token-unknown configured
rm -f "$E/fx/verify-account.json" "$E/fx/verify-user.json"
run_at "$T0"
check "token lookup failing doesn't affect usage checks" q '.token == {} and .metrics[0].value == 12345 and .metrics[0].error == ""'

new_env worker-errors configured
set_value workers errors 2026-11-12 800
run_at "$T0"
check "high Worker error rate: one warning" grep -qF "warning | Cloudflare Worker errors: 800 failed requests today | 800 of 2,345 Worker requests failed today (UTC), 34%." "$E/notify.log"
run_at $((T0 + 600))
check "error warning sent once a day" test "$(notes)" = 1
check "tile data flags the error rate" q '.metrics[0].errors_high == true'

new_env pages configured
set_value pages requests 2026-11-12 500
run_at "$T0"
check "Pages Functions requests count toward the Workers cap" q '.metrics[0] | .value == 12845 and .pages == 500 and .requests_only == 12345'

new_env kv-cap configured
for r in week today; do
  jq '.data.viewer.accounts[0].kvOperationsAdaptiveGroups |= map(if .dimensions.date == "2026-11-12" and .dimensions.actionType == "write" then .sum.requests = 800 else . end)' \
    "$E/fx/kv-$r.json" >"$E/fx/kv.tmp" && mv "$E/fx/kv.tmp" "$E/fx/kv-$r.json"
done
run_at "$T0"
check "KV writes: 80% of the 1,000-a-day cap warns" grep -qF "warning | KV writes at 80% of the free daily cap | 800 of 1,000 used today (UTC)." "$E/notify.log"

new_env ai-used configured
set_value ai totalNeurons 2026-11-10 150
run_at "$T0"
check "Workers AI appears once used this week" q '.metrics[] | select(.id == "ai") | .visible == true and .value == 0'

# ---------------------------------------------------------------------------
echo "plugin file"
REL_VERSION=$(sed -n 's/^<!ENTITY version "\(.*\)">$/\1/p' "$ROOT/cloudflare.usage.plg")
PLG_OUT=$WORK/cloudflare.usage.plg "$ROOT/build.sh" "$REL_VERSION" >/dev/null
check "cloudflare.usage.plg is well-formed and inlines the sources unchanged" python3 -I - "$ROOT" "$WORK/cloudflare.usage.plg" <<'PY'
import sys, xml.etree.ElementTree as ET
root = sys.argv[1]
plg = ET.parse(sys.argv[2]).getroot()
assert plg.get("name") == "cloudflare.usage" and plg.get("min") == "7.0.0", plg.attrib
assert plg.get("launch") == "Settings/CloudflareUsage", plg.attrib          # icon on the Plugins page opens settings
assert plg.get("support", "").startswith("https://github.com/"), plg.attrib
files = {f.get("Name"): f for f in plg.findall("FILE") if f.get("Name")}
want = {
    "CloudflareUsageTile.page": "src/CloudflareUsageTile.page", "include/tile.php": "src/include/tile.php",
    "CloudflareUsage.page": "src/CloudflareUsage.page", "README.md": "src/plugin-README.md",
    "include/settings_lib.php": "src/include/settings_lib.php", "include/save.php": "src/include/save.php",
    "tile.css": "src/tile.css", "tile.js": "src/tile.js",
    "scripts/poll": "src/scripts/poll", "cloudflare.usage.cron": "src/cloudflare.usage.cron",
    "cloudflare.usage.cfg.default": "src/cloudflare.usage.cfg.default",
}
for name, src in want.items():
    f = files[f"/usr/local/emhttp/plugins/cloudflare.usage/{name}"]
    # the plugin manager writes trim(INLINE) + "\n"
    assert f.find("INLINE").text.strip() + "\n" == open(f"{root}/{src}").read().strip() + "\n", name
assert files["/usr/local/emhttp/plugins/cloudflare.usage/scripts/poll"].get("Mode") == "0755"
runs = [f for f in plg.findall("FILE") if f.get("Run")]
assert [f.get("Method") for f in runs] == [None, None, "remove"], [f.attrib for f in runs]
assert "rm -rf /usr/local/emhttp/plugins/cloudflare.usage" in runs[0].find("INLINE").text
version = plg.get("version")
assert f"Cloudflare Usage {version}" in runs[1].find("INLINE").text and "@VERSION@" not in runs[1].find("INLINE").text
assert not plg.findall(".//URL"), "plugin must not download anything"
PY
check "release cloudflare.usage.plg is up to date with src/ (rebuild with ./build.sh)" \
  bash -c 'diff <(sed "s/ pluginURL=\"[^\"]*\"//" "$1") "$2"' _ "$ROOT/cloudflare.usage.plg" "$WORK/cloudflare.usage.plg"
check "tile wraps its own text, so it can't widen the Dashboard" grep -qF '#cfu-body { white-space: normal; }' "$ROOT/src/tile.css"
check "release notes cover the release version" grep -qx "###$REL_VERSION" "$ROOT/CHANGES.md"
check "page registers on the Dashboard with Markdown off" bash -c "head -n 3 '$ROOT/src/CloudflareUsageTile.page' | tr '\n' ' ' | grep -qx 'Menu=\"Dashboard:0\" Markdown=\"false\" --- '"
check "tile has no nested <table>/<tbody> (the Dashboard script would break)" bash -c "test \$(grep -o '<tbody' '$ROOT/src/include/tile.php' | wc -l) = 1 && ! grep -q '<table' '$ROOT/src/include/tile.php'"
check "cron wakes the poller every 5 minutes in --cron mode" grep -qx '2,7,12,17,22,27,32,37,42,47,52,57 \* \* \* \* /usr/local/emhttp/plugins/cloudflare.usage/scripts/poll --cron >/dev/null 2>&1' "$ROOT/src/cloudflare.usage.cron"
check "shell scripts parse" bash -c "bash -n '$POLL' && bash -n '$ROOT/src/install.sh' && bash -n '$ROOT/src/remove.sh'"

echo "tile"
if command -v php >/dev/null; then
  if "$ROOT/test/run-tile-test.sh" >"$WORK/tile.log" 2>&1; then ok "tile renders correctly (test/run-tile-test.sh)"
  else bad "tile render test"; sed 's/^/        /' "$WORK/tile.log"; fi
else
  echo "  skip  tile render test needs php-cli (then run test/run-tile-test.sh)"
fi

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
