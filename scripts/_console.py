"""Terminal output + subprocess helpers shared by the build/release scripts.

install.py deliberately does *not* import this — it is curl-piped straight into
a Python interpreter and has to stay a single self-contained file.
"""

from __future__ import annotations

import os
import subprocess
import sys
from typing import NoReturn, Sequence

_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ

RED = "\033[0;31m" if _COLOR else ""
GREEN = "\033[0;32m" if _COLOR else ""
YELLOW = "\033[1;33m" if _COLOR else ""
BLUE = "\033[0;34m" if _COLOR else ""
CYAN = "\033[0;36m" if _COLOR else ""
NC = "\033[0m" if _COLOR else ""

TOTAL_STEPS = 5


def step(n: int, message: str) -> None:
    print(f"\n{BLUE}[{n}/{TOTAL_STEPS}]{NC} {CYAN}{message}{NC}")


def success(message: str) -> None:
    print(f"  {GREEN}✓ {message}{NC}")


def warn(message: str) -> None:
    print(f"  {YELLOW}⚠ {message}{NC}")


def info(message: str) -> None:
    print(f"{CYAN}{message}{NC}")


def error(message: str) -> NoReturn:
    print(f"  {RED}✗ {message}{NC}")
    raise SystemExit(1)


def run(
    cmd: Sequence[str],
    *,
    cwd=None,
    quiet: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess:
    """Run a command. With quiet=True output is buffered and only replayed on
    failure — the bash scripts sent it to /dev/null unconditionally, which made
    a failing xcodebuild impossible to diagnose."""
    proc = subprocess.run(
        list(cmd),
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if quiet else None,
        stderr=subprocess.STDOUT if quiet else None,
    )
    if check and proc.returncode != 0:
        if quiet and proc.stdout:
            sys.stderr.write(proc.stdout[-4000:].rstrip() + "\n")
        error(f"{cmd[0]} failed (exit {proc.returncode})")
    return proc


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "K", "M", "G"):
        if size < 1024 or unit == "G":
            return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}G"
