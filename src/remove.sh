#!/bin/bash
# cloudflare.usage remove step. The plugin manager runs update_cron after this, which
# drops the cron entry.
rm -f /boot/config/plugins/cloudflare.usage/cloudflare.usage.cron
rm -rf /usr/local/emhttp/plugins/cloudflare.usage /var/local/cloudflare.usage
echo ""
echo "cloudflare.usage removed. Your settings, API token and history remain in /boot/config/plugins/cloudflare.usage."
echo "Delete that folder to remove them too:  rm -r /boot/config/plugins/cloudflare.usage"
echo ""
