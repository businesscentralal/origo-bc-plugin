# Changelog

All notable changes to the `origo-bc` Cowork plugin are documented here.
The plugin follows [semantic versioning](https://semver.org/).

## [0.3.0] — 2026-04-23

### Breaking — connection format

- **`plain:<base64>` connection blobs are no longer accepted.** The MCP
  server's `resolveConn` now rejects `plain:` prefixed blobs with a
  migration error directing the user to re-run the connection script.
- **AES-256-GCM is the only supported encryption format.** Connection blobs
  are now encrypted server-side via the `encrypt_data` endpoint before
  being stored locally.
- Existing users **must re-authenticate** by running
  `Create-ConnectionString.ps1` (Windows) or
  `node create-connection-string.js` (macOS/Linux) and pasting the new blob
  into their config. Use `/origo-bc-update-env` for guided migration.

### Changed

- `Create-PlainConnectionString.ps1` renamed to `Create-ConnectionString.ps1`
  — the script now calls the `encrypt_data` MCP endpoint instead of
  producing a `plain:<base64>` blob.
- `create-connection-string.js` rewritten to call `encrypt_data` via HTTPS
  instead of producing `plain:<base64>`.
- All skill files updated to remove `plain:` references and document the
  AES-256-GCM-only flow.

### Added

- New `/origo-bc-update-env` skill — re-generates the connection blob for
  an existing `bc-<nickname>` entry. Handles v0.3 migration (detects old
  `plain:` blobs) and routine credential rotation.

## Unreleased

### Distribution (GitHub mirror)

- Azure DevOps repo is mirrored to a public GitHub repo on every
  successful `main` build:
  <https://github.com/businesscentralal/origo-bc-plugin>
- GitHub is now the primary Claude Code marketplace surface. Install
  command shortens to:

  ```
  claude plugin marketplace add businesscentralal/origo-bc-plugin
  claude plugin install origo-bc@origo-bc
  ```

- Cowork organization admins can point at the same GitHub URL when
  publishing `origo-bc` as an "org plugin" in Anthropic's Admin Console —
  the officially documented path for Cowork orgs.
- Azure DevOps remains the private source of truth. The blob-hosted
  marketplace and the `.plugin` zip are retained as fallback
  distribution channels.
- Mirror auth: fine-grained GitHub PAT with `Contents: Read & write` on
  the target repo, stored in the `CI Build Agent` variable group as
  `GitHubPat` (secret).
- README and `install.html` lead with the GitHub command; the blob
  command remains as a documented alternative.

### CI / Release

- Azure Pipelines now uploads `origo-bc.plugin` to the public Origo blob
  on every successful push to `main`:
  - <https://origopublic.blob.core.windows.net/resources/mcp/origo-bc.plugin>
    (latest, overwritten each build)
  - `https://origopublic.blob.core.windows.net/resources/mcp/origo-bc-<version>.plugin`
    (versioned, immutable)
- Pipeline also uploads the marketplace manifest and full plugin source
  tree so the blob doubles as a Claude Code plugin marketplace:
  - `.claude-plugin/marketplace.json`
  - `plugins/origo-bc/**`
  
  Claude Code users can now install with:

  ```
  claude plugin marketplace add https://origopublic.blob.core.windows.net/resources/mcp
  claude plugin install origo-bc@origo-bc
  ```
- Upload auth comes from the `CI Build Agent` variable group
  (`StorageBaseURL`, `StorageSasToken`).

### Distribution

- Plugin is now publicly available — anyone using Business Central can
  install, not just Origo staff. Install guide rewritten accordingly;
  support contact remains <service@origo.is>.

### Documentation

- Bilingual (Icelandic / English) install guide at `docs/install.html`,
  auto-uploaded to
  <https://origopublic.blob.core.windows.net/resources/mcp/install.html>
  on every build. Language toggle via `#en` hash. Designed as the one
  URL to share externally.
- Install guide restructured around Claude Desktop's three modes
  (Chat / Cowork / Code). Anchor links jump straight to the relevant
  section (`#cowork`, `#code`). Three-card decision block at the top
  helps users pick the right path before they read instructions that
  don't apply to them.
- Code section points integration developers at the
  <code>bc-cloud-events</code> skill
  (<https://origopublic.blob.core.windows.net/help/Cloud%20Events/bc27/en-US/SKILL.md>)
  and explains that Claude loads it automatically through the
  remote-loader entry in MCP-Skills once BC is connected. Wording
  clarifies that Cloud Events is a web service callable from any
  language with HTTP + OAuth (C#, Python, TypeScript, AL, PowerShell,
  Go, Java, etc.), not an AL-specific extension.
- New prerequisite section *Entra App Registration* walks through:
  (1) creating the app in Azure portal (Entra ID → App registrations),
  copying Tenant ID / Client ID, generating a client secret;
  (2) registering the same app in BC under *Microsoft Entra
  Applications* with the required **CLOUD EVENTS API** permission set
  plus baseline BC data permissions (`D365 BASIC`, `SUPER (DATA)`, or
  scoped alternatives); (3) granting admin consent. Separate
  registrations per environment are recommended.
- Azure-side instructions now match the Microsoft
  "Business Central Web Service Client" reference template:
  single-tenant or multitenant (`AzureADMultipleOrgs`) — both work,
  pick whichever fits; public-client redirect URI
  `https://businesscentral.dynamics.com/OAuthLanding.htm`,
  *Allow public client flows = Yes*, and four API permissions —
  `User.Read` (Microsoft Graph, delegated) plus
  `Financials.ReadWrite.All`, `user_impersonation` (both delegated)
  and `app_access` (application) on Dynamics 365 Business Central.
  Client-secret naming convention (`ORI<nnnn>`) and expiry guidance
  included. Minimal-setup callout flags that `app_access` alone
  suffices for MCP-only use.
- `/origo-bc-setup` input list extended to match reality: Tenant ID,
  Client ID, Client Secret, environment name, company name.

## [0.1.1] — 2026-04-21

### Added

- `/origo-bc-setup` and `/origo-bc-add-env` now run `node --version` up
  front and abort with a clear message if Node.js 18+ is not on PATH.
- README clarifies that Node.js is a *runtime* requirement, not just a
  setup-time one.

## [0.1.0] — 2026-04-21

Initial plugin release.

### Added

- `origo-bc-accounting` auto-loading skill with Origo BC operating
  rules (MCP-Skills / MCP-Prompts / UBL Templates namespaces, two
  connection formats, update rules, EndpointID resolution).
- `/origo-bc-setup` first-time connection wizard.
- `/origo-bc-add-env` flow for additional BC tenants.
- `/origo-bc-list-environments` read-only inventory.
- `/origo-bc-switch-company` default company swap.
- Bundled scripts: `dynamics-is.js`, `Create-PlainConnectionString.ps1`,
  `create-connection-string.js`.
