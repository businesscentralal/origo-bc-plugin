---
name: origo-bc-list-environments
description: >
  List every Business Central tenant / environment currently configured in
  the Cowork MCP config. Use this skill when the user types
  `/origo-bc-list-environments`, asks which BC environments are connected,
  which BC tenants Cowork knows about, what `bc-*` MCP servers are
  registered, or wants to audit their Origo BC setup. Reads the Cowork /
  Claude Desktop MCP config file and shows a table of every `bc-*` entry
  with its resolved default company (if any).
metadata:
  version: "0.1.0"
  author: "Origo hf."
---

# `/origo-bc-list-environments` — Show configured BC tenants

Reads the Cowork MCP config and lists every `bc-*` entry.

## What this command does

1. Locate the Cowork / Claude Desktop config file:
   - Windows: `%APPDATA%\Claude\claude_desktop_config.json`
   - macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
   - Linux: `~/.config/Claude/claude_desktop_config.json`
2. Parse the JSON and collect every key under `mcpServers` starting with
   `bc-`.
3. For each entry, extract:
   - The nickname (key after `bc-` prefix).
   - The default company GUID, if present (third element of `args`).
   - Whether the blob is DPAPI-wrapped (`dpapi:`) or raw (`plain:`).
4. Render a table:

   | Nickname | Default company | Auth format | Script path |
   | -------- | --------------- | ----------- | ----------- |
   | kappi    | `AAAA-...`      | dpapi       | `...\OrigoBC\dynamics-is.js` |
   | cronus   | _(none)_        | dpapi       | `...\OrigoBC\dynamics-is.js` |

5. If no `bc-*` entries exist, tell the user and suggest `/origo-bc-setup`.

## Guardrails

- **Never** print the `dpapi:` / `plain:` blob itself. Only report its
  length and format prefix.
- Don't modify the config file — this command is read-only.
- If the config file is missing or malformed, report the failure and stop;
  don't attempt to repair it.

## Optional enrichment

If the user explicitly asks ("which companies are in each?"), you may
call `mcp__bc-<nickname>__list_companies` per entry to show the resolved
companies. Don't do that by default — it hits the network and spins up the
proxy for every tenant.
