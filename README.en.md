**English** · [Español](README.md)

# macbook-always-run-out-of-disk-space

[![PyPI](https://img.shields.io/pypi/v/diskclean-mcp?label=mcp%20server)](https://pypi.org/project/diskclean-mcp/)
[![License](https://img.shields.io/github/license/matigumma/macbook-always-run-out-of-disk-space)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-89e051)](diskclean.sh)
[![macOS](https://img.shields.io/badge/macOS-Catalina%2B-lightgrey)](#requirements)

> Interactive macOS disk cleanup. Tells you what can be deleted, how big it is, and how risky — before touching anything.

If you're a Mac developer, you know how the story ends: `DerivedData` eats 40 GB, `node_modules` everywhere, iOS simulators you haven't used in months, LLM models you downloaded "just to try". This script scans all that, groups by risk, and lets you choose what to delete — with safety nets (Trash + double confirmation).

Pure Bash, no dependencies, no install. One file.

> 🤖 **Using Claude Code or Claude Desktop?** There's an MCP server published on PyPI: [`diskclean-mcp`](https://pypi.org/project/diskclean-mcp/). Your agent can scan and clean disk space using native tools. See [`mcp/README.md`](mcp/README.md).

---

## Demo

```
  ╔══════════════════════════════════════════════════════════════╗
  ║              🧹  Mac Disk Cleanup Tool                       ║
  ╚══════════════════════════════════════════════════════════════╝

  Disk status:
    Total: 500G  |  Used: 487G  |  Free: 13G
    Reclaimable space found: 87.4 GB

  🟢 SAFE       — Caches and temporary files. Auto-regenerated. No risk.
  🟡 MODERATE   — Recoverable, may require reconfiguration.
  🔴 RISKY      — Data that could be lost. Double confirmation required.

  ━━━ 🟢 SAFE ━━━  (Total: 41.2 GB)

  [ 1] Xcode DerivedData                              28.4 GB  [🗑️ trash available]
       Xcode build data. Regenerated on next build.
       📁 ~/Library/Developer/Xcode/DerivedData

  [ 2] Homebrew cache                                  6.1 GB
       Downloads and old versions from Homebrew.
       📁 ~/Library/Caches/Homebrew

  [ 3] User caches (~/Library/Caches)                  4.8 GB  [🗑️ trash available]
       Application caches. Regenerated automatically.
       ...
```

> The interactive script's UI is in Spanish. An English UI is on the roadmap — PRs welcome.

---

## What makes it different

- **Risk classification** — Each item is labeled 🟢 safe / 🟡 moderate / 🔴 risky. Wiping `~/Library/Caches` is not the same as wiping `Downloads`.
- **Trash, not `rm -rf`** — For paths that can be moved, it gives you the option to send to Trash (recoverable) instead of permanent delete.
- **Double confirmation on risky items** — Nothing gets deleted by accident.
- **Native commands where appropriate** — For managers like `brew`, `npm`, `pnpm`, `pip`, `go`, `docker`, it uses the official cleanup command (doesn't break internal state).
- **Three cleanup modes** — Auto (safe only), auto + moderate, or manual selection by number.
- **Bash only** — No Python, no Node, no installers. Works on a freshly formatted Mac.

---

## What it scans

Covers ~40 common sources of "disk full" on a development Mac:

| Category | Includes |
|---|---|
| **System** | User and system caches, logs (`~/Library/Logs`, `/Library/Logs`, `/var/log`), macOS updates, Apple Media Analysis |
| **Apple dev** | Xcode DerivedData, Archives, unavailable iOS simulators |
| **Android** | Full Android SDK, AVD emulators, caches |
| **Containers** | Docker Desktop, OrbStack |
| **Package managers** | npm, pnpm, Homebrew, pip, Go modules, Cargo/Rust |
| **Runtimes** | nvm, pyenv, rustup, Reflex |
| **Editors / IDEs** | VS Code, Cursor, Windsurf, Codeium, TabNine, Azure Data Studio |
| **Local AI** | LM Studio (models), Open Interpreter |
| **Common apps** | Claude Desktop, Discord, Brave, Arc, Warp, Telegram, WhatsApp, Gradle |
| **Other** | Trash, Downloads, global venvs |

Items under 10 MB are ignored to keep the list clean.

---

## Usage

### As an interactive CLI

```bash
git clone https://github.com/matigumma/macbook-always-run-out-of-disk-space.git
cd macbook-always-run-out-of-disk-space
chmod +x diskclean.sh
./diskclean.sh
```

Or as a one-liner, without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/matigumma/macbook-always-run-out-of-disk-space/main/diskclean.sh -o diskclean.sh && chmod +x diskclean.sh && ./diskclean.sh
```

### From Claude Code / Claude Desktop (MCP)

The [MCP server](mcp/README.md) is published on PyPI as [`diskclean-mcp`](https://pypi.org/project/diskclean-mcp/). Your agent can scan and clean using native tools — through a **mandatory 3-step flow** (`scan_disk` → `prepare_cleanup` → `execute_cleanup`) that makes it **impossible** to delete anything without you having seen the plan and consented explicitly. Details in [mcp/README.md → Safety model](mcp/README.md#safety-model).

```bash
# Claude Code
claude mcp add diskclean -- uvx diskclean-mcp
```

For Claude Desktop, add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "diskclean": { "command": "uvx", "args": ["diskclean-mcp"] }
  }
}
```

Then in a conversation: *"scan my disk and clean the safe stuff"* — the agent calls `scan_disk`, shows you the result, and only cleans after your confirmation.

### Non-interactive mode (scripting / cron)

The script also accepts flags for integration with other tools:

```bash
./diskclean.sh --json                              # scan, print JSON
./diskclean.sh --execute xcode-deriveddata,homebrew-cache --mode trash
./diskclean.sh --execute android-sdk --confirm-risky
./diskclean.sh --help                              # see all options
```

> **Note:** some items require `sudo` (system caches and logs). In interactive mode the script will prompt for it when needed; in non-interactive mode those items fail and are reported as `failed`.

---

## Safety model

| Level | What it does | Example |
|---|---|---|
| 🟢 **Safe** | Deletes directly (or offers Trash). Regenerable caches. | `~/Library/Caches`, DerivedData, Homebrew cache |
| 🟡 **Moderate** | Deletes with single confirmation. May require reconfiguration. | iOS simulators, VS Code data, Apple Media Analysis |
| 🔴 **Risky** | **Double** confirmation required. Data unrecoverable without backup. | Android SDK, WhatsApp data, Downloads, Arc/Brave data |

For apps with delicate state (browsers, messaging, Docker), the script **does not delete directly** — it tells you how to clean from the app, and why.

---

## Requirements

- macOS (tested on Sonoma+, should work from Catalina)
- Bash 3.2+ (ships with macOS)
- `bc` and `du` (ship with macOS)
- Optional: `brew`, `npm`, `pnpm`, `pip`, `go`, `docker`, `xcrun` — used if present, skipped otherwise.

---

## Contributing

PRs welcome. If you know another typical source of "disk full" on Mac, add a `scan_*()` following the existing pattern:

```bash
register_item \
    "<visible name>" \
    "<size in bytes>" \
    "<safe|moderate|risky>" \
    "<path>" \
    "<cleanup command>" \
    "<description>" \
    "<yes|no>"   # can it be moved to Trash?
```

Open ideas: JetBrains IDEs, Adobe caches, Spotify cache, Steam, non-interactive cleanup support (`--auto-safe` for cron).

---

## License

MIT.
