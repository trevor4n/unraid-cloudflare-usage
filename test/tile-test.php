<?php
/* Renders the tile from caches written by scripts/poll and checks the HTML.
 * Run through test/run-tile-test.sh, which makes the caches first.
 *
 *   php test/tile-test.php CACHE_DIR [PREVIEW_HTML]
 *
 * With PREVIEW_HTML it also writes a standalone page showing each state, for a
 * visual check in a browser.
 */
$dir = $argv[1] ?? exit("usage: php tile-test.php CACHE_DIR [PREVIEW_HTML]\n");
$preview = $argv[2] ?? '';
define('CFU_CACHE', "$dir/current.json");
require __DIR__.'/../src/include/tile.php';

$pass = 0; $fail = 0;
function check($desc, $ok) {
  global $pass, $fail;
  if ($ok) { $pass++; echo "  ok    $desc\n"; } else { $fail++; echo "  FAIL  $desc\n"; }
}
function render($case) {
  global $dir;
  copy("$dir/$case.json", CFU_CACHE);
  return cfu_tile();
}

$pages = [];

echo "tile: normal\n";
$html = render('normal');
$pages['Normal day'] = $html;
check('exactly one tbody, with a title', substr_count($html, '<tbody') === 1 && str_contains($html, "<tbody title='Cloudflare usage'>"));
check('no nested table', !str_contains($html, '<table'));
check('two rows: header and body', substr_count($html, '<tr>') === 2);
check('Unraid 7 tile header markup', str_contains($html, "<span class='tile-header'>") && str_contains($html, "<h3 class='tile-header-main'>Cloudflare</h3>"));
check('one bar per cap (7)', substr_count($html, "class='cfu-bar'") === 7);
check('Workers numbers and percent', str_contains($html, '12,345 / 100,000 <b>12%</b>'));
check('D1 rows read against 5M', str_contains($html, '1,234,567 / 5,000,000 <b>24%</b>'));
check('DO duration in GB-s', str_contains($html, 'DO duration (GB-s)</span><span class=\'cfu-num\'>12 / 13,000 <b>&lt;1%</b>'));
check('low usage is green', substr_count($html, "class='cfu-metric cfu-green'") === 7);
check('bar width', str_contains($html, "<span style='width:12.3%'>"));
check('7 day columns, today last', substr_count($html, "class='cfu-hist-day'") === 7 && str_contains($html, ">Today</span><span class='cfu-hist-label'>"));
check('49 history cells (7 caps x 7 days)', substr_count($html, "class='cfu-col") === 49);
$yesterday = gmdate('Y-m-d', time() - 86400);
check('history tooltip', str_contains($html, "title='$yesterday: 3,900,000 (78%)'"));
check('78% day is orange in history', str_contains($html, "title='$yesterday: 3,900,000 (78%)'><i class='cfu-orange'"));
check('footer has update and reset times', str_contains($html, 'data-cfu-ago=') && str_contains($html, 'data-cfu-reset='));
check('footer shows the next check', str_contains($html, ', next check <span data-cfu-time='));
check('dashboard link uses the account ID', str_contains($html, 'https://dash.cloudflare.com/0123456789abcdef0123456789abcdef/workers-and-pages'));

echo "tile: thresholds\n";
$html = render('levels');
$pages['Near the caps'] = $html;
check('50-75% is yellow', str_contains($html, "cfu-metric cfu-yellow'><div class='cfu-line'><span class='cfu-label'>Durable Objects requests"));
check('75-90% is orange', str_contains($html, "cfu-metric cfu-orange'><div class='cfu-line'><span class='cfu-label'>Workers requests"));
check('90%+ is red', str_contains($html, "cfu-metric cfu-red'><div class='cfu-line'><span class='cfu-label'>D1 rows read"));
check('over the cap clamps the bar at 100%', str_contains($html, '120,000 / 100,000 <b>120%</b>') && str_contains($html, "width:100%'"));

echo "tile: errors\n";
$html = render('error');
$pages['API error'] = $html;
check('error text is escaped', str_contains($html, '&lt;script&gt;') && !str_contains($html, '<script>'));
check('per-metric failure shown', str_contains($html, "<div class='cfu-err'>Last check failed:"));

echo "tile: not set up\n";
$html = render('unconfigured');
$pages['Not set up'] = $html;
check('setup hint shown', str_contains($html, "<div class='cfu-note cfu-warn'>Not set up:"));
check('values shown as dashes', substr_count($html, '– / ') === 7);
check('stale flag when never updated', str_contains($html, "cfu-foot cfu-stale"));

echo "tile: yesterday's cache\n";
$html = render('old');
$pages['Stale (poller stopped)'] = $html;
check('old day shows no values', substr_count($html, '– / ') === 7);
check('old data flagged', str_contains($html, "cfu-foot cfu-stale"));

echo "tile: no cache\n";
@unlink(CFU_CACHE);
$html = cfu_tile();
check('no cache file is handled', str_contains($html, 'No data yet'));

if ($preview) {
  // Static preview: one tile per state. The PHP already renders the relative
  // times, so tile.js is left out (it expects a single #cfu-body).
  $css = file_get_contents(__DIR__.'/../src/tile.css');
  $cells = '';
  foreach ($pages as $title => $tile) {
    $cells .= "<div class='col'><h2>".htmlspecialchars($title)."</h2><table class='dashboard'>$tile</table></div>";
  }
  $page = <<<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>cloudflare.usage tile preview</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/4.7.0/css/font-awesome.min.css">
<style>
:root { --green-500:#17bf0b; --yellow-500:#ffd324; --orange-500:#ff8c2f; --red-700:#de1100;
  --usage-disk-background-color:#e3e3e3; --alt-text-color:#606e7f; color-scheme: light dark; }
@media (prefers-color-scheme: dark) { :root { --usage-disk-background-color:#3a3a3a; --alt-text-color:#a0a0a0; } body { background:#1c1b1b; color:#f2f2f2; } table.dashboard { background:#262626; } }
html { font-size: 62.5%; }
body { font: 1.3rem/1.5 system-ui, sans-serif; margin: 16px; background:#f2f2f2; color:#1c1b1b; }
.grid { display:grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap:16px; }
table.dashboard { width:100%; border-collapse:collapse; background:#fff; border-radius:4px; }
table.dashboard td { padding: 8px 14px; }
.tile-header { display:flex; justify-content:space-between; align-items:center; }
.tile-header-left { display:flex; gap:12px; align-items:center; }
.tile-header-main { margin:0; font-size:1.6rem; }
i.f32 { font-size:32px; }
h2 { font-size:1.3rem; margin:0 0 6px; opacity:.7; }
</style>
<style>$css</style>
</head><body>
<div class="grid">$cells</div>
</body></html>
HTML;
  file_put_contents($preview, $page);
  echo "preview written to $preview\n";
}

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
