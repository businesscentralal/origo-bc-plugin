# Origo BC — Cowork plugin monorepo

Source tree for the `origo-bc` Cowork plugin, packaged as a single-plugin
Cowork marketplace. Azure Pipelines builds `origo-bc.plugin` as an
artifact on every push to `main`.

## Repository layout

```
.
├── .claude-plugin/
│   └── marketplace.json          # marketplace manifest (one plugin: origo-bc)
├── plugins/
│   └── origo-bc/                 # the plugin itself
│       ├── .claude-plugin/plugin.json
│       ├── README.md
│       ├── skills/
│       │   ├── origo-bc-accounting/SKILL.md
│       │   ├── origo-bc-cloud-events/SKILL.md
│       │   ├── origo-bc-setup/SKILL.md
│       │   ├── origo-bc-add-env/SKILL.md
│       │   ├── origo-bc-list-environments/SKILL.md
│       │   ├── origo-bc-update-env/SKILL.md
│       │   └── origo-bc-switch-company/SKILL.md
│       └── scripts/
│           ├── dynamics-is.js
│           ├── Create-ConnectionString.ps1
│           └── create-connection-string.js
├── scripts/
│   ├── validate-plugin.sh        # syntax + structure checks
│   └── build-plugin.sh           # produces origo-bc.plugin
├── docs/
│   └── install.html              # bilingual IS/EN install guide (blob-hosted)
├── azure-pipelines.yml           # CI definition
├── CHANGELOG.md
├── .gitignore
└── README.md                     # this file
```

## Build locally

Requires: `bash`, `zip`, `jq`, `node` (any recent version).

```bash
# Validate the plugin source
bash scripts/validate-plugin.sh plugins/origo-bc

# Build origo-bc.plugin into ./build/
bash scripts/build-plugin.sh plugins/origo-bc ./build
ls -la build/
```

The produced `build/origo-bc.plugin` is the same artifact Azure Pipelines
publishes.

## CI build

`azure-pipelines.yml` triggers on:

- push to `main` touching `plugins/`, `scripts/`, `.claude-plugin/`, or
  the pipeline file itself
- PRs targeting `main` (validation only — no artifact published)

Published artifact: **`origo-bc-plugin`** (contains `origo-bc.plugin`).
Download from the pipeline run page in Azure DevOps under **Artifacts →
origo-bc-plugin**.

## Stable public URLs

Azure DevOps is the private source of truth. On every successful push
to `main`, the pipeline publishes to two public surfaces — pick whichever
fits your tool. The GitHub mirror is the primary path for Claude Code
users; the Origo blob keeps the `.plugin` zip and the bilingual install
guide.

### Primary: public GitHub mirror

- **Public repo** — native Claude Code marketplace format:
  <https://github.com/businesscentralal/origo-bc-plugin>

Claude Code users install with one short command pair:

```
claude plugin marketplace add businesscentralal/origo-bc-plugin
claude plugin install origo-bc@origo
```

Cowork organization admins can point the same URL at their "org plugin"
marketplace inside Anthropic's Admin Console — the officially documented
path for Cowork orgs. The mirror push uses a fine-grained GitHub PAT
stored in the `CI Build Agent` variable group as `GitHubPat`.

### Secondary: Origo blob

Kept for the Cowork drag-and-drop path, the bilingual install guide,
and as a fallback marketplace.

- **Install guide (bilingual IS/EN)** — the public-facing page:
  <https://origopublic.blob.core.windows.net/resources/mcp/install.html>
- **Marketplace root** — alternative Claude Code install URL:
  <https://origopublic.blob.core.windows.net/resources/mcp>
- **Marketplace manifest** (direct link, rarely needed):
  <https://origopublic.blob.core.windows.net/resources/mcp/.claude-plugin/marketplace.json>
- **Latest plugin file** (for Cowork's drag-and-drop install):
  <https://origopublic.blob.core.windows.net/resources/mcp/origo-bc.plugin>
- **Versioned plugin** (immutable, one per version in `plugin.json`):
  `https://origopublic.blob.core.windows.net/resources/mcp/origo-bc-<version>.plugin`

The blob upload uses `StorageBaseURL` + `StorageSasToken` from the same
variable group. The versioned `.plugin` copy is never overwritten — bump
`version` in `plugin.json` to publish a new release. The install guide,
marketplace manifest, and plugin source tree are overwritten on every
build.

## Cutting a release

1. Bump `plugins/origo-bc/.claude-plugin/plugin.json` → `version`
   (semver).
2. Add a new section to `CHANGELOG.md` (newest at the top, dated).
3. Commit, push to `main`. CI validates, builds, publishes the pipeline
   artifact, and uploads both `origo-bc.plugin` (latest) and
   `origo-bc-<version>.plugin` (immutable) to the public blob above.

## Installing the produced plugin

Two supported paths. Point end-users at the install guide at
<https://origopublic.blob.core.windows.net/resources/mcp/install.html>
rather than this README — it walks through both paths in Icelandic and
English.

### Cowork (GUI) — download and drop

Download the `.plugin` file from the stable URL:

```
https://origopublic.blob.core.windows.net/resources/mcp/origo-bc.plugin
```

…or pin a specific version:

```
https://origopublic.blob.core.windows.net/resources/mcp/origo-bc-0.1.1.plugin
```

Then:

- **Cowork:** Settings → Plugins → Install from file → pick
  `origo-bc.plugin`. Or drop the file into a chat and send; the install
  card appears on the sent message.

### Claude Code (CLI) — marketplace install

Claude Code resolves the plugin source directly from the GitHub mirror:

```
claude plugin marketplace add businesscentralal/origo-bc-plugin
claude plugin install origo-bc@origo
```

Equivalent blob-based command (fallback, same content):

```
claude plugin marketplace add https://origopublic.blob.core.windows.net/resources/mcp
claude plugin install origo-bc@origo
```

To update later: `claude plugin update origo-bc@origo`.
To remove: `claude plugin uninstall origo-bc`.

### Claude Desktop (regular chat app)

**Not supported** — Claude Desktop has no plugin installer. Use Cowork
or Claude Code, or edit `claude_desktop_config.json` by hand.

## Contact

Origo hf. · <service@origo.is> · <https://dynamics.is>
