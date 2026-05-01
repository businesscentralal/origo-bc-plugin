# Origo BC — Claude plugin

Guided integration of Microsoft Dynamics 365 Business Central with Claude via
the Origo MCP endpoint at `https://dynamics.is/api/mcp`. The plugin bundles
the local `stdio-proxy` bridge and helper scripts, and ships slash commands
that walk the user through connecting their BC tenants. Works in both
**Cowork** and **Code** modes.

## Installation

**Recommended — GitHub Marketplace** (works in both Cowork and Code):

```bash
claude plugin marketplace add businesscentralal/origo-bc-plugin
claude plugin install origo-bc@origo-bc
```

**Alternative — .plugin file** (Cowork only): download `origo-bc.plugin` from
the [install page](https://origopublic.blob.core.windows.net/resources/mcp/install.html)
and drop it into a Cowork chat.

## What it installs

On first use of `/origo-bc-setup`, the plugin copies its bundled scripts to

```
%USERPROFILE%\OrigoBC\
```

and writes a new entry into the Claude Desktop MCP config pointing at
`stdio-proxy.js`. A connection blob — AES-256-GCM ciphertext produced by
the server's `encrypt_data` endpoint, optionally DPAPI-wrapped on Windows —
is generated locally and stored in the MCP config args.

## Components

All slash commands (`/origo-bc-*`) are packaged as skills under `skills/`,
which Cowork surfaces as slash commands. There is no legacy `commands/`
directory.

| Kind   | Name                                             | Purpose                                                                                      |
| ------ | ------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Skill  | `origo-bc-accounting`                        | Loads the Origo BC accounting & development rules whenever BC, MCP, or memory tools are mentioned.      |
| Skill  | `origo-bc-cloud-events`                      | Loads the Cloud Events API authoring rules, message type catalog, and examples for MCP development. |
| Skill  | `origo-bc-setup` (`/origo-bc-setup`)              | First-time connection wizard: copies scripts, collects credentials, writes the config entry. |
| Skill  | `origo-bc-add-env` (`/origo-bc-add-env`)          | Adds an additional BC tenant / environment to an existing install.                           |
| Skill  | `origo-bc-update-env` (`/origo-bc-update-env`)    | Re-generates the connection blob for an existing entry (migration, credential rotation).     |
| Skill  | `origo-bc-list-environments` (`/origo-bc-list-environments`) | Lists every BC entry currently configured in the Cowork MCP config file.          |
| Skill  | `origo-bc-switch-company` (`/origo-bc-switch-company`) | Swaps the default company GUID on an existing entry.                                    |
| Script | `scripts/dynamics-is.js`                         | stdio ↔ HTTP bridge the MCP config launches per connection.                                  |
| Script | `scripts/Create-ConnectionString.ps1`             | Windows PowerShell helper: encrypts credentials via `encrypt_data` endpoint, DPAPI-wraps the ciphertext. |
| Script | `scripts/create-connection-string.js`            | Cross-platform Node helper that does the same via HTTPS (DPAPI on Windows, raw elsewhere).   |

## Prerequisites

- **Node.js 18+** on PATH — **required at all times**, not just during
  setup. Every `bc-*` entry Claude launches is literally
  `node <path>\dynamics-is.js ...`, so the connection will not start
  without it. `/origo-bc-setup` and `/origo-bc-add-env` both run
  `node --version` up front and refuse to continue if it's missing.
- **Windows** for the PowerShell flow. On macOS / Linux use the Node helper
  with `--no-dpapi`; protect the resulting config file with filesystem
  permissions or a secret manager.
- An **Azure AD app registration** with either:
  - **Client Secret** (client credentials / unattended): `app_access` Application
    permission, plus a client secret. You need Tenant ID, Client ID, and Client Secret.
  - **Device Code** (delegated / user sign-in): `Financials.ReadWrite.All` and
    `user_impersonation` Delegated permissions, plus "Allow public client flows" enabled.
    You need Tenant ID and Client ID only (no secret).

See the [install guide](https://origopublic.blob.core.windows.net/resources/mcp/install.html)
for step-by-step Entra setup for each auth mode.

## Usage

After installing the plugin, run `/origo-bc-setup` in Cowork. The command
will walk you through:

1. Choosing a nickname (used as the MCP server key, e.g. `bc-kappi`).
2. Entering tenant ID, client ID, environment, and optional default company.
3. Generating the connection blob in a PowerShell window (the client secret
   never passes through Claude's chat — it is prompted as a SecureString
   directly by `Create-ConnectionString.ps1`).
4. Pasting the resulting AES-256-GCM blob (`dpapi:`-wrapped on Windows,
   raw base64 on macOS/Linux) back into Claude.
5. Updating the Cowork MCP config and asking you to restart Cowork.

After restart, `mcp__bc-<nickname>__*` tools become available. Test with
`list_companies`.

Add further tenants with `/origo-bc-add-env`. Inspect what is configured
with `/origo-bc-list-environments`. Point an existing entry at a different
company with `/origo-bc-switch-company`.

## Security notes

- Client secrets are collected as PowerShell `SecureString` or via Node's
  hidden-input prompt — never through Claude's chat interface.
- On Windows, the blob in `claude_desktop_config.json` is DPAPI-wrapped with
  `CurrentUser` scope, so copying the config file to another machine or
  Windows user renders it unusable.
- On mac