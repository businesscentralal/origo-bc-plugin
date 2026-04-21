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
- Upload auth comes from the `CI Build Agent` variable group
  (`StorageBaseURL`, `StorageSasToken`).

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
