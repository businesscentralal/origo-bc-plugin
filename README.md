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
│       │   ├── bc-mcp-connection-rules/SKILL.md
│       │   ├── origo-bc-setup/SKILL.md
│       │   ├── origo-bc-add-env/SKILL.md
│       │   ├── origo-bc-list-environments/SKILL.md
│       │   └── origo-bc-switch-company/SKILL.md
│       └── scripts/
│           ├── dynamics-is.js
│           ├── Create-PlainConnectionString.ps1
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

## Stable download URLs (public)

On every successful push to `main`, the pipeline also uploads the built
plugin to the public Origo blob so colleagues can download it without
needing Azure DevOps access:

- **Install guide (bilingual IS/EN)** — send this to colleagues:
  <https://origopublic.blob.core.windows.net/resources/mcp/install.html>
- **Latest plugin** (always the newest release):
  <https://origopublic.blob.core.windows.net/resources/mcp/origo-bc.plugin>
- **Versioned plugin** (immutable, one per version in `plugin.json`):
  `https://origopublic.blob.core.windows.net/resources/mcp/origo-bc-<version>.plugin`

The upload step uses the `CI Build Agent` variable group in Azure DevOps
(`StorageBaseURL` + `StorageSasToken`). The versioned copy is never
overwritten — bump `version` in `plugin.json` to publish a new release.
The install guide (`docs/install.html`) is overwritten each build.

## Cutting a release

1. Bump `plugins/origo-bc/.claude-plugin/plugin.json` → `version`
   (semver).
2. Add a new section to `CHANGELOG.md` (newest at the top, dated).
3. Commit, push to `main`. CI validates, builds, publishes the pipeline
   artifact, and uploads both `origo-bc.plugin` (latest) and
   `origo-bc-<version>.plugin` (immutable) to the public blob above.

## Installing the produced plugin

Colleagues can either download straight from the stable URL:

```
https://origopublic.blob.core.windows.net/resources/mcp/origo-bc.plugin
```

…or grab a specific version:

```
https://origopublic.blob.core.windows.net/resources/mcp/origo-bc-0.1.1.plugin
```

Then install it:

- **Cowork:** Settings → Plugins → Install from file → pick
  `origo-bc.plugin`. Or drop the file into a chat and send; the install
  card appears on the sent message.
- **Claude Code (CLI):** `claude plugin install origo-bc.plugin`.
- **Claude Desktop (regular chat app):** **not supported** — Claude
  Desktop has no plugin installer. Use Cowork or Code, or edit
  `claude_desktop_config.json` by hand.

## Adding the whole marketplace (future)

Once this repo is pushed to Azure DevOps, Cowork users can add it as a
marketplace with:

```
/plugin marketplace add https://dev.azure.com/<org>/<project>/_git/origo-bc-plugin
```

(Depends on the Cowork version; some builds only accept GitHub URLs —
verify before publishing this instruction to colleagues.)

## Contact

Origo hf. · <service@origo.is> · <https://dynamics.is>
