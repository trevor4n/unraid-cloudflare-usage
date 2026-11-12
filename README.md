# Cloudflare Usage for Unraid

Plugin name: `cloudflare.usage`. An independent project, not affiliated with or endorsed by
Cloudflare, Inc.

An Unraid 7 plugin. It adds a **Cloudflare** tile to the Dashboard showing today's
usage against the Workers Free plan daily caps, and raises Unraid notifications:

- at **75%** (warning) and **90%** (alert) of any cap, once per threshold per UTC day
- **30 days** before the API token expires (warning), then at **7 days** and **1 day** (alerts)
- when **Worker errors** are high: at least 50 failed requests and 5% of requests in a day (warning)

Notifications go wherever your Unraid notifications already go (browser, email, agents).

| Tracked today (UTC)      | Free-plan daily cap | GraphQL dataset → field                                      | On the tile |
| ------------------------ | ------------------- | ------------------------------------------------------------ | ----------- |
| Workers requests         | 100,000 (account)   | `workersInvocationsAdaptive` → `sum.requests` (and `sum.errors`) | always |
| + Pages Functions        | same cap            | `pagesFunctionsInvocationsAdaptiveGroups` → `sum.requests`   | added to Workers |
| Durable Objects requests | 100,000             | `durableObjectsInvocationsAdaptiveGroups` → `sum.requests`   | always |
| DO storage rows written  | 100,000             | `durableObjectsPeriodicGroups` → `sum.rowsWritten`           | always |
| DO storage rows read     | 5,000,000           | `durableObjectsPeriodicGroups` → `sum.rowsRead`              | always |
| DO duration              | 13,000 GB-s         | `durableObjectsPeriodicGroups` → `sum.duration`              | always |
| D1 rows written          | 100,000             | `d1AnalyticsAdaptiveGroups` → `sum.rowsWritten`              | always |
| D1 rows read             | 5,000,000           | `d1AnalyticsAdaptiveGroups` → `sum.rowsRead`                 | always |
| KV reads                 | 100,000             | `kvOperationsAdaptiveGroups` → `sum.requests` by `actionType` | once used this week |
| KV writes / deletes / lists | 1,000 each       | same                                                         | once used this week |
| Workers AI neurons       | 10,000              | `aiInferenceAdaptiveGroups` → `sum.totalNeurons`             | once used this week |

KV and Workers AI are always checked and always alert; they only get a bar once they've
been used in the last 7 days, so the tile stays short for accounts that don't use them.

Durable Objects on Workers Free must use SQLite storage, which has its own rows read and
written caps, separate from D1's. They matter for designs like an API gateway with a
Durable Object per user: one that records usage writes rows on every request, and every
RPC call to a Durable Object counts as a request, so a gateway that calls its limiter
twice per request reaches the DO requests cap at half the Workers cap. `put()`,
`delete()` and `setAlarm()` each count as a row written.

All caps reset at 00:00 UTC. Past the Workers cap, Cloudflare answers with Error 1027
(or skips the Worker on routes set to fail open) until the reset.

## How it works

```
cron, every 5 min ──> scripts/poll --cron ──(when due)──HTTPS──> api.cloudflare.com/client/v4
                            │                  (token from the flash drive, via curl's stdin)
                            ├─> /var/local/cloudflare.usage/usage.json  (cache, RAM, no token)
                            └─> Unraid notify (caps, token expiry, errors)
Dashboard ──> CloudflareUsageTile.page ──> include/tile.php ──reads──> usage.json
Settings → Cloudflare Usage ──> include/save.php ──> config + token on the flash drive
```

- **Check frequency follows usage.** Cron wakes the poller every 5 minutes, but it only
  queries Cloudflare when a check is due, based on the busiest cap:

  | Busiest cap | Check every |
  | --- | --- |
  | below 75% | 15 min |
  | 75% and up | 10 min |
  | 85% and up (approaching the 90% alert, and past it) | 5 min |

  A check also comes sooner when the growth since the previous check would reach the
  next threshold (75%, 90% or the cap) before the scheduled one. So a bot spike that
  starts from low usage is caught within about 5 minutes of the threshold rather than
  up to 15. Five minutes is the floor: Cloudflare's analytics lag a few minutes, so
  checking more often mostly re-reads the same numbers. The tile shows when the next
  check is due. Running `poll` by hand, or saving the settings, always checks immediately.
- **Token expiry** comes from Cloudflare's token verify endpoint, checked once a day and
  whenever the token changes.
- Opening the Dashboard never calls Cloudflare: the tile only reads the cache. A small
  script reloads the tile body from the cache every 5 minutes while the page is open
  and keeps "updated 3 min ago" and "resets in 5 h" current.
- The token never appears in the process list (it reaches curl on stdin with
  `curl -K -`), in the cache, in any page, or in the logs. The settings page accepts a
  token but never shows one back.
