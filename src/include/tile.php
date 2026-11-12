<?php
/* cloudflare.usage: renders the Dashboard tile from the JSON cache written by scripts/poll.
 *
 * It reads only that cache file, so opening the Dashboard never calls Cloudflare,
 * and the cache never holds the API token.
 *
 * CloudflareUsageTile.page includes this file to build the tile. tile.js also fetches
 * it directly every few minutes to refresh the tile body on a long-open Dashboard.
 */

if (!defined('CFU_CACHE')) define('CFU_CACHE', '/var/local/cloudflare.usage/usage.json'); // tests point this elsewhere
const CFU_STALE = 1800; // seconds without fresh data before the tile flags it

function cfu_h($s) {
  return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
}

// Bar colour: below 50%, 50-75%, 75-90%, 90% and up.
function cfu_level($pct) {
  if ($pct >= 90) return 'red';
  if ($pct >= 75) return 'orange';
  if ($pct >= 50) return 'yellow';
  return 'green';
}

function cfu_pct_text($pct) {
  if ($pct > 0 && $pct < 1) return '<1%';
  return floor($pct).'%';
}

function cfu_load() {
  $raw = @file_get_contents(CFU_CACHE);
  if ($raw === false) return null;
  $data = json_decode($raw, true);
  return is_array($data) ? $data : null;
}

function cfu_dur($sec) {
  $min = (int)ceil(max(0, $sec) / 60);
  return $min >= 60 ? intdiv($min, 60).' h '.($min % 60).' min' : $min.' min';
}

