/**
 * stdio-proxy.js
 *
 * MCP stdio transport wrapper for the bc-origo HTTP MCP server.
 * Claude Desktop / Cowork launches this as a child process and communicates
 * over stdin/stdout using newline-delimited JSON-RPC.
 * This script forwards each message to the configured BC Origo MCP server
 * with the required auth headers and writes the response(s) back to stdout.
 *
 * Usage: node stdio-proxy.js <encryptedConn> <companyId>
 *
 * The target host is hardcoded to dynamics.is (the BC Origo MCP endpoint);
 * it is no longer a configurable argument.
 *
 * Add to claude_desktop_config.json:
 * {
 *   "mcpServers": {
 *     "bc-kappi-production": {
 *       "command": "node",
 *       "args": [
 *         "C:\\Data\\MCP\\stdio-proxy.js",
 *         "<x-encrypted-conn>",
 *         "<x-company-id>"
 *       ]
 *     }
 *   }
 * }
 *
 * Argument format (Windows only):
 *   <encryptedConn> MUST be a "dpapi:<base64>" string produced by
 *     Create-ConnectionString.ps1. Plaintext connection strings are rejected.
 *     The proxy unwraps it at startup using Windows DPAPI with the
 *     CurrentUser scope, so the config file is useless if copied to another
 *     user account or another machine.
 *   <companyId> MUST be a plain GUID in 8-4-4-4-12 hex format
 *     (e.g. 10C11E99-2650-F011-BE59-000D3AB119BB). It is not a secret and
 *     is not DPAPI-wrapped.
 */

'use strict';

const https          = require('https');
const readline       = require('readline');
const { spawnSync }  = require('child_process');

// ── Configuration ────────────────────────────────────────────────────────────
// The target host is hardcoded rather than passed on the command line; this
// proxy is only ever used against the BC Origo MCP endpoint.

const TARGET_HOST        = 'dynamics.is';
const TARGET_PATH        = '/api/mcp';
const ENCRYPTED_CONN_ARG = process.argv[2];
const COMPANY_ID_ARG     = process.argv[3];

if (!ENCRYPTED_CONN_ARG || !COMPANY_ID_ARG) {
  process.stderr.write(
    '[stdio-proxy] Usage: node stdio-proxy.js <encryptedConn> <companyId>\n'
  );
  process.exit(1);
}

// ── DPAPI unwrap ─────────────────────────────────────────────────────────────
//
// Any arg that starts with "dpapi:" is treated as Base64-encoded ciphertext
// produced by Windows DPAPI with the CurrentUser scope (same primitive that
// PowerShell's ConvertFrom-SecureString uses when no -Key is supplied).
// We shell out to PowerShell once at startup to unwrap it; the plaintext
// then lives only in this process's memory for the lifetime of the proxy.
// Decryption will fail on any other Windows user account or on any other
// machine, which is the whole point.

function unwrapDpapi(value, label) {
  if (typeof value !== 'string' || !value.startsWith('dpapi:')) {
    return value;
  }

  if (process.platform !== 'win32') {
    process.stderr.write(
      '[stdio-proxy] dpapi:-prefixed value for ' + label +
      ' but this platform is not Windows; DPAPI is unavailable.\n'
    );
    process.exit(1);
  }

  const b64 = value.slice('dpapi:'.length);

  // Pass the Base64 blob to PowerShell via stdin so it never appears on the
  // command line (where it could be visible in process listings).
  // Add-Type loads System.Security so ProtectedData resolves. Without this,
  // `powershell.exe -NoProfile -Command ...` can fail with
  //   "Unable to find type [System.Security.Cryptography.ProtectedData]"
  // which the outer error handler misreports as a cross-user DPAPI failure.
  const script =
    "$ErrorActionPreference = 'Stop';" +
    'Add-Type -AssemblyName System.Security;' +
    '$b64 = [Console]::In.ReadToEnd().Trim();' +
    '$enc = [Convert]::FromBase64String($b64);' +
    '$dec = [System.Security.Cryptography.ProtectedData]::Unprotect(' +
    '$enc, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser);' +
    '[Console]::Out.Write([System.Text.Encoding]::UTF8.GetString($dec));';

  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { input: b64, encoding: 'utf8', windowsHide: true }
  );

  if (result.error) {
    process.stderr.write(
      '[stdio-proxy] Failed to launch PowerShell for DPAPI unwrap of ' +
      label + ': ' + result.error.message + '\n'
    );
    process.exit(1);
  }
  if (result.status !== 0) {
    process.stderr.write(
      '[stdio-proxy] DPAPI unwrap failed for ' + label +
      ' (exit ' + result.status + '). This usually means the value was ' +
      'encrypted for a different Windows user or on a different machine.\n'
    );
    if (result.stderr) process.stderr.write(result.stderr.toString() + '\n');
    process.exit(1);
  }

  const plain = (result.stdout || '').toString();
  if (!plain) {
    process.stderr.write('[stdio-proxy] DPAPI unwrap produced empty output for ' + label + '.\n');
    process.exit(1);
  }
  return plain;
}

// ── Cheap format validation (before any PowerShell shell-out) ────────────────
// Both checks run first so misconfigured args surface clear errors without
// paying for a DPAPI round-trip.

