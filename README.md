# Cloudflare Usage for Unraid

Plugin name: `cloudflare.usage`. An independent project, not affiliated with or endorsed by
Cloudflare, Inc.

An Unraid 7 plugin. It adds a **Cloudflare** tile to the Dashboard showing today's
usage against the Workers Free plan daily caps, and raises an Unraid notification at
**75%** and **90%** of any cap (once per threshold per UTC day). Notifications go
wherever your Unraid notifications already go (browser, email, agents).

| Tracked today (UTC)       | Free-plan daily cap | GraphQL dataset and field                              |
| ------------------------- | ------------------- | ------------------------------------------------------ |
| Workers requests          | 100,000 (account)   | `workersInvocationsAdaptive` → `sum.requests`          |
| Durable Objects requests  | 100,000             | `durableObjectsInvocationsAdaptiveGroups` → `sum.requests` |
| DO storage rows written   | 100,000             | `durableObjectsPeriodicGroups` → `sum.rowsWritten`     |
| DO storage rows read      | 5,000,000           | `durableObjectsPeriodicGroups` → `sum.rowsRead`        |
| DO duration               | 13,000 GB-s         | `durableObjectsPeriodicGroups` → `sum.duration`        |
| D1 rows written           | 100,000             | `d1AnalyticsAdaptiveGroups` → `sum.rowsWritten`        |
| D1 rows read              | 5,000,000           | `d1AnalyticsAdaptiveGroups` → `sum.rowsRead`           |

Durable Objects on Workers Free must use SQLite storage, which has its own rows
read and written caps, separate from D1's. They matter for designs like an API gateway
with a Durable Object per user: one that records usage writes rows on every request, so at two
rows a request the DO rows-written cap is reached at 50,000 gateway requests, well
before the Workers cap. `put()`, `delete()` and `setAlarm()` each count as a row
written.

All caps reset at 00:00 UTC. Past the Workers cap, Cloudflare answers with Error 1027
(or skips the Worker on routes set to fail open) until the reset.

## How it works

```
cron, every 5 min ──> scripts/poll --cron ──(when due)──HTTPS──> api.cloudflare.com/client/v4/graphql
                            │                  (token from the flash drive, via curl's stdin)
                            ├─> /var/local/cloudflare.usage/usage.json  (cache, RAM, no token)
                            └─> Unraid notify at 75% / 90%
Dashboard ──> CloudflareUsageTile.page ──> include/tile.php ──reads──> usage.json
```

- **Check frequency follows usage.** Cron wakes the poller every 5 minutes, but it only
  queries Cloudflare when a check is due, based on the busiest of the four caps:

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
  check is due. Running `poll` by hand always checks immediately.
- Opening the Dashboard never calls Cloudflare: the tile only reads the cache. A small
  script reloads the tile body from the cache every 5 minutes while the page is open
  and keeps "updated 3 min ago" and "resets in 5 h" current.
- The token never appears in the process list (it reaches curl on stdin with
  `curl -K -`), in the cache, in the page HTML or in the logs.
- One HTTPS request per dataset per check (four datasets): 16 an hour normally, 48
  an hour at most.
  Cloudflare's GraphQL limit is 300 queries per 5 minutes.
- Bars turn yellow at 50%, orange at 75% and red at 90%. Small ticks mark 75% and 90%.
- History: the poller asks for the last 7 UTC days, grouped by day (`datetimeHour`
  buckets for Workers, `date` for DO and D1). If the plan rejects a 7-day range it
  falls back to today only, and earlier days come from its own history file.
- Only bash, curl, jq and PHP, which all ship with Unraid. The `.plg` inlines every
  file, so installing it downloads nothing.

## Install

You need the Cloudflare **account ID** (32 hex characters: it's in the dashboard URL,
`dash.cloudflare.com/<account-id>/...`) and a new API token.

