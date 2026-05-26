"""Safety guardrail tests for the MCP server.

Every test in this file exercises a path where the wrong outcome would let
an agent destroy user data without the user having consented. If any of
these fail, the safety model is broken.
"""

from __future__ import annotations

import time
from unittest.mock import patch

import pytest

from diskclean_mcp import server


# ── Fixtures ──────────────────────────────────────────────────────────────────


def _make_item(
    item_id: str,
    name: str = "Test Item",
    size_bytes: int = 100 * 1024 * 1024,
    risk: str = "safe",
    trashable: bool = True,
) -> dict:
    return {
        "id": item_id,
        "index": 1,
        "name": name,
        "size_bytes": size_bytes,
        "size_human": f"{size_bytes // (1024 * 1024)} MB",
        "risk": risk,
        "path": f"/tmp/{item_id}",
        "command": f"echo {item_id}",
        "description": "test fixture",
        "trashable": trashable,
    }


MOCK_SCAN_RESULT = {
    "disk": {
        "total": "228Gi",
        "used": "17Gi",
        "available": "2.7Gi",
        "reclaimable_bytes": 12 * 1024 ** 3,
        "reclaimable_human": "12.0 GB",
    },
    "items": [
        _make_item("safe-item", name="Safe Item", risk="safe"),
        _make_item("moderate-item", name="Moderate Item", risk="moderate"),
        _make_item("risky-item", name="Risky Item", risk="risky", trashable=False),
        _make_item("huge-item", name="Huge Item", size_bytes=10 * 1024 ** 3, risk="safe"),
    ],
}

MOCK_EXECUTE_RESULT = {
    "results": [
        {"id": "safe-item", "success": True, "action": "trashed", "size_bytes": 100 * 1024 * 1024}
    ],
    "summary": {
        "succeeded": 1,
        "failed": 0,
        "skipped": 0,
        "space_freed_bytes": 100 * 1024 * 1024,
    },
}


@pytest.fixture(autouse=True)
def _clear_state():
    server._SCANS.clear()
    server._PLANS.clear()
    yield
    server._SCANS.clear()
    server._PLANS.clear()


@pytest.fixture
def scanned():
    """Returns a fresh scan_id after a mocked scan_disk()."""
    with patch.object(server, "_run_script", return_value=MOCK_SCAN_RESULT):
        result = server.scan_disk()
    return result["scan_id"]


# ── scan_disk ─────────────────────────────────────────────────────────────────


def test_scan_disk_returns_scan_id_and_items():
    with patch.object(server, "_run_script", return_value=MOCK_SCAN_RESULT):
        result = server.scan_disk()
    assert "scan_id" in result and len(result["scan_id"]) == 32
    assert len(result["items"]) == 4
    assert result["disk"]["reclaimable_human"] == "12.0 GB"


def test_scan_disk_caches_items_by_id(scanned):
    assert scanned in server._SCANS
    assert "safe-item" in server._SCANS[scanned]["items"]


def test_each_scan_returns_a_distinct_id():
    with patch.object(server, "_run_script", return_value=MOCK_SCAN_RESULT):
        a = server.scan_disk()["scan_id"]
        b = server.scan_disk()["scan_id"]
    assert a != b


# ── prepare_cleanup — guardrails ──────────────────────────────────────────────


def test_prepare_rejects_unknown_scan_id():
    with pytest.raises(ValueError, match="scan_id is unknown"):
        server.prepare_cleanup(scan_id="bogus-id-not-in-cache", ids=["safe-item"])


def test_prepare_rejects_expired_scan_id(scanned):
    # Manually expire
    server._SCANS[scanned]["created_at"] = time.time() - server.SCAN_TTL_SECONDS - 1
    with pytest.raises(ValueError, match="scan_id is unknown"):
        server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])


def test_prepare_rejects_empty_ids(scanned):
    with pytest.raises(ValueError, match="non-empty"):
        server.prepare_cleanup(scan_id=scanned, ids=[])


def test_prepare_rejects_delete_mode_without_acknowledgment(scanned):
    with pytest.raises(ValueError, match="i_understand_deletion_is_permanent"):
        server.prepare_cleanup(scan_id=scanned, ids=["safe-item"], mode="delete")


def test_prepare_excludes_risky_without_confirm(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item", "risky-item"])
    plan_ids = [it["id"] for it in plan["items"]]
    assert "safe-item" in plan_ids
    assert "risky-item" not in plan_ids
    assert any(e["id"] == "risky-item" for e in plan["excluded"])


def test_prepare_includes_risky_with_confirm(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["risky-item"], confirm_risky=True)
    plan_ids = [it["id"] for it in plan["items"]]
    assert "risky-item" in plan_ids


def test_prepare_excludes_unknown_ids(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item", "made-up-id"])
    assert any(e["id"] == "made-up-id" for e in plan["excluded"])


def test_prepare_raises_if_plan_is_empty_after_exclusions(scanned):
    with pytest.raises(ValueError, match="No items in the plan"):
        server.prepare_cleanup(scan_id=scanned, ids=["does-not-exist"])


def test_prepare_dedupes_ids(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item", "safe-item", "safe-item"])
    assert len(plan["items"]) == 1


# ── prepare_cleanup — warnings ────────────────────────────────────────────────


def test_prepare_warns_on_delete_mode(scanned):
    plan = server.prepare_cleanup(
        scan_id=scanned,
        ids=["safe-item"],
        mode="delete",
        i_understand_deletion_is_permanent=True,
    )
    assert any("PERMANENT DELETION" in w for w in plan["warnings"])


def test_prepare_warns_on_risky_items(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["risky-item"], confirm_risky=True)
    assert any("RISKY" in w for w in plan["warnings"])


def test_prepare_warns_on_large_cleanup(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["huge-item"])
    assert any("LARGE CLEANUP" in w for w in plan["warnings"])


def test_prepare_always_has_at_least_one_warning(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])
    assert len(plan["warnings"]) >= 1


def test_prepare_returns_a_token(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])
    assert "confirmation_token" in plan
    assert plan["confirmation_token"] in server._PLANS


# ── execute_cleanup — guardrails ──────────────────────────────────────────────


def test_execute_rejects_without_user_consent(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])
    with pytest.raises(ValueError, match="i_have_user_consent"):
        server.execute_cleanup(confirmation_token=plan["confirmation_token"])


