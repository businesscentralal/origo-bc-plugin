# Connection Setup & Scripts

> Loaded on demand. Only read this file when helping a user set up or
> troubleshoot their MCP connection.

## How the connection blob is produced

1. The helper script collects tenant, client, secret, and environment.
2. It calls `encrypt_data` on the MCP server (`https://dynamics.is/api/mcp`)
   via JSON-RPC — no authentication headers required.
3. The server encrypts the JSON with AES-256-GCM using `MCP_ENCRYPTION_KEY`
   and returns base64 ciphertext.
4. On Windows, the script wraps the ciphertext with DPAPI (user + machine bound).

**Protection layers:**
- In transit: TLS
- At rest: DPAPI on Windows, filesystem permissions elsewhere (`chmod 600`)
- Server-side: 256-bit key as Azure Function environment variable

## Scripts

| Platform | Command | Output |
|----------|---------|--------|
| Windows | `.\Create-ConnectionString.ps1 -TenantId ... -ClientId ... -Environment ...` | `dpapi:<base64>` |
| macOS | `node create-connection-string.js --tenant ... --client ... --environment ...` | `keychain:<service>` |
| Linux | `node create-connection-string.js --tenant ... --client ... --environment ...` | `plain:<base64>` |

Both scripts prompt for the client secret with hidden input.

**Options:**
- `--nickname` / `-Nickname`: writes directly into Claude Desktop MCP config
- Without nickname: copies to clipboard

## Connection format

The server's `resolveConn` accepts **only** AES-256-GCM encrypted blobs.
`plain:<base64>` blobs are **rejected** — the server returns a migration
error directing the user to re-run the connection script.