- One HTTPS request per dataset per check (seven datasets): 28 an hour normally, 84 an
  hour at most, plus one token check a day. Cloudflare's GraphQL limit is 300 queries
  per 5 minutes.
- Bars turn yellow at 50%, orange at 75% and red at 90%. Small ticks mark 75% and 90%.
- History: the poller asks for the last 7 UTC days, grouped by day. If the plan rejects
  a 7-day range it falls back to today only, and earlier days come from its own history file.
- Only bash, curl, jq and PHP, which all ship with Unraid. No third-party PHP libraries.
  The `.plg` inlines every file, so installing it downloads nothing.

## Install

1. **Install the plugin.** In the Unraid web UI: Plugins → Install Plugin → paste

   ```
   https://raw.githubusercontent.com/trevor4n/unraid-cloudflare-usage/main/cloudflare.usage.plg
   ```

   → Install. The plugin manager copies it to `/boot/config/plugins/` so it reinstalls at
   boot, and Plugins → Check for updates picks up new versions. Plugin auto-update can
   stay off.

2. **Create the token.** Open **Settings → Cloudflare Usage** (or click the plugin's icon
   on the Plugins page) and use **Create a token**. It opens Cloudflare's "Create account
   API token" form with **Account Analytics: Read** and a name already filled in
   (Cloudflare's [token template URL](https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/)).
   Check that Account Analytics: Read is the only permission, pick an expiry (a year is
   reasonable: you'll be warned before it runs out), and create it.

   An account-owned token belongs to the account rather than your login, so it keeps
   working if your user changes. A user token works too: My Profile → API Tokens →
   Custom token, **Account → Account Analytics → Read**, limited to your one account.

3. **Save it.** Back on the settings page, enter your **account ID** (32 characters, from
   the dashboard URL `dash.cloudflare.com/<account-id>/...`), paste the token, and click
   **Save and test**. The page shows what the token can see and today's totals, then the
   Dashboard tile fills in.

4. **Route alerts somewhere you'll see them.** In Settings → Notification Settings, add an
   agent that reaches your phone (Discord, ntfy, Pushover, Telegram…) and tick it for
   **Alerts** only. Then a cap at 90% or a token 7 days from expiry reaches your phone,
   while warnings stay in email. Every notification from this plugin uses the event name
   "Cloudflare usage", so an email filter can label them too.

### From the terminal instead

The settings page writes two files; you can write them yourself:

```bash
sed -i 's/^ACCOUNT_ID=.*/ACCOUNT_ID="<your account id>"/' /boot/config/plugins/cloudflare.usage/cloudflare.usage.cfg
```

```bash
read -rsp 'Cloudflare token: ' t && printf '%s\n' "$t" > /boot/config/plugins/cloudflare.usage/cf-api-token && unset t; echo
```

Check what the token can see (writes nothing, never prints the token), then take a reading:

```bash
/usr/local/emhttp/plugins/cloudflare.usage/scripts/poll --check
```

```bash
/usr/local/emhttp/plugins/cloudflare.usage/scripts/poll
```

Confirm the schedule is loaded, and that notifications reach you:

```bash
crontab -l | grep cloudflare.usage
```

```bash
/usr/local/emhttp/webGui/scripts/notify -e "Cloudflare usage" -s "Cloudflare Usage test" -d "Test notification" -i alert
```

## Files

| On the server | Purpose |
| --- | --- |
| `/usr/local/emhttp/plugins/cloudflare.usage/CloudflareUsageTile.page` | Registers the tile (`Menu="Dashboard:0"`, `$mytiles`), following `DashboardCustomTileExample.page` |
| `/usr/local/emhttp/plugins/cloudflare.usage/CloudflareUsage.page` | Settings page (Settings → User Utilities); the plugin icon links here |
| `/usr/local/emhttp/plugins/cloudflare.usage/include/tile.php` | Renders the tile from the cache; also serves the body refresh |
| `/usr/local/emhttp/plugins/cloudflare.usage/include/save.php`, `settings_lib.php` | Settings endpoint (POST, Unraid's CSRF check) and its helpers |
| `/usr/local/emhttp/plugins/cloudflare.usage/tile.css`, `tile.js` | Tile styles (Unraid theme colours) and the time and refresh updater |
| `/usr/local/emhttp/plugins/cloudflare.usage/scripts/poll` | The poller |
| `/usr/local/emhttp/plugins/cloudflare.usage/README.md` | The description on the Plugins page |
| `/boot/config/plugins/cloudflare.usage/cloudflare.usage.cfg` | Account ID, token path, optional cap and error-alert overrides |
| `/boot/config/plugins/cloudflare.usage/cf-api-token` | The token (mode 600) |
| `/boot/config/plugins/cloudflare.usage/cloudflare.usage.cron` | Cron entry: wakes `poll --cron` at minutes 2, 7, 12 … 57 |
| `/boot/config/plugins/cloudflare.usage/history.json` | Completed days, so history survives a reboot |
| `/boot/config/plugins/cloudflare.usage/alerts.sent` | Which alerts went out (today's, and the current token's) |
| `/var/local/cloudflare.usage/usage.json`, `token.json` | The cache the tile reads, and the token's status and expiry (RAM) |

Plugin code runs from RAM: Unraid reinstalls it from the flash drive at each boot. Writes
to the flash drive are kept rare: the history file when a day completes (or at most every
6 hours if Cloudflare revises a past day), the alert record only when an alert fires, and
the config and token only when you save settings. Nothing goes on the cache pool.

### How the cron entry gets loaded

`/usr/local/sbin/update_cron` concatenates `/boot/config/plugins/dynamix/*.cron` and
`/boot/config/plugins/<name>/*.cron` for every plugin listed as
`/var/log/plugins/<name>.plg`, and installs the result as root's crontab. The plugin
manager adds that listing only after the install script succeeds, so the install
script waits for it in the background and then runs `update_cron` (and a first poll).
This happens on first install, on upgrade and at every boot. Removing the plugin runs
`update_cron` again, which drops the entry.

## Alerts

- **Caps:** 75% of a cap: one **warning**. 90%: one **alert**. Per cap, per UTC day. If
  usage jumps straight past 90% between checks, only the 90% alert is sent.
- **Token expiry:** a **warning** 30 days before, **alerts** at 7 days and 1 day. Sent once
  per token; saving a new token starts over.
- **Worker errors:** one **warning** a day when at least 50 Worker requests failed and they
  were at least 5% of the day's requests (an uncaught exception, or going over the Free
  plan's 10 ms CPU limit). Change `ERROR_ALERT_MIN` and `ERROR_ALERT_PERCENT` in the config.
- **Checks failing:** if every query fails for about an hour (bad or expired token,
  Cloudflare or network down), one warning a day says the usage check is failing, since
  cap alerts can't fire while it is. Errors go to the syslog under the tag
  `cloudflare.usage`, once per change rather than every run.
- **If the checker stops** (for example the cron entry went missing), nothing can send a
  notification; the tile says "No fresh data for over 30 minutes". An outside check, such
  as a free healthchecks.io ping, would close that gap; it isn't built in.
- **How soon an alert arrives:** from 85% checks run every 5 minutes, so the 90% alert
  comes within about 5 minutes plus Cloudflare's few minutes of lag. Below 75% checks
  are 15 minutes apart. Steady growth pulls the next check forward to when the
  threshold should be crossed, but a sudden jump right after a check can still take up
  to 15 minutes (plus lag) to show.

## What it doesn't cover

- **R2:** its free allowance is monthly, and going over is billed rather than blocked, so
  it doesn't fit a daily-cap tile.
- **Durable Objects WebSocket messages:** billing counts incoming messages at 20:1
  toward the requests cap. Messages on non-hibernating WebSockets are reported in
  `durableObjectsPeriodicGroups.inboundWebsocketMsgCount`, which isn't added to the
  requests bar. With the Hibernation API they're already in it.
- **Pages Functions:** added to the Workers bar because they share the cap. If
  `workersInvocationsAdaptive` turns out to include them as well, the bar would
  over-count (which errs toward alerting early); compare with the Cloudflare dashboard
  once you use them.
- Queues, Workers Logs and others aren't tracked.
- Cloudflare's adaptive datasets can be sampled at high volume, so totals are close
  estimates rather than exact billing counts.
- The token sits on the flash drive, which only root can read on the server. If the
  `flash` SMB share is exported, anyone with access to that share can read it too;
  keep the share unexported or private.

## Upgrade and remove

Upgrade: Plugins → Check for updates, then update Cloudflare Usage. The install step
clears the old plugin files first; settings, token and history are kept.

Remove: Plugins → Cloudflare Usage → Remove, or `plugin remove cloudflare.usage.plg`.
Settings, token and history stay in `/boot/config/plugins/cloudflare.usage`; delete that
folder to remove them.

## Development

```bash
./build.sh 2026.11.13    # assemble cloudflare.usage.plg from src/ (add a ###version entry to CHANGES.md first)
./test/run-tests.sh      # poller and plugin tests against saved sample API responses (bash, jq, python3)
./test/run-tile-test.sh  # tile and settings page tests; needs php-cli. Pass a path to also write an HTML preview
```

GitHub Actions runs both on every push, so PHP doesn't need to be installed locally.
The poller honours `CF_USAGE_*` environment overrides (paths, curl, notify, clock) so
the tests run without Unraid or network access. Cron never sets them.

## License

[MIT](LICENSE). Cloudflare is a trademark of Cloudflare, Inc.; the name is used here only
to say what the plugin monitors.
