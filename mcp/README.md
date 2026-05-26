# diskclean-mcp

[![PyPI](https://img.shields.io/pypi/v/diskclean-mcp)](https://pypi.org/project/diskclean-mcp/)
[![Python](https://img.shields.io/pypi/pyversions/diskclean-mcp)](https://pypi.org/project/diskclean-mcp/)
[![License](https://img.shields.io/pypi/l/diskclean-mcp)](../LICENSE)

MCP server that wraps [`diskclean.sh`](../diskclean.sh), letting agents like Claude Desktop, Claude Code, or any MCP client scan and clean a Mac's reclaimable disk space — with safety guardrails built into the protocol itself.

> **Heads-up: `0.2.0` is a breaking change vs `0.1.x`.** The destructive `clean_items()` tool was replaced by a three-step flow (`scan_disk` → `prepare_cleanup` → `execute_cleanup`) so an agent literally cannot delete anything without first surfacing a plan to the user. See [Safety model](#safety-model).

## Tools exposed

| Tool | Type | Notes |
|---|---|---|
| `scan_disk()` | Read-only | Returns `{ scan_id, disk, items: [...] }`. `scan_id` valid 5 min. |
| `prepare_cleanup(scan_id, ids, mode, confirm_risky, i_understand_deletion_is_permanent)` | Read-only | Builds a plan, returns `confirmation_token` + warnings. **Deletes nothing.** |
| `execute_cleanup(confirmation_token, i_have_user_consent, i_understand_large_cleanup)` | **Destructive** | One-shot. Consumes the token. |
| `disk_status()` | Read-only | Cheap `df` check. |

## Quick start

```bash
uvx diskclean-mcp
```

That's it — zero install. The server runs on stdio, ready for any MCP client.

### Add to Claude Code

```bash
claude mcp add diskclean -- uvx diskclean-mcp
```

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

## Safety model

The destructive `execute_cleanup` is gated by **four independent guardrails**:

| Guardrail | Triggered by | Required override |
|---|---|---|
| **Scan binding** | always | `scan_id` from a recent `scan_disk()` (≤ 5 min old) |
| **Plan token** | always | `confirmation_token` from `prepare_cleanup()` — one-shot, ≤ 5 min |
| **User consent** | always | `i_have_user_consent=True` (the agent's accountability flag) |
| **Permanent delete** | `mode="delete"` | `i_understand_deletion_is_permanent=True` (set in `prepare_cleanup`) |
| **Risky items** | items with `risk="risky"` | `confirm_risky=True` (else excluded from plan) |
| **Large cleanup** | total > 5 GB | `i_understand_large_cleanup=True` |

Why this matters: an agent that's prompt-injected, buggy, or sloppy **cannot** delete anything by calling a single tool. It has to:

1. Call `scan_disk()` → store the `scan_id`.
2. Call `prepare_cleanup()` with the chosen IDs and any required acknowledgments. Get back a `confirmation_token` and warnings.
3. **Present the plan and warnings to the user.**
4. Get explicit consent.
5. Call `execute_cleanup()` with `i_have_user_consent=True`.

Failing to follow this protocol returns clear `ValueError`s with remediation hints, all of which are logged. The flags have intentionally long, explicit names so any spurious `=True` in a transcript is obvious in review.

## Audit log

Every scan, prepare, execute, and rejection is logged as JSON Lines to:

```
~/Library/Logs/diskclean-mcp.log
```

Sample entry:

```json
{"ts":"2026-05-26T22:15:30Z","event":"execute","token":"abc...","scan_id":"def...","ids":["xcode-deriveddata"],"mode":"trash","summary":{"succeeded":1,"failed":0,"skipped":0,"space_freed_bytes":30543958016}}
```

After-the-fact forensics: `tail -f ~/Library/Logs/diskclean-mcp.log | jq`.

## Dev install (from this repo)

```bash
cd mcp/
uv venv
uv pip install -e ".[dev]"   # includes pytest
uv run pytest                # run the safety guardrail tests
diskclean-mcp                # run the server on stdio
```

To register the local server with Claude Code:

```bash
claude mcp add diskclean -- uv --directory /absolute/path/to/repo/mcp run diskclean-mcp
```

## Configuration

| Env var | Purpose |
|---|---|
| `DISKCLEAN_SCRIPT` | Override the path to `diskclean.sh` (otherwise auto-discovered: bundled in wheel, or sibling of `mcp/` in dev). |

## How it works

```
agent → MCP → server.py → bash diskclean.sh --json | --execute → JSON → server.py → MCP → agent
                ↓
        ~/Library/Logs/diskclean-mcp.log  (audit trail)
```

The bash script is the single source of truth for scanning logic and the actual destructive operations. The Python layer adds:
- Protocol-level state (scan_id, confirmation_token)
- Consent enforcement
- Audit logging
- Friendly error messages with remediation hints

Adding a new scan category means editing `diskclean.sh` only — the MCP server picks it up automatically.

## License

MIT — same as the parent project.
