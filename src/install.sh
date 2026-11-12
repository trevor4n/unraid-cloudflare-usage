#!/bin/bash
# cloudflare.usage install step. The plugin manager runs this after writing the plugin
# files, on first install, on upgrade, and again at every boot.
set -u
PLUG=/usr/local/emhttp/plugins/cloudflare.usage
CFG=/boot/config/plugins/cloudflare.usage

mkdir -p "$CFG"
mkdir -p -m 755 /var/local/cloudflare.usage

# Default settings, only if none exist yet (keeps writes to the flash drive rare).
[[ -f $CFG/cloudflare.usage.cfg ]] || cp "$PLUG/cloudflare.usage.cfg.default" "$CFG/cloudflare.usage.cfg"

# update_cron builds root's crontab from /boot/config/plugins/<name>/*.cron, but
# only for plugins listed in /var/log/plugins. Write the cron file only if it changed.
if ! cmp -s "$PLUG/cloudflare.usage.cron" "$CFG/cloudflare.usage.cron"; then
  cp "$PLUG/cloudflare.usage.cron" "$CFG/cloudflare.usage.cron"
fi

# The plugin manager lists this plugin in /var/log/plugins only after this script
# succeeds, so an update_cron run right now would skip it. Wait for the listing
# in the background, then load the crontab and take the first reading.
setsid bash -c '
  for _ in $(seq 1 600); do [[ -e /var/log/plugins/cloudflare.usage.plg ]] && break; sleep 1; done
  /usr/local/sbin/update_cron
  /usr/local/emhttp/plugins/cloudflare.usage/scripts/poll
' </dev/null >/dev/null 2>&1 &

echo ""
echo "cloudflare.usage installed. Settings: $CFG/cloudflare.usage.cfg"
grep -q '^ACCOUNT_ID="[0-9a-f]\{32\}"' "$CFG/cloudflare.usage.cfg" ||
  echo "Next: set ACCOUNT_ID in that file and save the API token to $CFG/cf-api-token (see the README)."
echo ""
