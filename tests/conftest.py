"""Make `vivado_mcp_server` importable without requiring `pip install -e .`.

The package lives under `python/`, mirroring the pyproject `package-dir`
layout. Tests can then `from vivado_mcp_server...` normally.
"""

from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
_PKG_DIR = _ROOT / "python"
if str(_PKG_DIR) not in sys.path:
    sys.path.insert(0, str(_PKG_DIR))
