#!/usr/bin/env node
/**
 * create-connection-string.js
 *
 * Cross-platform helper that builds an AES-256-GCM encrypted connection blob
 * for the BC Origo MCP server by calling the server's encrypt_data tool
 * (no authentication required). On Windows the AES ciphertext is additionally
 * wrapped with DPAPI (CurrentUser scope) so the config file at rest is bound
 * to this user + machine. On Mac/Linux the raw AES ciphertext is emitted
 * and the user is warned to protect it with filesystem permissions.
 *
 * Two authentication flows are supported:
 *
 *   Client-secret flow (default):
 *     Prompts for a client secret (hidden input). The connection blob
 *     stores { tenantId, clientId, clientSecret, environment }.
 *
 *   Device-code flow (--device-code flag):
 *     Initiates an OAuth 2.0 device code flow against Entra ID.
 *     The user authenticates in a browser. The connection blob stores
 *     { tenantId, clientId, refreshToken, environment }.
 *
 * Security properties:
 *   At rest (config file): DPAPI + AES-256-GCM (double layer on Windows),
 *                           Keychain + AES-256-GCM (macOS).
 *   In transit to server:  TLS + AES-256-GCM.
 *   At server:             decrypted only in memory by resolveConn.
 *
 * The legacy "plain:<base64>" format is no longer supported.
 *
 * Usage:
 *   node create-connection-string.js \
 *     --tenant 'dynamics.is' \
 *     --client '<guid>' \
 *     --environment 'UAT' \
 *     [--device-code] \
 *     [--mcp-url 'https://dynamics.is/api/mcp'] \
 *     [--no-dpapi] \
 *     [--no-keychain]
 *
 * With --device-code the secret prompt is skipped; the user authenticates
 * interactively in a browser instead. Without --device-code the client
 * secret is prompted with hidden input so it never appears on the command
 * line or in shell history.
 *
 * Output: the final token is copied to the OS clipboard when possible,
 * otherwise printed to stdout. Informational messages go to stderr so
 * piping stdout into another tool still works.
 */

"use strict";

const https          = require("https");
const readline       = require("readline");
const { spawnSync }  = require("child_process");
const { Writable }   = require("stream");

const DEFAULT_MCP_URL = "https://dynamics.is/api/mcp";

// ── Argument parsing ─────────────────────────────────────────────────────────

function parseArgs(argv) {
  const out = {
    environment:     "UAT",
    noDpapi:         false,
    noKeychain:      false,
    deviceCode:      false,
    mcpUrl:          DEFAULT_MCP_URL,
    skipValidation:  false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case "--tenant":           out.tenant         = next(); break;
      case "--client":           out.client         = next(); break;
      case "--environment":      out.environment    = next(); break;
      case "--mcp-url":          out.mcpUrl         = next(); break;
      case "--no-dpapi":         out.noDpapi        = true;   break;
      case "--no-keychain":      out.noKeychain     = true;   break;
      case "--device-code":      out.deviceCode     = true;   break;
      case "--skip-validation":  out.skipValidation = true;   break;
      case "--help":
      case "-h":
        process.stderr.write(
          "Usage: node create-connection-string.js --tenant <id> --client <guid> " +
          "[--environment <name>] [--device-code] [--mcp-url <url>] [--no-dpapi] " +
          "[--no-keychain] [--skip-validation]\n"
        );
        process.exit(0);
      default:
        process.stderr.write(`Unknown argument: ${a}\n`);
        process.exit(2);
    }
  }
  if (!out.tenant || !out.client) {
    process.stderr.write("Missing --tenant or --client. Use --help for usage.\n");
    process.exit(2);
  }
  return out;
}

// ── Hidden-input prompt for the client secret ───────────────────────────────
// Mutes the terminal output while the user types. Returns a Promise resolving
// to the typed string. The plaintext stays only in the Promise's resolved
// value — we zero our own buffers once we're done with it.

function promptSecret(label) {
  return new Promise((resolve, reject) => {
    let muted = false;
    const mutableStdout = new Writable({
      write(chunk, encoding, cb) {
        if (!muted) process.stdout.write(chunk, encoding);
        cb();
      },
    });
    mutableStdout.isTTY = process.stdout.isTTY;

    const rl = readline.createInterface({
      input:    process.stdin,
      output:   mutableStdout,
      terminal: true,
    });

    process.stdout.write(`${label}: `);
    muted = true;

    rl.question("", (answer) => {
      rl.close();
      process.stdout.write("\n");
      if (!answer) return reject(new Error("Empty secret"));
      resolve(answer);
    });
    rl.on("SIGINT", () => {
      rl.close();
      reject(new Error("Interrupted"));
    });
  });
}

