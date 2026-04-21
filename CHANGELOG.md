# Changelog

All notable changes to the `origo-bc` Cowork plugin are documented here.
The plugin follows [semantic versioning](https://semver.org/).

## Unreleased

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
  claude plugin install origo-bc@origo
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
  URL to share externally — contains prerequisites, install steps for
  Cowork (GUI) and Claude Code (CLI marketplace), first-time setup,
  multi-environment guidance, and a troubleshooting section.

## [0.1.1] — 2026-04-21

### Added

- `/origo-bc-setup` and `/origo-bc-add-env` now run `node --version` up
  front and abort with a clear message if Node.js 18+ is not on PATH.
- README clarifies that Node.js is a *runtime* requirement, not just a
  setup-time one.

## [0.1.0] — 2026-04-21

Initial plugin release.

### Added

- `bc-mcp-connection-rules` auto-loading skill with Origo BC operating
  rules (MCP-Skills / MCP-Prompts / UBL Templates namespaces, two
  connection formats, update rules, EndpointID resolution).
- `/origo-bc-setup` first-time connection wizard.
- `/origo-bc-add-env` flow for additional BC tenants.
- `/origo-bc-list-environments` read-only inventory.
- `/origo-bc-switch-company` default company swap.
- Bundled scripts: `dynamics-is.js`, `Create-PlainConnectionString.ps1`,
  `create-connection-string.js`.
