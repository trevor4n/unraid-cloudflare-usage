<?php
/* Tests for the settings helpers, the save endpoint and the settings page.
 * Run through test/run-tile-test.sh (needs php-cli). Uses a temp folder in
 * place of the flash drive and a stub in place of scripts/poll.
 *
 *   php test/settings-test.php WORK_DIR
 */
$work = $argv[1] ?? exit("usage: php settings-test.php WORK_DIR\n");
$root = realpath(__DIR__.'/..');
$flash = "$work/flash";
$plug = "$work/plug";
@mkdir("$plug/scripts", 0777, true);
@mkdir($flash, 0777, true);
copy("$root/src/cloudflare.usage.cfg.default", "$plug/cloudflare.usage.cfg.default");
// Stub for `poll --check`: prints what the real one would, and records the call.
file_put_contents("$plug/scripts/poll", "#!/bin/sh\necho \"\$*\" >> '$work/poll.calls'\necho 'Token: active, expires 2027-11-12 (in 364 days)'\nexit \${STUB_RC:-0}\n");
chmod("$plug/scripts/poll", 0755);

define('CFU_CFG_DIR', $flash);
define('CFU_PLUG', $plug);
define('CFU_STATE', "$work/state");
require "$root/src/include/settings_lib.php";

$pass = 0; $fail = 0;
function check($desc, $ok) {
  global $pass, $fail;
  if ($ok) { $pass++; echo "  ok    $desc\n"; } else { $fail++; echo "  FAIL  $desc\n"; }
}
$ACCT = '0123456789abcdef0123456789abcdef';
$TOKEN = 'tEsT-ToKeN_0123456789abcdefghijklmnopqrs';

echo "settings: validation\n";
check('account ID normalised to lower case', cfu_valid_account(' 0123456789ABCDEF0123456789abcdef ') === $ACCT);
check('short or non-hex account ID rejected', cfu_valid_account('12345') === null && cfu_valid_account(str_repeat('g', 32)) === null);
check('token characters checked like the poller', cfu_valid_token($TOKEN) && !cfu_valid_token('abc"def ghi jkl mno pqr') && !cfu_valid_token('short'));
check('config line replaced in place', cfu_cfg_set("A=\"1\"\nACCOUNT_ID=\"\"\nB=\"2\"\n", 'ACCOUNT_ID', 'x') === "A=\"1\"\nACCOUNT_ID=\"x\"\nB=\"2\"\n");
check('config line appended when missing', cfu_cfg_set("A=\"1\"\n", 'TOKEN_FILE', '/t') === "A=\"1\"\nTOKEN_FILE=\"/t\"\n");

echo "settings: saving\n";
[$ok, $msg] = cfu_save($flash, "$plug/cloudflare.usage.cfg.default", 'nope', $TOKEN);
check('bad account ID refused, nothing written', !$ok && !file_exists("$flash/cloudflare.usage.cfg") && !file_exists("$flash/cf-api-token"));
[$ok, $msg] = cfu_save($flash, "$plug/cloudflare.usage.cfg.default", $ACCT, '');
check('first save needs a token', !$ok && str_contains($msg, 'Paste the API token'));
[$ok, $msg] = cfu_save($flash, "$plug/cloudflare.usage.cfg.default", $ACCT, 'not a token!');
check('malformed token refused', !$ok && !file_exists("$flash/cf-api-token"));
[$ok, $msg] = cfu_save($flash, "$plug/cloudflare.usage.cfg.default", strtoupper($ACCT), "  $TOKEN\n");
$cfg = file_get_contents("$flash/cloudflare.usage.cfg");
check('save writes the account ID into the config', $ok && str_contains($cfg, "ACCOUNT_ID=\"$ACCT\""));
check('config keeps the default caps', str_contains($cfg, 'CAP_WORKERS="100000"'));
check('token saved, trimmed, mode 600', trim(file_get_contents("$flash/cf-api-token")) === $TOKEN && (fileperms("$flash/cf-api-token") & 0777) === 0600);
check('messages never contain the token', !str_contains($msg, $TOKEN));
file_put_contents("$flash/cloudflare.usage.cfg", str_replace('CAP_KV_WRITE="1000"', 'CAP_KV_WRITE="2000"', $cfg));
[$ok] = cfu_save($flash, "$plug/cloudflare.usage.cfg.default", $ACCT, '');
check('empty token keeps the saved one and other settings', $ok && trim(file_get_contents("$flash/cf-api-token")) === $TOKEN
  && str_contains(file_get_contents("$flash/cloudflare.usage.cfg"), 'CAP_KV_WRITE="2000"'));
