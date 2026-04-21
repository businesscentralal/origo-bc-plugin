#!/usr/bin/env node
/**
 * create-connection-string.js
 *
 * Cross-platform helper that builds a "plain:<base64>" connection blob for
 * the BC Origo MCP server. On Windows the result is additionally wrapped
 * with DPAPI (CurrentUser scope) via a child PowerShell process so the
 * config file at rest is bound to this user + machine. On Mac/Linux the
 * raw "plain:<base64>" string is emitted and the user is warned to protect
 * it with filesystem permissions (or to use a secret manager of their
 * choice such as macOS Keychain or libsecret).
 *
 * No HTTPS call is made. The server's resolveConn accepts "plain:<base64>"
 * directly and decodes it server-side — see api/mcp/index.js.
 *
 * Usage:
 *   node create-connection-string.js \
 *     --tenant 'dynamics.is' \
 *     --client '<guid>' \
 *     --environment 'UAT' \
 *     [--no-dpapi]
 *
 * The client secret is prompted interactively (hidden input) so it never
 * appears on the command line or in shell history.
 *
 * Output: the final token is copied to the OS clipboard when possible,
 * otherwise printed to stdout. Informational messages go to stderr so
 * piping stdout into another tool still works.
 */

"use strict";

const readline       = require("readline");
const { spawnSync }  = require("child_process");
const { Writable }   = require("stream");

// ── Argument parsing ─────────────────────────────────────────────────────────

function parseArgs(argv) {
  const out = { environment: "UAT", noDpapi: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case "--tenant":      out.tenant      = next(); break;
      case "--client":      out.client      = next(); break;
      case "--environment": out.environment = next(); break;
      case "--no-dpapi":    out.noDpapi     = true;   break;
      case "--help":
      case "-h":
        process.stderr.write(
          "Usage: node create-connection-string.js --tenant <id> --client <guid> [--environment <name>] [--no-dpapi]\n"
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
// The plaintext is piped via stdin (not an argument) so it never shows up
// in Task Manager or ETW command-line logs.

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

// ── Main ─────────────────────────────────────────────────────────────────────

(async function main() {
  const opts = parseArgs(process.argv);

  let secret;
  try {
    secret = await promptSecret("BC client secret (input hidden)");
  } catch (e) {
    process.stderr.write(`[create-connection-string] ${e.message}\n`);
    process.exit(1);
  }

  const payload = JSON.stringify({
    tenantId:     opts.tenant,
    clientId:     opts.client,
    clientSecret: secret,
    environment:  opts.environment,
  });
  secret = null;

  const plainValue = "plain:" + Buffer.from(payload, "utf8").toString("base64");

  let finalValue;
  let wrapped = false;

  if (process.platform === "win32" && !opts.noDpapi) {
    try {
      finalValue = dpapiWrap(plainValue);
      wrapped = true;
    } catch (e) {
      process.stderr.write(`[create-connection-string] ${e.message}\n`);
      process.stderr.write("[create-connection-string] Falling back to un-wrapped plain:<base64>.\n");
      finalValue = plainValue;
    }
  } else {
    finalValue = plainValue;
  }

  const copied = copyToClipboard(finalValue);
  if (copied) {
    process.stderr.write(
      `[create-connection-string] ${wrapped ? "dpapi:" : "plain:"}<...> value copied to clipboard.\n`
    );
  } else {
    process.stderr.write("[create-connection-string] Clipboard unavailable; printing value to stdout:\n");
    process.stdout.write(finalValue + "\n");
  }

  if (!wrapped) {
    process.stderr.write(
      "[create-connection-string] WARNING: blob is NOT bound to this machine/user.\n" +
      "[create-connection-string] Protect the config file with filesystem permissions (chmod 600 on *nix)\n" +
      "[create-connection-string] or store the value in a platform secret manager.\n"
    );
  }
})().catch((e) => {
  process.stderr.write(`[create-connection-string] ${e.stack || e.message}\n`);
  process.exit(1);
});