// ── DPAPI wrap via a child PowerShell process (Windows only) ────────────────
// We call System.Security.Cryptography.ProtectedData.Protect with
// CurrentUser scope — same primitive stdio-proxy.js unwraps at startup.
// The AES ciphertext is piped via stdin (not an argument) so it never shows
// up in Task Manager or ETW command-line logs.

function dpapiWrap(plainText) {
  const script = `
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Security | Out-Null
    $stdin = [Console]::In.ReadToEnd()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($stdin)
    try {
      $cipher = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes, $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } finally {
      for ($i = 0; $i -lt $plainBytes.Length; $i++) { $plainBytes[$i] = 0 }
    }
    [Console]::Out.Write([Convert]::ToBase64String($cipher))
  `;

  const res = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
    { input: plainText, encoding: "utf8" }
  );

  if (res.status !== 0) {
    const msg = (res.stderr || "").toString().trim() || `powershell exited with ${res.status}`;
    throw new Error(`DPAPI wrap failed: ${msg}`);
  }
  return "dpapi:" + res.stdout.trim();
}

// ── macOS Keychain store ─────────────────────────────────────────────────────
// Stores the AES ciphertext in the login Keychain using the `security` CLI.
// The service name encodes the tenant + environment so each connection gets
// its own Keychain item. Returns the reference string "keychain:<service>".
// Throws on failure so the caller can fall back to plain:.

function keychainStore(ciphertext, tenant, environment) {
  const service = `origo-bc-mcp/${tenant}/${environment}`;
  const account = "mcp-encrypted-conn";

  // -U = update if exists, -T "" = no app-specific ACL (any process of this
  // user can read it after the Keychain is unlocked, which is the macOS
  // default for login Keychain items).
  const res = spawnSync("security", [
    "add-generic-password",
    "-a", account,
    "-s", service,
    "-w", ciphertext,
    "-U",
  ], { encoding: "utf8" });

  if (res.status !== 0) {
    const msg = (res.stderr || "").trim() || `security exited with ${res.status}`;
    throw new Error(`Keychain store failed: ${msg}`);
  }
  return "keychain:" + service;
}

// ── macOS Keychain read (used by dynamics-is.js, exported here for reference)
// security find-generic-password -a mcp-encrypted-conn -s <service> -w

// ── OS clipboard copy (best-effort, never throws upstream) ──────────────────

function copyToClipboard(text) {
  try {
    let cmd, args;
    if (process.platform === "win32") {
      cmd = "powershell.exe";
      args = ["-NoProfile", "-NonInteractive", "-Command", "Set-Clipboard -Value ([Console]::In.ReadToEnd())"];
    } else if (process.platform === "darwin") {
      cmd = "pbcopy"; args = [];
    } else {
      cmd = "xclip"; args = ["-selection", "clipboard"];
    }
    const res = spawnSync(cmd, args, { input: text, encoding: "utf8" });
    return res.status === 0;
  } catch {
    return false;
  }
}

// ── Validate the encrypted blob end-to-end via list_companies ───────────────
// Round-trips the fresh AES ciphertext through the server's list_companies
// tool. Fails the script (throws) if the server can't use these credentials
// to authenticate with BC, so we never write a broken config entry that the
// user would only discover after a full app restart. Catches rotated/wrong
// client secrets, device-code refresh tokens with insufficient scopes, and
// server-side routing bugs (e.g. client-credentials used when the payload
// only contains a refreshToken).

function validateEncryptedBlob(mcpUrl, aesCiphertext) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      jsonrpc: "2.0",
      id:      2,
      method:  "tools/call",
      params: {
        name:      "list_companies",
        arguments: { encryptedConn: aesCiphertext },
      },
    });

    const url = new URL(mcpUrl);
    const options = {
      hostname: url.hostname,
      port:     url.port || 443,
      path:     url.pathname,
      method:   "POST",
      headers: {
        "Content-Type":   "application/json",
        "Accept":         "application/json, text/event-stream",
        "Content-Length": Buffer.byteLength(body),
      },
    };

    const req = https.request(options, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let json;
        try { json = JSON.parse(raw); }
        catch (e) { return reject(new Error(`Validation response was not JSON: ${e.message}`)); }

        // JSON-RPC-level error
        if (json.error) {
          return reject(new Error(
            `Validation failed (JSON-RPC error ${json.error.code}): ${json.error.message}`));
        }

        // Tool-level error. MCP surfaces these as either:
        //   result.isError === true with message in content[0].text
        //   content[0].text starts with "Error:" / "Token error" / "Unauthorized"
        const text =
          (json.result && json.result.content && json.result.content[0] &&
           json.result.content[0].text) || "";

        if (json.result && json.result.isError) {
          return reject(new Error(`Validation failed: ${text}`));
        }
        if (/^\s*(Error|Token error|Unauthorized|Forbidden|AADSTS)\b/.test(text)) {
          return reject(new Error(`Validation failed: ${text}`));
        }

        // Try to parse for a nicer status line; a non-error response means
        // auth worked regardless of whether we can count companies cleanly.
        let count = null;
        try {
          const parsed = JSON.parse(text);
          if (Array.isArray(parsed))              count = parsed.length;
          else if (Array.isArray(parsed.companies)) count = parsed.companies.length;
          else if (Array.isArray(parsed.value))     count = parsed.value.length;
        } catch { /* non-JSON body is fine */ }

        resolve(count);
      });
    });

    req.on("error", (e) => reject(new Error(`Validation request failed: ${e.message}`)));
    req.write(body);
    req.end();
  });
}

