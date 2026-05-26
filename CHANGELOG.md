# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the MCP server
(`diskclean-mcp` on PyPI) follows [Semantic Versioning](https://semver.org/).

The bash CLI (`diskclean.sh`) is versioned implicitly through git tags;
behavioral changes that affect it are noted in the relevant MCP release.

## [Unreleased]

_Nothing yet._

## [0.2.0] — 2026-05-26

Breaking release driven by a safety audit. The previous `clean_items()` tool
let an agent destroy data in a single call; the only protection was a
docstring asking the agent to "please ask the user first". This release
makes that protection a property of the protocol itself.

### Added

- **Three-step cleanup flow** in the MCP server:
  `scan_disk()` → `prepare_cleanup()` → `execute_cleanup()`. An agent
  cannot complete a destructive operation in a single tool call.
- **`scan_id`** returned by `scan_disk()` and required by
  `prepare_cleanup()`. 5-minute TTL. Binds an execution to a specific scan.
- **`confirmation_token`** returned by `prepare_cleanup()` and required by
  `execute_cleanup()`. One-shot, 5-minute TTL.
- **Consent flags** with deliberately verbose names (so spurious `=True`
  in transcripts is obvious in review):
  - `i_have_user_consent` — required on every `execute_cleanup` call
  - `i_understand_deletion_is_permanent` — required when `mode="delete"`
  - `i_understand_large_cleanup` — required when total > 5 GB
- **Audit log** at `~/Library/Logs/diskclean-mcp.log` — JSON Lines for
  every scan, prepare, execute, and rejection.
- **Per-action warnings** in the `prepare_cleanup` response — surfaced to
  the user verbatim (permanent deletion, risky items, large cleanup).
- **Test suite** (`mcp/tests/test_server.py`) — 29 pytest tests covering
  every guardrail.
- `pytest` available as a dev dependency: `pip install diskclean-mcp[dev]`.

### Changed

- **BREAKING**: `clean_items()` removed. Migrate to the three-step flow.
- **diskclean.sh** (`execute_cleanup` interactive): empty/unknown input on
  the trash/delete prompt now always defaults to Trash, regardless of risk
  level. Previously SAFE items defaulted to permanent delete — a distracted
  user could lose data by pressing Enter.
- MCP tool docstrings rewritten with explicit "REQUIRED", "MUST",
  "violation" language. Less interpretable as polite suggestions.

### Fixed

- Audit log can no longer break the safety model — write failures log to
  stderr but do not propagate.

### Security

This release directly addresses findings from the safety audit:

| Finding | Severity | Status |
|---|---|---|
| MCP has no protocol-level user confirmation | 🔴 Critical | Fixed |
| Interactive default-on-empty = permanent delete | 🔴 Critical | Fixed |
| `mode="delete"` had no symmetric guardrail | 🟠 High | Fixed |
| No scan↔execute binding | 🟠 High | Fixed |
| No audit log | 🟠 High | Fixed |
| No size-threshold warning | 🟡 Medium | Fixed |
| Soft language in docstrings | 🟢 Low | Fixed |
| No safety test | 🟢 Low | Fixed |

Deferred: MCP elicitation (`ctx.elicit()`) — the SDK supports it but it's
experimental and Claude Desktop/Code don't reliably support the callback
yet. The three-step flow provides equivalent protection at the protocol
level without requiring client cooperation.

## [0.1.0] — 2026-05-26

First public release.

### Added

- `diskclean.sh` — interactive Bash CLI that scans ~40 common sources of
  disk usage on a development Mac, classifies them as
  🟢 safe / 🟡 moderate / 🔴 risky, and lets the user pick what to
  clean. Per-item choice between Trash (recoverable) and permanent
  delete. Double confirmation required for risky items.
- `--json` and `--execute <ids>` non-interactive modes for scripting.
- `diskclean-mcp` Python MCP server published to PyPI. Three tools:
  `scan_disk`, `clean_items`, `disk_status`. Distributed via `uvx`.
- Bilingual README (Spanish/English). MIT license.

[Unreleased]: https://github.com/matigumma/macbook-always-run-out-of-disk-space/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/matigumma/macbook-always-run-out-of-disk-space/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/matigumma/macbook-always-run-out-of-disk-space/releases/tag/v0.1.0
