<?php
/* cloudflare.usage: POST endpoint for the settings page.
 *
 * Unraid's local_prepend.php runs before this file and rejects any POST without
 * the session's csrf_token (403), and the web UI's login protects the URL.
 * The page posts URL-encoded fields (no multipart, no file uploads).
 *
 *   action=save   account_id, token (empty keeps the saved token)
 *   action=check  run `poll --check`
 */
require_once __DIR__.'/settings_lib.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

function cfu_reply($ok, $message, $check = null) {
  echo json_encode(['ok' => $ok, 'message' => $message, 'check' => $check]);
  exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
  http_response_code(405);
  cfu_reply(false, 'POST only.');
}

$action = $_POST['action'] ?? '';
$token = trim((string)($_POST['token'] ?? ''));

if ($action === 'save') {
  [$ok, $message] = cfu_save(CFU_CFG_DIR, CFU_PLUG.'/cloudflare.usage.cfg.default', $_POST['account_id'] ?? '', $token);
  if (!$ok) cfu_reply(false, $message);
  [$rc, $check] = cfu_run_check($token);
  cfu_refresh();
  cfu_reply($rc === 0,
    $rc === 0 ? 'Saved, and the token works. The Dashboard tile updates within a minute.'
              : 'Saved, but the check below found a problem.',
    $check);
}

if ($action === 'check') {
  [$rc, $check] = cfu_run_check();
  cfu_reply($rc === 0, $rc === 0 ? 'The token works.' : 'The check found a problem.', $check);
}

http_response_code(400);
cfu_reply(false, 'Unknown action.');