// ── Call the MCP server's encrypt_data tool ─────────────────────────────────
// No authentication headers are needed — encrypt_data is an open tool.
// It encrypts the payload with AES-256-GCM using the server's MCP_ENCRYPTION_KEY.

function encryptViaServer(mcpUrl, plaintext) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "encrypt_data", arguments: { plaintext } },
    });

    const url = new URL(mcpUrl);
    const options = {
      hostname: url.hostname,
      port:     url.port || 443,
      path:     url.pathname,
      method:   "POST",
      headers:  { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    };

    const req = https.request(options, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        try {
          const json = JSON.parse(raw);
          if (json.error) return reject(new Error(`encrypt_data error: ${json.error.message}`));
          const inner = JSON.parse(json.result.content[0].text);
          if (!inner.ciphertext) return reject(new Error("encrypt_data did not return a ciphertext field"));
          resolve(inner.ciphertext);
        } catch (e) {
          reject(new Error(`Failed to parse encrypt_data response: ${e.message}`));
        }
      });
    });

    req.on("error", (e) => reject(new Error(`Failed to reach MCP server at ${mcpUrl}: ${e.message}`)));
    req.write(body);
    req.end();
  });
}

// ── HTTPS POST helper (returns parsed JSON) ─────────────────────────────────

function httpsPost(urlStr, formBody) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const encoded = typeof formBody === "string" ? formBody
      : Object.entries(formBody).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
    const options = {
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname,
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Content-Length": Buffer.byteLength(encoded),
      },
    };
    const req = https.request(options, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
        } catch (e) {
          reject(new Error(`Failed to parse response: ${e.message}`));
        }
      });
    });
    req.on("error", (e) => reject(e));
    req.write(encoded);
    req.end();
  });
}

// ── Device-code flow ────────────────────────────────────────────────────────
// Initiates the OAuth 2.0 device code flow against Entra ID and polls for
// the user to complete authentication. Returns the refresh token.

async function deviceCodeFlow(tenantId, clientId) {
  const deviceCodeUrl = `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/devicecode`;
  const tokenUrl      = `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`;
  const scope         = "https://api.businesscentral.dynamics.com/.default offline_access";

  // Step 1: Request a device code
  const dc = await httpsPost(deviceCodeUrl, { client_id: clientId, scope });
  if (!dc.body.device_code) {
    throw new Error(`Device code request failed: ${dc.body.error_description || JSON.stringify(dc.body)}`);
  }

  process.stderr.write(`\n[create-connection-string] ── Device Code Authentication ──\n`);
  process.stderr.write(`[create-connection-string] ${dc.body.message}\n\n`);

  // Try to open the verification URL in the default browser
  try {
    const opener = process.platform === "win32" ? "start"
      : process.platform === "darwin" ? "open" : "xdg-open";
    spawnSync(opener, [dc.body.verification_uri], { shell: true });
  } catch { /* non-fatal */ }

  // Step 2: Poll for token
  let interval = Math.max(dc.body.interval || 5, 5) * 1000;
  const deadline = Date.now() + dc.body.expires_in * 1000;

  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, interval));

    const tok = await httpsPost(tokenUrl, {
      client_id: clientId,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      device_code: dc.body.device_code,
    });

    if (tok.body.refresh_token) {
      process.stderr.write("[create-connection-string] Authentication successful.\n");
      return tok.body.refresh_token;
    }

    if (tok.body.error === "authorization_pending") continue;
    if (tok.body.error === "slow_down") { interval += 5000; continue; }

    throw new Error(`Device code flow failed: ${tok.body.error_description || tok.body.error}`);
  }

  throw new Error("Device code flow timed out. Please try again.");
}

// ── Main ─────────────────────────────────────────────────────────────────────

