"""Hatch build hook that bundles ../diskclean.sh into the package.

Handles two build contexts transparently:
  * Building from the source tree:  diskclean.sh lives at  ../diskclean.sh
  * Building wheel from an sdist:   diskclean.sh lives at  ./diskclean.sh

The hook locates the script and routes it into the right destination for the
current target (wheel: inside the package; sdist: at the sdist root so the
chained wheel build can find it).
"""

from __future__ import annotations

from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class BundleDiskcleanHook(BuildHookInterface):
    PLUGIN_NAME = "bundle-diskclean"

    def initialize(self, version: str, build_data: dict) -> None:
        root = Path(self.root)
        candidates = [root.parent / "diskclean.sh", root / "diskclean.sh"]
        script = next((c for c in candidates if c.is_file()), None)
        if script is None:
            checked = ", ".join(str(c) for c in candidates)
            raise FileNotFoundError(f"diskclean.sh not found (checked: {checked})")

        force_include = build_data.setdefault("force_include", {})
        if self.target_name == "wheel":
            force_include[str(script)] = "diskclean_mcp/diskclean.sh"
        elif self.target_name == "sdist":
            force_include[str(script)] = "diskclean.sh"