check('no temp files left behind', count(glob("$flash/.cfu*")) === 0);

echo "settings: status\n";
@mkdir("$work/state");
file_put_contents("$work/state/usage.json", json_encode(['error' => '', 'next' => 1794600000,
  'token' => ['status' => 'active', 'expires' => 1825977600],
  'metrics' => [['id' => 'workers', 'fetched' => 1794500000, 'error' => ''], ['id' => 'do', 'fetched' => 1794500000, 'error' => 'do: HTTP 403: x']]]));
$st = cfu_status($flash, "$work/state/usage.json");
check('status reports account, token saved, expiry, errors', $st['account'] === $ACCT && $st['token_saved'] && $st['token']['expires'] === 1825977600
  && $st['updated'] === 1794500000 && $st['errors'] === ['do: HTTP 403: x']);
check('status never includes the token', !str_contains(json_encode($st), $TOKEN));

echo "settings: endpoint\n";
function endpoint($post, $method = 'POST', $env = '') {
  global $root, $work, $plug, $flash;
  $code = 'define("CFU_CFG_DIR", '.var_export($flash, true).'); define("CFU_PLUG", '.var_export($plug, true).');'
    .' $_SERVER["REQUEST_METHOD"] = '.var_export($method, true).'; $_POST = '.var_export($post, true).';'
    .' include '.var_export("$root/src/include/save.php", true).';';
  $out = shell_exec($env.'php -d display_errors=stderr -r '.escapeshellarg($code).' 2>/dev/null');
  return json_decode((string)$out, true);
}
$r = endpoint([], 'GET');
check('GET refused', is_array($r) && $r['ok'] === false && $r['message'] === 'POST only.');
$r = endpoint(['action' => 'save', 'account_id' => $ACCT, 'token' => 'bad token']);
check('endpoint passes validation errors back', $r['ok'] === false && str_contains($r['message'], "doesn't look like"));
@unlink("$work/poll.calls");
$r = endpoint(['action' => 'save', 'account_id' => $ACCT, 'token' => $TOKEN]);
check('save runs the check and returns its output', $r['ok'] === true && str_contains($r['check'], 'Token: active'));
usleep(500000);   // the refresh runs in the background
$calls = file("$work/poll.calls", FILE_IGNORE_NEW_LINES);
check('save runs --check, then a background refresh', $calls[0] === '--check' && count($calls) === 2 && $calls[1] === '');
check('endpoint reply never contains the token', !str_contains(json_encode($r), $TOKEN));
$r = endpoint(['action' => 'check'], 'POST', 'STUB_RC=1 ');
check('failed check reported as a problem', $r['ok'] === false && $r['message'] === 'The check found a problem.');
$r = endpoint(['action' => 'rm -rf /']);
check('unknown action refused', $r['ok'] === false && $r['message'] === 'Unknown action.');

echo "settings: page\n";
// Render the page body the way Unraid does: header stripped, eval'd with $docroot set.
$docroot = "$work/docroot";
@mkdir("$docroot/plugins/cloudflare.usage/include", 0777, true);
// A symlink, so the page's require_once sees the library already loaded.
@symlink("$root/src/include/settings_lib.php", "$docroot/plugins/cloudflare.usage/include/settings_lib.php");
[, $body] = explode("\n---\n", file_get_contents("$root/src/CloudflareUsage.page"), 2);
$before = array_keys(get_defined_vars());
ob_start();
eval('?>'.$body);
$html = ob_get_clean();
$added = array_diff(array_keys(get_defined_vars()), $before, ['before', 'html']);
check('page shows the saved account ID', str_contains($html, "value=\"$ACCT\""));
check('token field is write-only', str_contains($html, 'type="password" name="token"') && str_contains($html, 'Saved. Paste a new one to replace it.'));
check('page never contains the token', !str_contains($html, $TOKEN));
check('page shows the expiry date', str_contains($html, '12 Nov 2027'));
check('page shows the failing check', str_contains($html, 'Last check failed: do: HTTP 403: x'));
check('page links the token template and notification settings', str_contains($html, 'permissionGroupKeys=') && str_contains($html, '/Settings/Notifications'));
check('page only adds cfu_-prefixed globals', $added && !array_filter($added, fn($k) => !str_starts_with($k, 'cfu_')));

echo "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
