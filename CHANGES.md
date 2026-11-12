###2026.11.12b
- Settings page (Settings, User Utilities, Cloudflare Usage; or click the plugin icon): enter the account ID and API token, test the connection, see status and token expiry. The token is write-only.
- Warns 30 days before the API token expires, then alerts at 7 days and 1 day.
- Tracks KV reads, writes, deletes and lists, and Workers AI neurons; their bars appear once used in the last 7 days.
- Pages Functions requests are added to the Workers bar, since they share its cap.
- Warns once a day when Worker errors are high (at least 50 failed requests and 5% of requests).
- Plugin description on the Plugins page, a settings link on the tile, and the version and setup status in the install output.

###2026.11.12a
- The tile wraps its own text, so a long setup message no longer widens every Dashboard tile on narrow screens.
- Before the first update the tile shows when the checker last ran, instead of a "no fresh data" warning.
- Clearer message when the token file is empty.

###2026.11.12
- First release: Dashboard tile for Cloudflare Workers Free plan daily caps (Workers, Durable Objects, D1), with Unraid notifications at 75% and 90% of each cap.