def test_execute_rejects_explicit_false_consent(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])
    with pytest.raises(ValueError, match="i_have_user_consent"):
        server.execute_cleanup(
            confirmation_token=plan["confirmation_token"], i_have_user_consent=False
        )


def test_execute_rejects_unknown_token():
    with pytest.raises(ValueError, match="unknown or already consumed"):
        server.execute_cleanup(confirmation_token="bogus", i_have_user_consent=True)


def test_execute_rejects_expired_token(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])
    # Expire manually
    server._PLANS[plan["confirmation_token"]]["created_at"] = (
        time.time() - server.TOKEN_TTL_SECONDS - 1
    )
    with pytest.raises(ValueError, match="has expired"):
        server.execute_cleanup(
            confirmation_token=plan["confirmation_token"], i_have_user_consent=True
        )


def test_execute_rejects_large_cleanup_without_ack(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["huge-item"])
    with pytest.raises(ValueError, match="i_understand_large_cleanup"):
        server.execute_cleanup(
            confirmation_token=plan["confirmation_token"], i_have_user_consent=True
        )


def test_execute_allows_large_cleanup_with_ack(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["huge-item"])
    with patch.object(server, "_run_script", return_value=MOCK_EXECUTE_RESULT):
        result = server.execute_cleanup(
            confirmation_token=plan["confirmation_token"],
            i_have_user_consent=True,
            i_understand_large_cleanup=True,
        )
    assert result["summary"]["succeeded"] == 1


def test_execute_token_is_one_shot(scanned):
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])
    token = plan["confirmation_token"]
    with patch.object(server, "_run_script", return_value=MOCK_EXECUTE_RESULT):
        server.execute_cleanup(confirmation_token=token, i_have_user_consent=True)
    # Second call must be rejected
    with pytest.raises(ValueError, match="unknown or already consumed"):
        server.execute_cleanup(confirmation_token=token, i_have_user_consent=True)


def test_execute_consumes_token_even_on_consent_failure(scanned):
    """Confirm: failed consent does NOT consume the token (so user can retry properly)."""
    plan = server.prepare_cleanup(scan_id=scanned, ids=["safe-item"])
    token = plan["confirmation_token"]
    with pytest.raises(ValueError, match="i_have_user_consent"):
        server.execute_cleanup(confirmation_token=token)
    # Token should STILL be valid
    assert token in server._PLANS


# ── execute_cleanup — happy path ──────────────────────────────────────────────


def test_execute_happy_path_passes_args_to_bash(scanned):
    plan = server.prepare_cleanup(
        scan_id=scanned, ids=["safe-item", "moderate-item"], mode="trash"
    )

    captured_args = {}

    def fake_run(args):
        captured_args["args"] = args
        return MOCK_EXECUTE_RESULT

    with patch.object(server, "_run_script", side_effect=fake_run):
        server.execute_cleanup(
            confirmation_token=plan["confirmation_token"], i_have_user_consent=True
        )

    assert "--execute" in captured_args["args"]
    assert "safe-item,moderate-item" in captured_args["args"]
    assert "--mode" in captured_args["args"]
    assert "trash" in captured_args["args"]
    assert "--confirm-risky" not in captured_args["args"]


def test_execute_passes_confirm_risky_flag(scanned):
    plan = server.prepare_cleanup(
        scan_id=scanned, ids=["risky-item"], confirm_risky=True
    )

    captured_args = {}

    def fake_run(args):
        captured_args["args"] = args
        return MOCK_EXECUTE_RESULT

    with patch.object(server, "_run_script", side_effect=fake_run):
        server.execute_cleanup(
            confirmation_token=plan["confirmation_token"], i_have_user_consent=True
        )

    assert "--confirm-risky" in captured_args["args"]


def test_execute_passes_delete_mode(scanned):
    plan = server.prepare_cleanup(
        scan_id=scanned,
        ids=["safe-item"],
        mode="delete",
        i_understand_deletion_is_permanent=True,
    )

    captured_args = {}

    def fake_run(args):
        captured_args["args"] = args
        return MOCK_EXECUTE_RESULT

    with patch.object(server, "_run_script", side_effect=fake_run):
        server.execute_cleanup(
            confirmation_token=plan["confirmation_token"], i_have_user_consent=True
        )

    assert "delete" in captured_args["args"]


# ── disk_status ───────────────────────────────────────────────────────────────


def test_disk_status_returns_parsed_df():
    # disk_status is read-only and doesn't go through _run_script — calls df directly.
    result = server.disk_status()
    assert "total" in result and "used" in result and "available" in result
