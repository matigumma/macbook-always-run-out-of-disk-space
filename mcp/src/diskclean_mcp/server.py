"""MCP server exposing diskclean.sh as agent-callable tools."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("diskclean")


def _find_script() -> Path:
    """Locate diskclean.sh — env override → bundled in package → dev mode (repo root)."""
    if override := os.environ.get("DISKCLEAN_SCRIPT"):
        p = Path(override).expanduser()
        if not p.is_file():
            raise FileNotFoundError(f"DISKCLEAN_SCRIPT={p} does not exist")
        return p

    bundled = Path(__file__).parent / "diskclean.sh"
    if bundled.is_file():
        return bundled

    # Dev mode: mcp/src/diskclean_mcp/server.py → repo root
    dev = Path(__file__).resolve().parents[3] / "diskclean.sh"
    if dev.is_file():
        return dev

    raise FileNotFoundError(
        "Could not locate diskclean.sh. Set DISKCLEAN_SCRIPT env var to the script path."
    )


def _run_script(args: list[str]) -> dict[str, Any]:
    """Invoke diskclean.sh with the given args and parse its JSON output."""
    script = _find_script()
    if not os.access(script, os.X_OK):
        try:
            os.chmod(script, 0o755)
        except PermissionError:
            pass

    bash = shutil.which("bash") or "/bin/bash"
    result = subprocess.run(
        [bash, str(script), *args],
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        msg = result.stderr.strip() or result.stdout.strip() or "(no output)"
        raise RuntimeError(f"diskclean.sh exit={result.returncode}: {msg}")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        snippet = result.stdout[:500].replace("\n", " ")
        raise RuntimeError(f"diskclean.sh did not return JSON: {e}; got: {snippet!r}")


@mcp.tool()
def scan_disk() -> dict[str, Any]:
    """Scan the Mac for reclaimable disk space. Read-only.

    Returns a dict with:
      - disk: total / used / available / reclaimable_bytes / reclaimable_human
      - items: list of cleanup candidates, each with:
          id          stable slug — pass these to clean_items()
          name        human-readable label
          description what the item is
          path        on-disk location
          command     underlying cleanup command (for transparency)
          size_bytes, size_human
          risk        "safe" | "moderate" | "risky"
          trashable   true if it can be moved to Trash (recoverable)

    Items under 10MB are filtered out. Always show the results to the user
    and get explicit consent before calling clean_items().
    """
    return _run_script(["--json"])


@mcp.tool()
def clean_items(
    ids: list[str],
    mode: Literal["trash", "delete"] = "trash",
    confirm_risky: bool = False,
) -> dict[str, Any]:
    """Execute cleanup for specific items from scan_disk(). Destructive.

    Args:
        ids: Item IDs (slugs) from scan_disk(). Must be non-empty.
        mode: "trash" (default — moves to ~/.Trash, recoverable) or
              "delete" (permanent — invokes the underlying cleanup command).
              For items where trashable=false, the command is used regardless.
        confirm_risky: Must be True to act on items with risk="risky".
                       Items marked risky without this flag are reported as
                       skipped, not executed.

    Returns a dict with:
      - results: per-item outcome (action: "trashed" | "cleaned" | "deleted" |
                                  "skipped" | "not_found" | "failed")
      - summary: { succeeded, failed, skipped, space_freed_bytes }

    SAFETY GUIDANCE for the calling agent:
      1. Default to mode="trash". Only use "delete" if the user explicitly asks
         to permanently remove (and consider warning them first).
      2. For risky items, require an explicit user confirmation before passing
         confirm_risky=True. Quote the item name and path back to them.
      3. Items needing sudo will fail in this non-interactive context. Surface
         the .command field to the user so they can run it manually.
      4. After cleanup, call disk_status() to confirm space was freed.
         (Trash items still occupy space until the Trash is emptied.)
    """
    if not ids:
        raise ValueError("ids must be a non-empty list")

    args = ["--execute", ",".join(ids), "--mode", mode]
    if confirm_risky:
        args.append("--confirm-risky")
    return _run_script(args)


@mcp.tool()
def disk_status() -> dict[str, str]:
    """Get current disk usage without running a full scan. Cheap and read-only.

    Returns total, used, and available space for the root volume.
    Useful for quick status checks or verifying space was reclaimed after cleanup.
    """
    result = subprocess.run(
        ["df", "-h", "/"],
        capture_output=True,
        text=True,
        check=True,
    )
    lines = result.stdout.strip().split("\n")
    if len(lines) < 2:
        raise RuntimeError(f"Unexpected df output: {result.stdout!r}")
    parts = lines[1].split()
    if len(parts) < 4:
        raise RuntimeError(f"Could not parse df output: {lines[1]!r}")
    return {"total": parts[1], "used": parts[2], "available": parts[3]}


def main() -> None:
    """Entry point — runs the server on stdio."""
    try:
        _find_script()
    except FileNotFoundError as e:
        print(f"diskclean-mcp: {e}", file=sys.stderr)
        sys.exit(1)
    mcp.run()


if __name__ == "__main__":
    main()
