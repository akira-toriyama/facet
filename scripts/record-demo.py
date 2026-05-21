#!/usr/bin/env python3
"""Record a facet demo screencast for README / docs/demo.gif.

Phase 2 approach (memory: 2026-05-21): external automation via
``screencapture`` + ``cliclick`` + (optional) ``ffmpeg``. The
facet app itself is not modified — Phase 3 (facet-internal demo
mode) was considered and rejected as an architectural
compromise.

Usage
-----
  scripts/record-demo.py [SCENARIO] [--dry-run] [--silent]

Scenarios
---------
  tree-click   tree row click + workspace switch          (~12 s)
  grid-drag    grid overview + cell DnD                   (~14 s)
  full         tree-click → clean → grid-drag back-to-back

Outputs
-------
  docs/demo-<scenario>.mov
  docs/demo-<scenario>.gif    (if ffmpeg is available)
  /tmp/facet-record-demo.log  (tee of stdout/stderr; suppress with --silent)

Prerequisites (install once)
----------------------------
  brew install cliclick ffmpeg

  cliclick will request Accessibility on first click — grant it.

IMPORTANT: the coordinate defaults below assume the tree panel
sits at its default top-left position and the display is wide
enough for the grid cells used in grid-drag. If your layout
differs, edit ``Coords`` below or run with ``--dry-run`` first
to see the printed coordinates without actually clicking.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
LOG_PATH = Path("/tmp/facet-record-demo.log")


# -----------------------------------------------------------------
# Log tee — default ON so reruns / agent inspection are easy.
# -----------------------------------------------------------------

class Tee:
    """Mirror writes to a primary stream + a secondary log file."""

    def __init__(self, primary, secondary):
        self.primary = primary
        self.secondary = secondary

    def write(self, data: str) -> int:
        n = self.primary.write(data)
        self.secondary.write(data)
        self.secondary.flush()
        return n

    def flush(self) -> None:
        self.primary.flush()
        self.secondary.flush()

    def isatty(self) -> bool:
        return self.primary.isatty()


def install_log_tee() -> None:
    """Tee stdout + stderr to LOG_PATH. Subprocess output is fd-level
    and not captured here — only this script's print() calls land in
    the log. That's enough to reconstruct what ran."""
    log_f = LOG_PATH.open("w")
    sys.stdout = Tee(sys.stdout, log_f)
    sys.stderr = Tee(sys.stderr, log_f)
    print(f"[log] tee → {LOG_PATH}")


# -----------------------------------------------------------------
# Tunables — adjust to your display + panel layout.
# -----------------------------------------------------------------

@dataclass(frozen=True)
class Coords:
    """Click coordinates. All in screen pixels (top-left = 0,0)."""

    # Tree panel rows (panel ~248 px wide at default position).
    row_y_offset: int = 80          # first row y
    row_height: int = 44            # window-with-title row height
    panel_center_x: int = 130       # ≈ sidebarWidth / 2

    # Grid overlay cells (assumes 1920x1080-ish main display + cols=5).
    grid_cell_1_x: int = 400        # source cell center
    grid_cell_1_y: int = 300
    grid_cell_2_x: int = 1200       # destination cell center
    grid_cell_2_y: int = 300


@dataclass(frozen=True)
class Timing:
    """Sleep budgets (seconds). Nudge if your machine is faster / slower."""

    short: float = 0.8
    medium: float = 1.5
    long: float = 2.5


# -----------------------------------------------------------------
# Runner — uniform exec / dry-run wrapper.
# -----------------------------------------------------------------

class Runner:
    """Executes commands; in dry-run mode prints them instead."""

    def __init__(self, dry_run: bool):
        self.dry_run = dry_run

    def run(
        self,
        *cmd: str,
        background: bool = False,
    ) -> Optional[subprocess.Popen]:
        if self.dry_run:
            tag = "[DRY:BG]" if background else "[DRY]"
            print(tag, " ".join(cmd))
            return None
        if background:
            return subprocess.Popen(list(cmd))
        subprocess.run(list(cmd), check=False)
        return None

    def sleep(self, sec: float) -> None:
        if self.dry_run:
            print(f"[DRY] sleep {sec}")
            return
        time.sleep(sec)


# -----------------------------------------------------------------
# Prereqs + clean-state setup.
# -----------------------------------------------------------------

def check_prerequisites() -> None:
    """Fail loud + actionable if required tools / bundle are missing."""
    missing = [t for t in ("cliclick", "screencapture")
               if shutil.which(t) is None]
    if missing:
        sys.stderr.write(
            f"error: required tools missing: {' '.join(missing)}\n"
            f"       install: brew install {' '.join(missing)}\n"
        )
        if "screencapture" in missing:
            sys.stderr.write(
                "       (screencapture ships with macOS — if it's "
                "missing your install is broken)\n"
            )
        sys.exit(1)

    if shutil.which("ffmpeg") is None:
        sys.stderr.write(
            "warning: ffmpeg not found — gif conversion will be skipped\n"
            "         (install: brew install ffmpeg)\n"
        )

    bundle = REPO_ROOT / "Facet.app"
    if not bundle.is_dir():
        sys.stderr.write(
            f"error: {bundle.name} not found in repo root.\n"
            "       build first: ./package.sh   (or ./run.sh)\n"
        )
        sys.exit(1)


