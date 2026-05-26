# diskclean-mcp

[![PyPI](https://img.shields.io/pypi/v/diskclean-mcp)](https://pypi.org/project/diskclean-mcp/)
[![Python](https://img.shields.io/pypi/pyversions/diskclean-mcp)](https://pypi.org/project/diskclean-mcp/)
[![License](https://img.shields.io/pypi/l/diskclean-mcp)](../LICENSE)

MCP server that wraps [`diskclean.sh`](../diskclean.sh), letting agents like Claude Desktop, Claude Code, or any MCP client scan and clean a Mac's reclaimable disk space — with safety guardrails baked in.

## Tools exposed

| Tool | Returns | Notes |
|---|---|---|
| `scan_disk()` | `{ disk, items: [...] }` | Read-only. Items include stable `id`, size, risk level, path. |
| `clean_items(ids, mode, confirm_risky)` | `{ results, summary }` | Destructive. Defaults to Trash; risky items gated by flag. |
| `disk_status()` | `{ total, used, available }` | Cheap, no full scan. Good for before/after checks. |

## Quick start

```bash
uvx diskclean-mcp
```

That's it — zero install. The server runs on stdio, ready for any MCP client to connect.

### Add to Claude Desktop

```json
{
  "mcpServers": {
    "diskclean": {
      "command": "uvx",
      "args": ["diskclean-mcp"]
    }
  }
}
```

### Add to Claude Code

```bash
claude mcp add diskclean -- uvx diskclean-mcp
```

## Dev install (from this repo)

```bash
cd mcp/
uv venv
uv pip install -e .
diskclean-mcp                  # runs on stdio — test with an MCP inspector
```

To register the local server with Claude Code:

```bash
claude mcp add diskclean -- uv --directory /absolute/path/to/repo/mcp run diskclean-mcp
```

For Claude Desktop, in `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "diskclean": {
      "command": "uv",
      "args": ["--directory", "/absolute/path/to/repo/mcp", "run", "diskclean-mcp"]
    }
  }
}
```

## Safety model (how an agent should use this)

1. **Scan first.** Call `scan_disk()` and present a summary to the user (totals by risk level, biggest items). Never auto-clean.
2. **Get explicit consent** before calling `clean_items()`. Quote item names and sizes.
3. **Default to Trash.** `mode="trash"` is recoverable. Only pass `mode="delete"` if the user explicitly says so.
4. **Risky items need double opt-in.** Items with `risk="risky"` (browsers, WhatsApp, Downloads, Android SDK) are skipped unless you pass `confirm_risky=True`. Don't pass this flag without the user confirming.
5. **Sudo-required items will fail** in non-interactive mode. Surface their `command` field so the user can run them manually.
6. **Verify after.** Call `disk_status()` after cleanup to confirm space was freed. Trash items still occupy space until the Trash is emptied.

## Configuration

| Env var | Purpose |
|---|---|
| `DISKCLEAN_SCRIPT` | Override the path to `diskclean.sh` (otherwise auto-discovered: bundled in wheel, or sibling of `mcp/` in dev). |

## How it works

The server is a thin wrapper around `diskclean.sh`:

```
agent → MCP tool call → server.py → bash diskclean.sh --json | --execute → JSON → agent
```

All scanning logic lives in the bash script (single source of truth). The Python layer handles MCP protocol, argument validation, and safety messaging. Adding a new scan category means editing `diskclean.sh` only — the MCP server picks it up automatically via the dynamic item list.

## License

MIT — same as the parent project.