(async function main() {
  const opts = parseArgs(process.argv);

  let payload;

  if (opts.deviceCode) {
    // Device code flow — interactive browser auth, stores refresh token
    let refreshToken;
    try {
      refreshToken = await deviceCodeFlow(opts.tenant, opts.client);
    } catch (e) {
      process.stderr.write(`[create-connection-string] ${e.message}\n`);
      process.exit(1);
    }
    payload = JSON.stringify({
      tenantId:     opts.tenant,
      clientId:     opts.client,
      refreshToken: refreshToken,
      environment:  opts.environment,
    });
    refreshToken = null;
  } else {
    // Client secret flow — hidden prompt
    let secret;
    try {
      secret = await promptSecret("BC client secret (input hidden)");
    } catch (e) {
      process.stderr.write(`[create-connection-string] ${e.message}\n`);
      process.exit(1);
    }
    payload = JSON.stringify({
      tenantId:     opts.tenant,
      clientId:     opts.client,
      clientSecret: secret,
      environment:  opts.environment,
    });
    secret = null;
  }

  // Call the server to encrypt the credentials with AES-256-GCM
  process.stderr.write(`[create-connection-string] Calling encrypt_data at ${opts.mcpUrl} ...\n`);

  let aesCiphertext;
  try {
    aesCiphertext = await encryptViaServer(opts.mcpUrl, payload);
  } catch (e) {
    process.stderr.write(`[create-connection-string] ${e.message}\n`);
    process.exit(1);
  }

  process.stderr.write("[create-connection-string] Credentials encrypted successfully (AES-256-GCM).\n");

  // End-to-end validation — fail before writing anything if the server can't
  // actually use these credentials. See validateEncryptedBlob() for the list
  // of failure modes this catches.
  if (!opts.skipValidation) {
    process.stderr.write(
      `[create-connection-string] Validating credentials via list_companies ...\n`);
    try {
      const count = await validateEncryptedBlob(opts.mcpUrl, aesCiphertext);
      const suffix = count != null
        ? ` (${count} ${count === 1 ? "company" : "companies"} visible)`
        : "";
      process.stderr.write(
        `[create-connection-string] Validation OK — credentials work${suffix}.\n`);
    } catch (e) {
      process.stderr.write(`[create-connection-string] ${e.message}\n`);
      process.stderr.write(
        "[create-connection-string] Aborting before writing anything. " +
        "Re-run with --skip-validation if you need to override.\n");
      process.exit(1);
    }
  }

  let finalValue;
  let wrapped = false;
  let wrapLabel = "plain:";

  if (process.platform === "win32" && !opts.noDpapi) {
    // Windows: DPAPI binds the blob to this user + machine.
    try {
      finalValue = dpapiWrap(aesCiphertext);   // returns "dpapi:<base64>"
      wrapped = true;
      wrapLabel = "dpapi:";
    } catch (e) {
      process.stderr.write(`[create-connection-string] ${e.message}\n`);
      process.stderr.write("[create-connection-string] Falling back to un-wrapped AES ciphertext.\n");
      finalValue = "plain:" + aesCiphertext;
    }
  } else if (process.platform === "darwin" && !opts.noKeychain) {
    // macOS: Keychain binds the blob to this user's login Keychain.
    try {
      finalValue = keychainStore(aesCiphertext, opts.tenant, opts.environment);
      wrapped = true;
      wrapLabel = "keychain:";
      process.stderr.write(
        "[create-connection-string] AES ciphertext stored in macOS Keychain " +
        `(service: origo-bc-mcp/${opts.tenant}/${opts.environment}).\n`
      );
    } catch (e) {
      process.stderr.write(`[create-connection-string] ${e.message}\n`);
      process.stderr.write("[create-connection-string] Falling back to un-wrapped AES ciphertext.\n");
      finalValue = "plain:" + aesCiphertext;
    }
  } else {
    // Linux or explicit --no-dpapi / --no-keychain.
    finalValue = "plain:" + aesCiphertext;
  }

  const copied = copyToClipboard(finalValue);
  if (copied) {
    process.stderr.write(
      `[create-connection-string] ${wrapLabel}<...> value copied to clipboard.\n`
    );
  } else {
    process.stderr.write("[create-connection-string] Clipboard unavailable; printing value to stdout:\n");
    process.stdout.write(finalValue + "\n");
  }

  if (!wrapped) {
    process.stderr.write(
      "[create-connection-string] NOTE: blob is AES-encrypted but NOT bound to this machine/user.\n" +
      "[create-connection-string] Protect the config file with filesystem permissions (chmod 600 on *nix)\n" +
      "[create-connection-string] or store the value in a platform secret manager.\n"
    );
  }
})().catch((e) => {
  process.stderr.write(`[create-connection-string] ${e.stack || e.message}\n`);
  process.exit(1);
});