1. **Create the token.** This link opens Cloudflare's "Create account API token" form
   with **Account Analytics: Read** and a name already filled in (Cloudflare's
   [token template URL](https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/)).
   Pick your account if asked, check that Account Analytics: Read is the only
   permission, then create it:

   <https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=%5B%7B%22key%22%3A%22account_analytics%22%2C%22type%22%3A%22read%22%7D%5D&name=Unraid%20Cloudflare%20Usage%20%28analytics%20read%29>

   An account-owned token belongs to the account rather than your login, so it keeps
   working if your user changes. A user token works too: My Profile → API Tokens →
   Custom token, **Account → Account Analytics → Read**, Account Resources limited to
   your one account. A TTL is fine if you're happy to rotate it; the tile shows the
   failure when it expires.

2. **Copy the plugin to the server** (replace `tower` with your server's name), or skip
   to the URL install below:

   ```bash
   scp cloudflare.usage.plg root@tower:/tmp/
   ```

3. **Install it.** In the Unraid web UI: Plugins → Install Plugin → enter
   `/tmp/cloudflare.usage.plg` → Install. Or in the Unraid terminal:

   ```bash
   plugin install /tmp/cloudflare.usage.plg
   ```

   The plugin manager copies it to `/boot/config/plugins/` so it reinstalls at boot.

4. **Add the account ID.** Edit `/boot/config/plugins/cloudflare.usage/cloudflare.usage.cfg` and set
   `ACCOUNT_ID="..."`.

5. **Save the token** in the Unraid web terminal. This prompts without echoing and keeps
   the token out of the shell history:

   ```bash
   read -rsp 'Cloudflare token: ' t && printf '%s\n' "$t" > /boot/config/plugins/cloudflare.usage/cf-api-token && unset t; echo
   ```

6. **Check it.** This prints the dataset limits on your plan, whether the needed fields
   are available, and today's totals. It writes nothing and never prints the token:

   ```bash
   /usr/local/emhttp/plugins/cloudflare.usage/scripts/poll --check
   ```

   Then take a first reading and open the Dashboard (the tile is in the middle column;
   drag it anywhere):

   ```bash
   /usr/local/emhttp/plugins/cloudflare.usage/scripts/poll
   ```

   Confirm the schedule is loaded:

   ```bash
   crontab -l | grep cloudflare.usage
   ```

   Optionally confirm alerts reach you, using the same path the plugin uses:

   ```bash
   /usr/local/emhttp/webGui/scripts/notify -e "Cloudflare usage" -s "Cloudflare Usage test" -d "Test notification" -i warning
   ```

### Installing through UnraidClaw instead

`unraid_plugin_install` only takes a public `https` URL ending in `.plg`. If this repo
is pushed to GitHub, build with its raw URL so the plugin also gets Unraid's "check
for updates", commit, push, then install from that URL:

```bash
PLUGIN_URL=https://raw.githubusercontent.com/trevor4n/unraid-cloudflare-usage/main/cloudflare.usage.plg ./build.sh
```

The repo holds no secrets: the token and account ID live only on the server.

## Files

| On the server | Purpose |
| --- | --- |
| `/usr/local/emhttp/plugins/cloudflare.usage/CloudflareUsageTile.page` | Registers the tile (`Menu="Dashboard:0"`, `$mytiles`), following `DashboardCustomTileExample.page` |
| `/usr/local/emhttp/plugins/cloudflare.usage/include/tile.php` | Renders the tile from the cache; also serves the body refresh |
| `/usr/local/emhttp/plugins/cloudflare.usage/tile.css`, `tile.js` | Tile styles (Unraid theme colours) and the time and refresh updater |
| `/usr/local/emhttp/plugins/cloudflare.usage/scripts/poll` | The poller |
| `/boot/config/plugins/cloudflare.usage/cloudflare.usage.cfg` | Account ID, token path, optional cap overrides |
| `/boot/config/plugins/cloudflare.usage/cf-api-token` | The token (you create it) |
| `/boot/config/plugins/cloudflare.usage/cloudflare.usage.cron` | Cron entry: wakes `poll --cron` at minutes 2, 7, 12 … 57 |
| `/boot/config/plugins/cloudflare.usage/history.json` | Completed days, so history survives a reboot |
| `/boot/config/plugins/cloudflare.usage/alerts.sent` | Which alerts went out today |
| `/var/local/cloudflare.usage/usage.json` | The cache the tile reads (RAM) |

Writes to the flash drive are kept rare: the history file when a day completes (or
at most every 6 hours if Cloudflare revises a past day), the alert record only when
an alert fires.

### How the cron entry gets loaded

`/usr/local/sbin/update_cron` concatenates `/boot/config/plugins/dynamix/*.cron` and
`/boot/config/plugins/<name>/*.cron` for every plugin listed as
`/var/log/plugins/<name>.plg`, and installs the result as root's crontab. The plugin
manager adds that listing only after the install script succeeds, so the install
script waits for it in the background and then runs `update_cron` (and a first poll).
This happens on first install, on upgrade and at every boot. Removing the plugin runs
`update_cron` again, which drops the entry.

## Alerts

- 75% of a cap: one **warning**. 90%: one **alert**. Per metric, per UTC day. If usage
  jumps straight past 90% between checks, only the 90% alert is sent.
- If every query fails for about an hour (bad or expired token, Cloudflare or network
  down), one warning a day says the usage check is failing, since cap alerts can't
  fire while it is. Errors go to the syslog under the tag `cloudflare.usage`, once per change
  rather than every run.
- How soon an alert arrives: from 85% checks run every 5 minutes, so the 90% alert
  comes within about 5 minutes plus Cloudflare's few minutes of lag. Below 75% checks
  are 15 minutes apart. Steady growth pulls the next check forward to when the
  threshold should be crossed, but a sudden jump right after a check can still take up
  to 15 minutes (plus lag) to show. A very fast spike can go from 75% to the cap
  within one check.

## What it doesn't cover

- **Durable Objects WebSocket messages:** billing counts incoming messages at 20:1
  toward the requests cap. Messages on non-hibernating WebSockets are reported in
  `durableObjectsPeriodicGroups.inboundWebsocketMsgCount`, which isn't added to the
  requests bar. With the Hibernation API they're already in it.
- **Pages Functions:** they count toward the Workers request cap. Check
  `poll --check` once one exists to see whether they show up in
  `workersInvocationsAdaptive`.
- **Other free-plan caps:** Workers KV, Workers AI, Queues and others aren't tracked,
  since the service plan doesn't use them. Each would be another dataset in
  `scripts/poll` and a row in the tile.
- Cloudflare's adaptive datasets can be sampled at high volume, so totals are close
  estimates rather than exact billing counts.
- The token sits on the flash drive, which only root can read on the server. If the
  `flash` SMB share is exported, anyone with access to that share can read it too;
  keep the share unexported or private.

## Upgrade and remove

Upgrade: rebuild with a newer version (`./build.sh`, which defaults to today's date)
and install the new `cloudflare.usage.plg` the same way. The install step clears the old
plugin files first.

Remove: Plugins → cloudflare.usage → Remove, or `plugin remove cloudflare.usage.plg`. Settings, token
and history stay in `/boot/config/plugins/cloudflare.usage`; delete that folder to remove them.

## Development

```bash
./build.sh               # assemble cloudflare.usage.plg from src/
./test/run-tests.sh      # poller tests against saved sample API responses (bash, jq, python3)
./test/run-tile-test.sh  # tile render tests; needs php-cli. Pass a path to also write an HTML preview
```

The poller honours `CF_USAGE_*` environment overrides (paths, curl, notify, clock) so
the tests run without Unraid or network access. Cron never sets them.

The poller's syslog lines (errors, recoveries, setup hints) are tagged `cloudflare.usage`:

```bash
grep cloudflare.usage /var/log/syslog
```

## License

[MIT](LICENSE). Cloudflare is a trademark of Cloudflare, Inc.; the name is used here only
to say what the plugin monitors.
