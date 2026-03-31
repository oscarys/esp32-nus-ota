"""
Stubs for MicroPython-only modules so OTAManager runs under desktop CPython/pytest.
Import order matters: stubs must be in sys.modules before ota_manager is imported.
"""
import sys
import os
import binascii
from unittest.mock import MagicMock, patch
import pytest

# --- machine stub -----------------------------------------------------------
machine_stub = MagicMock()
_reset_calls = []

def _fake_reset():
    _reset_calls.append(1)

machine_stub.reset = _fake_reset
sys.modules['machine'] = machine_stub

# --- os.statvfs stub (not available on all desktop platforms) ---------------
# Returns (block_size, frag_size, blocks, free_blocks, ...)
# Default: 4096-byte blocks, 10 000 free = ~40 MB free
_statvfs_result = (4096, 4096, 20000, 10000, 0, 0, 0, 0, 0, 255)

_real_statvfs = getattr(os, 'statvfs', None)

def patched_statvfs(path):
    return _statvfs_result

if not hasattr(os, 'statvfs'):
    os.statvfs = patched_statvfs


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def reset_machine_calls():
    """Clear the reset counter before each test."""
    _reset_calls.clear()
    yield
    # tests can inspect _reset_calls after yield if needed


@pytest.fixture()
def tmp_working_dir(tmp_path, monkeypatch):
    """
    Change cwd to a temp directory for the duration of a test.
    OTAManager writes _ota_tmp and target files relative to cwd.
    """
    monkeypatch.chdir(tmp_path)
    yield tmp_path


@pytest.fixture()
def free_space_ample():
    """Ensure statvfs reports plenty of free space."""
    orig = os.statvfs
    os.statvfs = lambda p: (4096, 4096, 20000, 10000, 0, 0, 0, 0, 0, 255)
    yield
    os.statvfs = orig


@pytest.fixture()
def free_space_tight():
    """Simulate a nearly-full filesystem (only 1 block free)."""
    orig = os.statvfs
    os.statvfs = lambda p: (4096, 4096, 20000, 1, 0, 0, 0, 0, 0, 255)
    yield
    os.statvfs = orig
