<?php
/* cloudflare.usage: settings helpers shared by CloudflareUsage.page and save.php.
 *
 * Kept free of request handling so the tests can call it directly. Writes go
 * only to the plugin's own folder on the flash drive, the token is never read
 * back out, and nothing here touches a shell with user input.
 */

if (!defined('CFU_CFG_DIR')) define('CFU_CFG_DIR', '/boot/config/plugins/cloudflare.usage');
if (!defined('CFU_PLUG'))    define('CFU_PLUG', '/usr/local/emhttp/plugins/cloudflare.usage');
if (!defined('CFU_STATE'))   define('CFU_STATE', '/var/local/cloudflare.usage');

// Cloudflare's dashboard opens a pre-filled "create token" form from this link
// (Account Analytics: Read only); the user reviews it and clicks Create.
const CFU_TOKEN_TEMPLATE = 'https://dash.cloudflare.com/?to=/:account/api-tokens'
  .'&permissionGroupKeys=%5B%7B%22key%22%3A%22account_analytics%22%2C%22type%22%3A%22read%22%7D%5D'
  .'&name=Unraid%20Cloudflare%20Usage%20%28analytics%20read%29';

function cfu_cfg_file($dir) { return "$dir/cloudflare.usage.cfg"; }
function cfu_token_file($dir) { return "$dir/cf-api-token"; }

// KEY="value" pairs from the config file, read without executing anything.
function cfu_cfg_read($dir) {
  $out = [];
  $text = @file_get_contents(cfu_cfg_file($dir));
  if ($text === false) return $out;
  foreach (preg_split('/\r?\n/', $text) as $line) {
    if (preg_match('/^([A-Z0-9_]+)="?([^"]*)"?\s*$/', $line, $m)) $out[$m[1]] = $m[2];
  }
  return $out;
}

function cfu_valid_account($s) {
  $s = strtolower(trim((string)$s));
  return preg_match('/^[0-9a-f]{32}$/', $s) ? $s : null;
}

// Same rule as scripts/poll: the token ends up inside a quoted curl config line.
function cfu_valid_token($s) {
  return (bool)preg_match('#^[A-Za-z0-9._~+/=-]{20,256}$#', (string)$s);
}

// Write a file via a temp file in the same folder, then rename.
function cfu_write_atomic($path, $data, $mode = 0600) {
  $tmp = @tempnam(dirname($path), '.cfu');
  if ($tmp === false) return false;
  if (@file_put_contents($tmp, $data) === false) { @unlink($tmp); return false; }
  @chmod($tmp, $mode);
  if (!@rename($tmp, $path)) { @unlink($tmp); return false; }
  return true;
}

// Set KEY="value" in config text, replacing the line or appending one.
function cfu_cfg_set($text, $key, $value) {
  $line = $key.'="'.$value.'"';
  $pattern = '/^'.preg_quote($key, '/').'=.*$/m';
  return preg_match($pattern, $text) ? preg_replace($pattern, $line, $text, 1) : rtrim($text)."\n".$line."\n";
}

/* Save the account ID and, when given, a new token. An empty token keeps the
 * saved one. Returns [ok, message]; the message never contains the token. */
function cfu_save($dir, $defaultCfg, $account, $token) {
  $acct = cfu_valid_account($account);
  if ($acct === null) return [false, 'The account ID is 32 letters and numbers (0-9, a-f). Copy it from your Cloudflare dashboard URL.'];
  $token = trim((string)$token);
  $tokenFile = cfu_token_file($dir);
  if ($token === '' && !is_file($tokenFile)) return [false, 'Paste the API token too.'];
  if ($token !== '' && !cfu_valid_token($token)) return [false, "That doesn't look like a Cloudflare API token. Copy it again from the token's summary page."];

  if (!is_dir($dir) && !@mkdir($dir, 0700, true)) return [false, "Couldn't create $dir."];
  $cfg = @file_get_contents(cfu_cfg_file($dir));
  if ($cfg === false) $cfg = (string)@file_get_contents($defaultCfg);
  $cfg = cfu_cfg_set($cfg, 'ACCOUNT_ID', $acct);
  $cfg = cfu_cfg_set($cfg, 'TOKEN_FILE', $tokenFile);
  if (!cfu_write_atomic(cfu_cfg_file($dir), $cfg, 0600)) return [false, "Couldn't write the settings file."];
  if ($token !== '' && !cfu_write_atomic($tokenFile, $token."\n", 0600)) return [false, "Couldn't save the token."];
  return [true, 'Saved.'];
}

// What the settings page shows. Never includes the token itself.
function cfu_status($dir, $cache) {
  $cfg = cfu_cfg_read($dir);
  $tokenFile = $cfg['TOKEN_FILE'] ?? cfu_token_file($dir);
  $data = json_decode((string)@file_get_contents($cache), true);
  $data = is_array($data) ? $data : [];
  $updated = 0;
  $errors = [];
  foreach ($data['metrics'] ?? [] as $m) {
    $updated = max($updated, (int)($m['fetched'] ?? 0));
    if (!empty($m['error'])) $errors[] = $m['error'];
  }
  return [
    'account'      => cfu_valid_account($cfg['ACCOUNT_ID'] ?? '') ?? '',
    'token_saved'  => is_file($tokenFile) && filesize($tokenFile) > 0,
    'token_mtime'  => is_file($tokenFile) ? filemtime($tokenFile) : 0,
    'token'        => $data['token'] ?? [],
    'updated'      => $updated,
    'next'         => (int)($data['next'] ?? 0),
    'setup_error'  => (string)($data['error'] ?? ''),
    'errors'       => array_values(array_unique($errors)),
  ];
}

// Run `poll --check` and return [exit code, output]. Fixed command, no input.
function cfu_run_check($secret = '') {
  $lines = [];
  $rc = 1;
  exec(escapeshellarg(CFU_PLUG.'/scripts/poll').' --check 2>&1', $lines, $rc);
  $text = implode("\n", $lines);
  if ($secret !== '') $text = str_replace($secret, '[redacted]', $text);   // belt and braces; poll never prints it
  return [$rc, $text];
}

// Refresh the tile now rather than at the next scheduled check.
function cfu_refresh() {
  exec('setsid '.escapeshellarg(CFU_PLUG.'/scripts/poll').' >/dev/null 2>&1 &');
}