def clean_facet_state(runner: Runner, timing: Timing) -> None:
    """Kill any existing facet, launch a single fresh release bundle."""
    print("[setup] killing existing facet instances...")
    runner.run("./stop.sh")
    runner.sleep(0.5)
    print("[setup] launching clean Facet.app...")
    runner.run("open", "Facet.app")
    # Wait for server + initial refresh + panel paint.
    runner.sleep(timing.long)


# -----------------------------------------------------------------
# Scenarios.
# -----------------------------------------------------------------

def run_tree_click(runner: Runner, coords: Coords, timing: Timing,
                   out: Path) -> None:
    print("[demo:tree-click] start")
    rec = runner.run(
        "screencapture", "-V", "12", "-t", "mp4", "-v", str(out),
        background=True,
    )
    runner.sleep(timing.medium)

    # Bring tree to front (idempotent).
    runner.run("facet", "--view=tree")
    runner.sleep(timing.medium)

    # First window row.
    y1 = coords.row_y_offset + coords.row_height
    runner.run("cliclick", f"c:{coords.panel_center_x},{y1}")
    runner.sleep(timing.long)

    # Different workspace (a few rows down).
    y2 = coords.row_y_offset + coords.row_height * 4
    runner.run("cliclick", f"c:{coords.panel_center_x},{y2}")
    runner.sleep(timing.long)

    if rec is not None:
        rec.wait()
    print(f"[demo:tree-click] wrote {out}")


def run_grid_drag(runner: Runner, coords: Coords, timing: Timing,
                  out: Path) -> None:
    print("[demo:grid-drag] start")
    rec = runner.run(
        "screencapture", "-V", "14", "-t", "mp4", "-v", str(out),
        background=True,
    )
    runner.sleep(timing.medium)

    # Open the grid overlay.
    runner.run("facet", "--view=grid")
    runner.sleep(timing.long)

    # Drag a window thumb from cell 1 → cell 2.
    # cliclick drag: d:X,Y m:X,Y u:X,Y  (down / move / up)
    runner.run(
        "cliclick",
        f"d:{coords.grid_cell_1_x},{coords.grid_cell_1_y}",
        f"m:{coords.grid_cell_2_x},{coords.grid_cell_2_y}",
        f"u:{coords.grid_cell_2_x},{coords.grid_cell_2_y}",
    )
    runner.sleep(timing.long)

    # Dismiss the grid with Esc.
    runner.run("cliclick", "kp:esc")
    runner.sleep(timing.short)

    if rec is not None:
        rec.wait()
    print(f"[demo:grid-drag] wrote {out}")


# -----------------------------------------------------------------
# Optional: mov → gif (skipped in dry-run / if ffmpeg absent).
# -----------------------------------------------------------------

def to_gif(runner: Runner) -> None:
    if runner.dry_run or shutil.which("ffmpeg") is None:
        return
    docs = REPO_ROOT / "docs"
    for mov in sorted(docs.glob("demo-*.mov")):
        gif = mov.with_suffix(".gif")
        print(f"[ffmpeg] {mov.name} → {gif.name}")
        subprocess.run(
            [
                "ffmpeg", "-y", "-i", str(mov),
                "-vf", "fps=15,scale=800:-1:flags=lanczos",
                "-loop", "0", str(gif),
            ],
            check=False,
        )


# -----------------------------------------------------------------
# Main.
# -----------------------------------------------------------------

SCENARIOS = ("tree-click", "grid-drag", "full")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "scenario", nargs="?", default="tree-click", choices=SCENARIOS,
        help="which scenario to record (default: tree-click)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print commands instead of executing (no recording, "
             "no mouse events, no process kills)",
    )
    parser.add_argument(
        "--silent", action="store_true",
        help=f"don't tee output to {LOG_PATH} (default: tee on)",
    )
    args = parser.parse_args()

    if not args.silent:
        install_log_tee()

    os.chdir(REPO_ROOT)
    check_prerequisites()

    runner = Runner(dry_run=args.dry_run)
    coords = Coords()
    timing = Timing()

    docs = REPO_ROOT / "docs"
    docs.mkdir(exist_ok=True)

    clean_facet_state(runner, timing)

    if args.scenario == "tree-click":
        run_tree_click(runner, coords, timing,
                       docs / "demo-tree-click.mov")
    elif args.scenario == "grid-drag":
        run_grid_drag(runner, coords, timing,
                      docs / "demo-grid-drag.mov")
    elif args.scenario == "full":
        run_tree_click(runner, coords, timing,
                       docs / "demo-tree-click.mov")
        runner.sleep(1)
        # Re-clean so grid-drag starts from a known state (grid
        # closed, panel possibly visible — same as a fresh launch).
        clean_facet_state(runner, timing)
        run_grid_drag(runner, coords, timing,
                      docs / "demo-grid-drag.mov")

    to_gif(runner)
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