// Inner HTML of the tile body. Uses only divs and spans: the Dashboard script
// treats every tbody element on the page as a tile (and needs its title), so a
// nested table here would break the whole Dashboard.
function cfu_body() {
  $d = cfu_load();
  if (!$d) {
    return "<div class='cfu-note'>No data yet. The first check runs right after install, then every 5 to 15 minutes depending on usage.</div>";
  }
  $now = time();
  $today = gmdate('Y-m-d', $now);
  $sameDay = ($d['day'] ?? '') === $today;
  $out = '';

  if (!empty($d['error'])) {
    $out .= "<div class='cfu-note cfu-warn'>".cfu_h($d['error'])."</div>";
  }

  // Today's bars, one per cap.
  $updated = 0;
  foreach (($d['metrics'] ?? []) as $m) {
    $cap = max(1, (int)($m['cap'] ?? 1));
    $has = $sameDay && isset($m['value']) && is_numeric($m['value']);
    $val = $has ? (int)$m['value'] : 0;
    $pct = $val * 100 / $cap;
    $lvl = $has ? cfu_level($pct) : 'none';
    $updated = max($updated, (int)($m['fetched'] ?? 0));
    $label = cfu_h($m['label'] ?? $m['id'] ?? '?');
    $nums = ($has ? number_format($val) : '–').' / '.number_format($cap);
    $pctTxt = $has ? '<b>'.cfu_h(cfu_pct_text($pct)).'</b>' : '';
    $width = $has ? round(min(100, $pct), 1) : 0;
    $out .= "<div class='cfu-metric cfu-$lvl'>"
      ."<div class='cfu-line'><span class='cfu-label'>$label</span><span class='cfu-num'>$nums $pctTxt</span></div>"
      ."<div class='cfu-bar' role='meter' aria-label='$label' aria-valuemin='0' aria-valuemax='$cap' aria-valuenow='$val'>"
      ."<span style='width:$width%'></span></div>";
    if (!empty($m['error'])) {
      $out .= "<div class='cfu-err'>Last check failed: ".cfu_h($m['error'])."</div>";
    }
    $out .= "</div>";
  }

  // Last 7 UTC days, each cell a small column scaled to that day's cap.
  $hist = $d['history'] ?? [];
  if ($hist) {
    $out .= "<div class='cfu-hist' aria-label='Last 7 days, share of each daily cap'>";
    $out .= "<span class='cfu-hist-title'>Last 7 days (UTC)</span>";
    foreach ($hist as $h) {
      $day = $h['day'] ?? '';
      $ts = strtotime("$day 00:00:00 UTC");
      $name = $day === $today ? 'Today' : ($ts ? gmdate('D', $ts) : '?');
      $out .= "<span class='cfu-hist-day' title='".cfu_h($day)."'>".cfu_h($name)."</span>";
    }
    foreach (($d['metrics'] ?? []) as $m) {
      $id = $m['id'] ?? '';
      $cap = max(1, (int)($m['cap'] ?? 1));
      $out .= "<span class='cfu-hist-label'>".cfu_h($m['short'] ?? $id)."</span>";
      foreach ($hist as $h) {
        $day = cfu_h($h['day'] ?? '');
        if (!isset($h[$id]) || !is_numeric($h[$id])) {
          $out .= "<span class='cfu-col cfu-col-none' title='$day: no data'></span>";
          continue;
        }
        $v = (int)$h[$id];
        $p = $v * 100 / $cap;
        $height = $v > 0 ? max(6, round(min(100, $p))) : 0;
        $tip = cfu_h("$day: ".number_format($v).' ('.cfu_pct_text($p).')');
        $out .= "<span class='cfu-col' title='$tip'><i class='cfu-".cfu_level($p)."' style='height:$height%'></i></span>";
      }
    }
    $out .= "</div>";
  }

  // Footer: last update and the next reset, in local time. tile.js keeps
  // the relative parts ("3 min ago", "in 5 h") current between page loads.
  $reset = (int)($d['reset'] ?? 0);
  // Stale means data that was fresh once and has stopped updating; before the
  // first update the setup hint or the per-cap errors say what's wrong instead.
  $stale = $updated && $now - $updated > CFU_STALE;
  $out .= "<div class='cfu-foot".($stale ? ' cfu-stale' : '')."' data-cfu-updated='$updated'>";
  $next = (int)($d['next'] ?? 0);
  if ($updated) {
    // Checks run every 15, 10 or 5 minutes depending on usage; "next" is when the next one is due.
    $out .= "<span>Updated <span data-cfu-time='$updated'>".date('H:i', $updated)."</span>"
      ." (<span data-cfu-ago='$updated'>".cfu_dur($now - $updated)." ago</span>)"
      .($next > $now ? ", next check <span data-cfu-time='$next'>".date('H:i', $next)."</span>" : '')
      ."</span>";
  } else {
    // Show the poller's last run, so it's visible that the schedule is working.
    $gen = (int)($d['generated'] ?? 0);
    $out .= "<span>Not updated yet"
      .($gen ? " (checker last ran <span data-cfu-time='$gen'>".date('H:i', $gen)."</span>)" : '')
      ."</span>";
  }
  if ($reset) {
    $out .= "<span>Resets <span data-cfu-reset='$reset'>in ".cfu_dur($reset - $now)."</span>"
      ." at <span data-cfu-time='$reset'>".date('H:i', $reset)."</span></span>";
  }
  $out .= "<span class='cfu-stale-note'>No fresh data for over 30 minutes. Check the syslog (tag cloudflare.usage).</span>";
  $out .= "</div>";
  return $out;
}

// The whole tile in Unraid 7 dashboard markup (see DashboardCustomTileExample.page).
function cfu_tile() {
  $d = cfu_load();
  $acct = $d['account'] ?? '';
  $link = preg_match('/^[0-9a-f]{32}$/', $acct)
    ? "https://dash.cloudflare.com/$acct/workers-and-pages"
    : 'https://dash.cloudflare.com/';
  return "<tbody title='Cloudflare usage'>"
    ."<tr><td>"
    ."<span class='tile-header'>"
    ."<span class='tile-header-left'>"
    ."<i class='fa fa-cloud f32'></i>"
    ."<div class='section'>"
    ."<h3 class='tile-header-main'>Cloudflare</h3>"
    ."<span>Free plan usage today, resets 00:00 UTC</span><br>"
    ."</div>"
    ."</span>"
    ."<span class='tile-header-right'>"
    ."<span class='tile-header-right-controls'>"
    ."<a href='".cfu_h($link)."' target='_blank' rel='noopener noreferrer' title='Open the Cloudflare dashboard'>"
    ."<i class='fa fa-fw fa-external-link control'></i></a>"
    ."</span>"
    ."</span>"
    ."</span>"
    ."</td></tr>"
    ."<tr><td id='cfu-body'>".cfu_body()."</td></tr>"
    ."</tbody>";
}

// Fetched directly by tile.js: return just the body.
if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
  header('Content-Type: text/html; charset=utf-8');
  header('Cache-Control: no-store');
  echo cfu_body();
}