// Connection string MUST be DPAPI-protected. Plaintext is rejected outright
// so the value stored in the config is never directly replayable.
if (typeof ENCRYPTED_CONN_ARG !== 'string' || !ENCRYPTED_CONN_ARG.startsWith('dpapi:')) {
  process.stderr.write(
    '[stdio-proxy] <encryptedConn> must be a "dpapi:<base64>" value produced ' +
    'by Create-ConnectionString.ps1. Plaintext connection strings are not ' +
    'accepted.\n'
  );
  process.exit(1);
}

// Company ID MUST be a plain GUID. Tolerate an optional surrounding {...}
// (some tooling emits that form), but reject DPAPI blobs, empty strings,
// and anything that isn't an 8-4-4-4-12 hex GUID.
const GUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const COMPANY_ID = (typeof COMPANY_ID_ARG === 'string'
  ? COMPANY_ID_ARG.replace(/^\{(.*)\}$/, '$1')
  : '');

if (!GUID_RE.test(COMPANY_ID)) {
  process.stderr.write(
    '[stdio-proxy] <companyId> must be a plain GUID in 8-4-4-4-12 hex format ' +
    '(e.g. 10C11E99-2650-F011-BE59-000D3AB119BB). DPAPI-wrapped values and ' +
    'other formats are not accepted for the company ID.\n'
  );
  process.exit(1);
}

// ── DPAPI unwrap (shells out to PowerShell; Windows only) ────────────────────
// Create-ConnectionString.ps1 DPAPI-wraps the server's ciphertext token
// directly, so the decrypted value here is the bare token that belongs in
// the x-encrypted-conn header. If it ever isn't (e.g. the PS1 script is
// reverted to wrap the JSON envelope), regenerate the config value rather
// than adding a fallback here.
const ENCRYPTED_CONN = unwrapDpapi(ENCRYPTED_CONN_ARG, 'x-encrypted-conn').trim();

// HTTP headers cannot contain CR, LF, or NUL. A properly generated token
// is already header-safe; this guard surfaces formatting surprises with a
// clear error rather than Node's generic "Invalid character in header content".
if (/[\r\n\0]/.test(ENCRYPTED_CONN)) {
  process.stderr.write(
    '[stdio-proxy] x-encrypted-conn contains CR/LF/NUL after DPAPI unwrap; ' +
    'regenerate it with Create-ConnectionString.ps1.\n'
  );
  process.exit(1);
}

const INJECT_HEADERS = {
  'x-encrypted-conn' : ENCRYPTED_CONN,
  'x-company-id'     : COMPANY_ID,
};

// ── State ────────────────────────────────────────────────────────────────────

let sessionId = null;   // MCP session ID returned by the server after initialize

// ── Core: forward one JSON-RPC message to the HTTP server ────────────────────

function sendToMcp(payload) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(payload);

    const reqHeaders = Object.assign({}, INJECT_HEADERS, {
      'content-type'   : 'application/json',
      'accept'         : 'application/json, text/event-stream',
      'content-length' : Buffer.byteLength(body),
    });

    if (sessionId) {
      reqHeaders['mcp-session-id'] = sessionId;
    }

    const options = {
      hostname : TARGET_HOST,
      port     : 443,
      path     : TARGET_PATH,
      method   : 'POST',
      headers  : reqHeaders,
    };

    const req = https.request(options, (res) => {
      // Persist session ID for the lifetime of this process
      if (res.headers['mcp-session-id']) {
        sessionId = res.headers['mcp-session-id'];
      }

      const ct = res.headers['content-type'] || '';

      if (ct.includes('text/event-stream')) {
        // ── SSE stream: collect all data: lines then resolve ──────────────
        const messages = [];
        let buf = '';

        res.on('data', (chunk) => {
          buf += chunk.toString('utf8');
          const lines = buf.split('\n');
          buf = lines.pop();               // keep any incomplete trailing line

          let pending = '';
          for (const line of lines) {
            if (line.startsWith('data: ')) {
              pending = line.slice(6).trim();
            } else if (line.trim() === '' && pending) {
              try { messages.push(JSON.parse(pending)); } catch (_) {}
              pending = '';
            }
          }
        });

        res.on('end',   () => resolve(messages));
        res.on('error', reject);

      } else {
        // ── Plain JSON response ───────────────────────────────────────────
        let raw = '';
        res.on('data',  (chunk) => { raw += chunk.toString('utf8'); });
        res.on('end',   () => {
          if (!raw.trim()) { resolve([]); return; }
          try { resolve([JSON.parse(raw)]); }
          catch (_) { resolve([]); }
        });
        res.on('error', reject);
      }
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ── Stdio loop ───────────────────────────────────────────────────────────────

const rl = readline.createInterface({ input: process.stdin, terminal: false });

rl.on('line', async (line) => {
  line = line.trim();
  if (!line) return;

  let msg;
  try { msg = JSON.parse(line); }
  catch (_) { return; }   // ignore non-JSON input

  try {
    const responses = await sendToMcp(msg);
    for (const r of responses) {
      process.stdout.write(JSON.stringify(r) + '\n');
    }
  } catch (err) {
    // Emit a JSON-RPC error so the client knows something went wrong
    if (msg.id !== undefined) {
      process.stdout.write(JSON.stringify({
        jsonrpc : '2.0',
        id      : msg.id,
        error   : { code: -32000, message: err.message },
      }) + '\n');
    }
    process.stderr.write('[stdio-proxy] error: ' + err.message + '\n');
  }
});

rl.on('close', () => process.exit(0));

process.stderr.write('[stdio-proxy] BC Origo MCP proxy ready – ' + TARGET_HOST + ' / company ' + COMPANY_ID + '\n');
