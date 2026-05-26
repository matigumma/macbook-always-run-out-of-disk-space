"""MCP server for diskclean.sh — agent-driven Mac disk cleanup with safety guardrails.

The cleanup flow is intentionally three-step:

  1. scan_disk()       — read-only scan, returns a scan_id and the items list.
  2. prepare_cleanup() — build an execution plan tied to that scan_id. Returns a
                         single-use confirmation_token. DOES NOT DELETE ANYTHING.
  3. execute_cleanup() — destructive; consumes a token and requires explicit
                         consent flags from the calling agent.

This protocol exists so an agent CANNOT skip showing a plan to the user before
any deletion can happen. The consent flags are deliberate friction points:

  - i_have_user_consent                  — required for any execute_cleanup call
  - i_understand_deletion_is_permanent   — required when mode="delete"
  - i_understand_large_cleanup           — required when total size > 5 GB
  - confirm_risky                        — required to include risk="risky" items

All destructive operations (and rejections thereof) are logged as JSON lines
to ~/Library/Logs/diskclean-mcp.log for after-the-fact auditability.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

# ── Constants ─────────────────────────────────────────────────────────────────

SCAN_TTL_SECONDS = 300                                  # 5 min
TOKEN_TTL_SECONDS = 300                                 # 5 min, one-shot
LARGE_CLEANUP_THRESHOLD_BYTES = 5 * 1024 * 1024 * 1024  # 5 GB

LOG_FILE = Path.home() / "Library" / "Logs" / "diskclean-mcp.log"

# ── In-memory state (lost on server restart — by design) ──────────────────────

_SCANS: dict[str, dict[str, Any]] = {}   # scan_id -> { created_at, items: {id: item}, disk }
_PLANS: dict[str, dict[str, Any]] = {}   # token   -> { created_at, scan_id, ids, mode,
                                         #              confirm_risky, items, total_size_bytes }

# ── Helpers ───────────────────────────────────────────────────────────────────


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

    dev = Path(__file__).resolve().parents[3] / "diskclean.sh"
    if dev.is_file():
        return dev

    raise FileNotFoundError(
        "Could not locate diskclean.sh. Set DISKCLEAN_SCRIPT env var to the script path."
    )


def _run_script(args: list[str]) -> dict[str, Any]:
    """Invoke diskclean.sh and parse its JSON output."""
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


def _audit(event: str, **fields: Any) -> None:
    """Append a JSON-line entry to the audit log. Never raises."""
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        entry = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "event": event,
            **fields,
        }
        with LOG_FILE.open("a") as f:
            f.write(json.dumps(entry, separators=(",", ":")) + "\n")
    except Exception as e:  # noqa: BLE001
        # Audit logging failure must never cascade into a destructive call's safety
        print(f"diskclean-mcp: audit log write failed: {e}", file=sys.stderr)


def _expire_stale() -> None:
    now = time.time()
    for sid in [s for s, v in _SCANS.items() if now - v["created_at"] > SCAN_TTL_SECONDS]:
        del _SCANS[sid]
    for tok in [t for t, v in _PLANS.items() if now - v["created_at"] > TOKEN_TTL_SECONDS]:
        del _PLANS[tok]


def _humanize(b: int) -> str:
    if b >= 1024 ** 3:
        return f"{b / 1024 ** 3:.1f} GB"
    if b >= 1024 ** 2:
        return f"{b / 1024 ** 2:.0f} MB"
    if b >= 1024:
        return f"{b / 1024:.0f} KB"
    return f"{b} B"


# ── MCP server ────────────────────────────────────────────────────────────────

mcp = FastMCP("diskclean")


@mcp.tool()
def scan_disk() -> dict[str, Any]:
    """READ-ONLY. Scan the Mac for reclaimable disk space.

    Returns:
        {
          "scan_id": str          -- opaque token, required for prepare_cleanup().
                                     Valid for 5 minutes.
          "disk":    { total, used, available, reclaimable_bytes, reclaimable_human },
          "items":   [{ id, name, description, path, command,
                        size_bytes, size_human, risk, trashable }, ...]
        }

    Items under 10 MB are filtered out.

    REQUIRED AGENT BEHAVIOR:
      - Always call this first before any cleanup. prepare_cleanup() will
        reject calls without a fresh scan_id.
      - Present the items to the user (grouping by risk level is recommended).
      - Let the user choose which items to clean. Do not auto-select.
    """
    _expire_stale()
    raw = _run_script(["--json"])

    scan_id = uuid.uuid4().hex
    items_by_id = {it["id"]: it for it in raw["items"]}
    _SCANS[scan_id] = {
        "created_at": time.time(),
        "items": items_by_id,
        "disk": raw["disk"],
    }

    _audit(
        "scan",
        scan_id=scan_id,
        item_count=len(items_by_id),
        reclaimable_bytes=raw["disk"]["reclaimable_bytes"],
    )
    return {"scan_id": scan_id, "disk": raw["disk"], "items": raw["items"]}


@mcp.tool()
def prepare_cleanup(
    scan_id: str,
    ids: list[str],
    mode: Literal["trash", "delete"] = "trash",
    confirm_risky: bool = False,
    i_understand_deletion_is_permanent: bool = False,
) -> dict[str, Any]:
    """READ-ONLY. Build a cleanup plan from a recent scan. Does NOT delete anything.

    Step 2 of the cleanup flow: scan_disk() → prepare_cleanup() → execute_cleanup().

    Args:
        scan_id: From a recent scan_disk(). Must be < 5 minutes old.
        ids: Item IDs (slugs) to include in the cleanup plan.
        mode:
            "trash"  (default) — move to ~/.Trash, recoverable until emptied.
            "delete" — invoke the underlying cleanup command. PERMANENT.
                       REQUIRES i_understand_deletion_is_permanent=True.
        confirm_risky: True to include items with risk="risky".
                       Risky items are excluded by default.
        i_understand_deletion_is_permanent: REQUIRED when mode="delete". Only
                       set True if the user explicitly asked for permanent
                       deletion (not recoverable from Trash). When in doubt,
                       use mode="trash".

    Returns:
        {
          "confirmation_token":  str    -- pass to execute_cleanup(). One-shot, 5 min.
          "items":               [...]  -- full info on each item in the plan.
          "total_size_bytes":    int,
          "total_size_human":    str,
          "mode":                str,
          "warnings":            [str]  -- human-readable warnings; surface to user.
          "excluded":            [{id, reason}]  -- items dropped from the plan.
          "expires_in_seconds":  int,
        }

    REQUIRED AGENT BEHAVIOR:
      1. Present the plan verbatim: items, sizes, mode.
      2. Read every entry in `warnings` to the user. Do not summarize them away.
      3. Wait for explicit consent. Quote the user's confirmation back.
      4. Only then call execute_cleanup() with i_have_user_consent=True.
    """
    _expire_stale()

    if not ids:
        raise ValueError("ids must be a non-empty list")

    scan = _SCANS.get(scan_id)
    if scan is None:
        _audit("prepare_rejected", reason="invalid_scan_id", scan_id=scan_id)
        raise ValueError(
            "scan_id is unknown or expired. Call scan_disk() first to get a fresh one."
        )

    if mode == "delete" and not i_understand_deletion_is_permanent:
        _audit("prepare_rejected", reason="missing_delete_acknowledgment", scan_id=scan_id)
        raise ValueError(
            'mode="delete" requires i_understand_deletion_is_permanent=True. '
            'Only set this True if the user has explicitly asked for permanent '
            'deletion. Use mode="trash" (default) for recoverable cleanup.'
        )

    plan_items: list[dict[str, Any]] = []
    excluded: list[dict[str, str]] = []
    seen: set[str] = set()

    for item_id in ids:
        if item_id in seen:
            continue
        seen.add(item_id)

        item = scan["items"].get(item_id)
        if item is None:
            excluded.append({"id": item_id, "reason": "not in scan"})
            continue
        if item["risk"] == "risky" and not confirm_risky:
            excluded.append({
                "id": item_id,
                "reason": "risky item; pass confirm_risky=True only after explicit user confirmation",
            })
            continue
        plan_items.append(item)

    if not plan_items:
        raise ValueError(
            "No items in the plan after exclusions. See 'excluded' for reasons. "
            "Adjust the call or surface the exclusions to the user."
        )

    total_size = sum(it["size_bytes"] for it in plan_items)

    warnings: list[str] = []
    if mode == "delete":
        warnings.append(
            "PERMANENT DELETION: items will NOT go to Trash. They cannot be recovered. "
            "Confirm the user really wants this (instead of the default mode='trash')."
        )
    risky_items = [it for it in plan_items if it["risk"] == "risky"]
    if risky_items:
        names = ", ".join(it["name"] for it in risky_items)
        warnings.append(
            f"{len(risky_items)} RISKY item(s) in plan: {names}. "
            "These contain user data that is NOT auto-regenerable. Quote each one to the user."
        )
    if total_size > LARGE_CLEANUP_THRESHOLD_BYTES:
        warnings.append(
            f"LARGE CLEANUP: {_humanize(total_size)} will be removed in one operation. "
            "execute_cleanup() will require i_understand_large_cleanup=True. "
            "Confirm the total size with the user explicitly."
        )
    if not warnings:
        warnings.append(
            "No special risks detected. Still confirm the plan with the user before executing."
        )

    token = uuid.uuid4().hex
    _PLANS[token] = {
        "created_at": time.time(),
        "scan_id": scan_id,
        "ids": [it["id"] for it in plan_items],
        "mode": mode,
        "confirm_risky": confirm_risky,
        "items": plan_items,
        "total_size_bytes": total_size,
    }

    _audit(
        "prepare",
        token=token,
        scan_id=scan_id,
        ids=[it["id"] for it in plan_items],
        mode=mode,
        confirm_risky=confirm_risky,
        total_size_bytes=total_size,
    )

    return {
        "confirmation_token": token,
        "items": plan_items,
        "total_size_bytes": total_size,
        "total_size_human": _humanize(total_size),
        "mode": mode,
        "warnings": warnings,
        "excluded": excluded,
        "expires_in_seconds": TOKEN_TTL_SECONDS,
    }


@mcp.tool()
def execute_cleanup(
    confirmation_token: str,
    i_have_user_consent: bool = False,
    i_understand_large_cleanup: bool = False,
) -> dict[str, Any]:
    """DESTRUCTIVE. Run the cleanup plan associated with a confirmation_token.

    Step 3 of the cleanup flow. Tokens are one-shot: a single successful
    execute_cleanup() consumes the token.

    Args:
        confirmation_token: From prepare_cleanup(). Valid for 5 minutes.
        i_have_user_consent: REQUIRED. Set True only if the user has explicitly
                       and recently consented to THIS plan in THIS conversation.
                       Setting this True without user consent is a safety
                       violation. The agent is accountable — never set True
                       without quoting the user's confirmation.
        i_understand_large_cleanup: REQUIRED when the plan's total size exceeds
                       5 GB. An extra friction point for bulk operations.

    Returns:
        {
          "results": [{ id, success, action, size_bytes?, message? }, ...]
          "summary": { succeeded, failed, skipped, space_freed_bytes, space_freed_human }
        }

    Items requiring sudo will fail in non-interactive mode — surface their
    .command field (from scan_disk) so the user can run them manually.
    """
    # Do NOT call _expire_stale() before the token check — we want the explicit
    # "token expired" path (with its actionable message) to fire rather than
    # the generic "unknown token" one.

    if not i_have_user_consent:
        _audit("execute_rejected", reason="missing_user_consent", token=confirmation_token)
        raise ValueError(
            "execute_cleanup() requires i_have_user_consent=True. "
            "Show the prepare_cleanup() plan to the user, get explicit consent in this "
            "conversation, and only then call this tool with the flag set. "
            "Inferring consent from prior messages or your own reasoning is a violation."
        )

    plan = _PLANS.get(confirmation_token)
    if plan is None:
        _audit("execute_rejected", reason="invalid_token", token=confirmation_token)
        raise ValueError(
            "confirmation_token is unknown or already consumed. "
            "Call prepare_cleanup() to get a fresh one."
        )

    if time.time() - plan["created_at"] > TOKEN_TTL_SECONDS:
        del _PLANS[confirmation_token]
        _audit("execute_rejected", reason="token_expired", token=confirmation_token)
        raise ValueError(
            f"confirmation_token has expired ({TOKEN_TTL_SECONDS}s TTL). "
            "Call prepare_cleanup() again."
        )

    if plan["total_size_bytes"] > LARGE_CLEANUP_THRESHOLD_BYTES and not i_understand_large_cleanup:
        _audit(
            "execute_rejected",
            reason="large_cleanup_unacknowledged",
            token=confirmation_token,
            total_size_bytes=plan["total_size_bytes"],
        )
        raise ValueError(
            f"Plan total size is {_humanize(plan['total_size_bytes'])}, exceeding the 5 GB threshold. "
            "Pass i_understand_large_cleanup=True after confirming the size with the user."
        )

    # Consume the token BEFORE running — one-shot semantics, even on failure.
    del _PLANS[confirmation_token]

    args = ["--execute", ",".join(plan["ids"]), "--mode", plan["mode"]]
    if plan["confirm_risky"]:
        args.append("--confirm-risky")

    try:
        result = _run_script(args)
    except Exception as e:
        _audit("execute_error", token=confirmation_token, error=str(e))
        raise

    summary = result.get("summary", {})
    summary["space_freed_human"] = _humanize(summary.get("space_freed_bytes", 0))
    result["summary"] = summary

    _audit(
        "execute",
        token=confirmation_token,
        scan_id=plan["scan_id"],
        ids=plan["ids"],
        mode=plan["mode"],
        summary=summary,
    )
    return result


@mcp.tool()
def disk_status() -> dict[str, str]:
    """READ-ONLY. Get current disk usage without a scan. Cheap.

    Returns total / used / available for the root volume.
    Useful for verifying space was reclaimed after cleanup.
    """
    result = subprocess.run(["df", "-h", "/"], capture_output=True, text=True, check=True)
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
    _audit("server_start", pid=os.getpid())
    mcp.run()


if __name__ == "__main__":
    main()
