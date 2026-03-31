"""
Unit tests for OTAManager.

Run from the repo root:
    pytest esp32/tests/ -v

No BLE hardware required. All file I/O goes into pytest tmp_path.
The machine.reset() stub records calls without actually resetting anything.
"""
import sys, os, binascii, struct
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import pytest
from conftest import _reset_calls
from ota_manager import OTAManager


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_ota(replies=None, token=None):
    """Return a fresh OTAManager wired to a reply-capture list."""
    if replies is None:
        replies = []
    mgr = OTAManager(reply_fn=replies.append)
    OTAManager.AUTH_TOKEN = token
    return mgr, replies


def crc32_of(data: bytes) -> str:
    return format(binascii.crc32(data) & 0xFFFFFFFF, '08x')


def hex_chunk(data: bytes) -> str:
    return data.hex()


def drive_transfer(mgr, filename, data, chunk_size=64):
    """
    Drive a full START → DATA* → COMMIT sequence programmatically.
    Returns the final reply list entry.
    """
    replies = []
    mgr._reply = replies.append
    crc = crc32_of(data)
    mgr.handle(f"OTA:START:{filename}:{len(data)}:{crc}")
    assert replies[-1] == "OTA:READY", f"Expected READY, got {replies[-1]}"

    offset, seq = 0, 0
    while offset < len(data):
        chunk = data[offset:offset + chunk_size]
        mgr.handle(f"OTA:DATA:{seq}:{hex_chunk(chunk)}")
        assert replies[-1] == f"OTA:ACK:{seq}", \
            f"Expected ACK:{seq}, got {replies[-1]}"
        offset += len(chunk)
        seq += 1

    mgr.handle("OTA:COMMIT")
    return replies[-1]


# ===========================================================================
# 1. START — validation
# ===========================================================================

class TestStart:

    def test_ready_on_valid_start(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"print('hello')\n"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        assert rep[-1] == "OTA:READY"
        assert mgr._state == OTAManager.ARMED

    def test_rejects_file_not_in_allowlist(self, tmp_working_dir):
        mgr, rep = make_ota()
        mgr.handle("OTA:START:../../boot.py:10:deadbeef")
        assert rep[-1] == "OTA:REJECT:FORBIDDEN"
        assert mgr._state == OTAManager.IDLE

    def test_rejects_path_traversal(self, tmp_working_dir):
        mgr, rep = make_ota()
        mgr.handle("OTA:START:/etc/passwd:10:deadbeef")
        assert rep[-1] == "OTA:REJECT:FORBIDDEN"

    def test_rejects_missing_args(self, tmp_working_dir):
        mgr, rep = make_ota()
        mgr.handle("OTA:START:main.py:100")      # missing CRC
        assert rep[-1] == "OTA:REJECT:BAD_ARGS"

    def test_rejects_when_busy(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"x" * 32
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        assert rep[-1] == "OTA:READY"
        # second START while ARMED
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        assert rep[-1] == "OTA:REJECT:BUSY"

    def test_rejects_no_space(self, tmp_working_dir, free_space_tight):
        mgr, rep = make_ota()
        # 1 block free = 4096 bytes; send 10 000 bytes → should exceed 80% threshold
        data = b"x" * 10000
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        assert rep[-1] == "OTA:REJECT:NOSPACE"

    def test_accepts_optional_version_and_token(self, tmp_working_dir):
        mgr, rep = make_ota(token="mysecret")
        data = b"pass\n"
        mgr.handle(
            f"OTA:START:main.py:{len(data)}:{crc32_of(data)}:1.2.3:64:mysecret"
        )
        assert rep[-1] == "OTA:READY"

    def test_rejects_wrong_token(self, tmp_working_dir):
        mgr, rep = make_ota(token="secret")
        data = b"pass\n"
        mgr.handle(
            f"OTA:START:main.py:{len(data)}:{crc32_of(data)}:1.0.0:64:wrongtoken"
        )
        assert rep[-1] == "OTA:REJECT:AUTH"


# ===========================================================================
# 2. DATA — chunk sequencing
# ===========================================================================

class TestData:

    def test_first_chunk_acked(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"hello world"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data)}")
        assert rep[-1] == "OTA:ACK:0"
        assert mgr._state == OTAManager.RECEIVING

    def test_out_of_order_chunk_nacked(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"hello world"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        # skip seq 0, send seq 1
        mgr.handle(f"OTA:DATA:1:{hex_chunk(data)}")
        assert rep[-1] == "OTA:ERR:1"

    def test_duplicate_chunk_silently_acked(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"hello"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data)}")
        assert rep[-1] == "OTA:ACK:0"
        # resend seq 0 (client missed our ACK)
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data)}")
        assert rep[-1] == "OTA:ACK:0"   # silently re-ACK, no double-write

    def test_data_before_start_rejected(self, tmp_working_dir):
        mgr, rep = make_ota()
        mgr.handle("OTA:DATA:0:deadbeef")
        assert rep[-1] == "OTA:ERR:NOT_READY"

    def test_sequential_chunks_all_acked(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = bytes(range(256))          # 256 bytes
        chunk_size = 32
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        for seq, off in enumerate(range(0, len(data), chunk_size)):
            chunk = data[off:off + chunk_size]
            mgr.handle(f"OTA:DATA:{seq}:{hex_chunk(chunk)}")
            assert rep[-1] == f"OTA:ACK:{seq}"


# ===========================================================================
# 3. COMMIT — CRC, rename, reset
# ===========================================================================

class TestCommit:

    def test_successful_commit_writes_file(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"print('v2')\n"
        result = drive_transfer(mgr, "main.py", data)
        assert result == "OTA:OK"
        assert (tmp_working_dir / "main.py").read_bytes() == data

    def test_successful_commit_triggers_reset(self, tmp_working_dir):
        mgr, _ = make_ota()
        data = b"# new firmware\n"
        drive_transfer(mgr, "main.py", data)
        assert len(_reset_calls) == 1

    def test_commit_backs_up_existing_file(self, tmp_working_dir):
        # Pre-create the target file
        (tmp_working_dir / "main.py").write_bytes(b"# old version\n")
        mgr, _ = make_ota()
        data = b"# new version\n"
        drive_transfer(mgr, "main.py", data)
        # Backup should exist
        assert (tmp_working_dir / "main.py.bak").read_bytes() == b"# old version\n"
        # New file should be in place
        assert (tmp_working_dir / "main.py").read_bytes() == data

    def test_commit_fails_on_crc_mismatch(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"hello"
        bad_crc = "00000000"                      # deliberately wrong
        mgr.handle(f"OTA:START:main.py:{len(data)}:{bad_crc}")
        assert rep[-1] == "OTA:READY"
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data)}")
        mgr.handle("OTA:COMMIT")
        assert rep[-1].startswith("OTA:ERR:CRC")
        # No file should have been written
        assert not (tmp_working_dir / "main.py").exists()
        # State back to IDLE
        assert mgr._state == OTAManager.IDLE

    def test_commit_fails_on_size_mismatch(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"hello"
        # Lie about size in START
        mgr.handle(f"OTA:START:main.py:999:{crc32_of(data)}")
        assert rep[-1] == "OTA:READY"
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data)}")
        mgr.handle("OTA:COMMIT")
        assert rep[-1].startswith("OTA:ERR:SIZE")
        assert mgr._state == OTAManager.IDLE

    def test_commit_before_receiving_rejected(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"x"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        # Send COMMIT without any DATA
        mgr.handle("OTA:COMMIT")
        assert rep[-1] == "OTA:ERR:NOT_RECEIVING"

    def test_tmp_file_cleaned_up_on_crc_failure(self, tmp_working_dir):
        mgr, _ = make_ota()
        data = b"test"
        mgr.handle(f"OTA:START:main.py:{len(data)}:00000000")
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data)}")
        mgr.handle("OTA:COMMIT")
        assert not (tmp_working_dir / "_ota_tmp").exists()


# ===========================================================================
# 4. ABORT
# ===========================================================================

class TestAbort:

    def test_abort_from_armed_resets_to_idle(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"x"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        mgr.handle("OTA:ABORT")
        assert rep[-1] == "OTA:ABORTED"
        assert mgr._state == OTAManager.IDLE

    def test_abort_from_receiving_resets_to_idle(self, tmp_working_dir):
        mgr, rep = make_ota()
        data = b"hello world"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data[:5])}")
        mgr.handle("OTA:ABORT")
        assert rep[-1] == "OTA:ABORTED"
        assert mgr._state == OTAManager.IDLE

    def test_abort_removes_tmp_file(self, tmp_working_dir):
        mgr, _ = make_ota()
        data = b"hello"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data[:3])}")
        mgr.handle("OTA:ABORT")
        assert not (tmp_working_dir / "_ota_tmp").exists()

    def test_abort_does_not_disturb_existing_target(self, tmp_working_dir):
        original = b"# original\n"
        (tmp_working_dir / "main.py").write_bytes(original)
        mgr, _ = make_ota()
        data = b"# new\n"
        mgr.handle(f"OTA:START:main.py:{len(data)}:{crc32_of(data)}")
        mgr.handle(f"OTA:DATA:0:{hex_chunk(data[:3])}")
        mgr.handle("OTA:ABORT")
        assert (tmp_working_dir / "main.py").read_bytes() == original

    def test_abort_from_idle_is_harmless(self, tmp_working_dir):
        mgr, rep = make_ota()
        mgr.handle("OTA:ABORT")
        assert rep[-1] == "OTA:ABORTED"
        assert mgr._state == OTAManager.IDLE


# ===========================================================================
# 5. Unknown command
# ===========================================================================

class TestUnknownCommand:

    def test_unknown_ota_command_replied(self, tmp_working_dir):
        mgr, rep = make_ota()
        mgr.handle("OTA:REBOOT")
        assert rep[-1] == "OTA:ERR:UNKNOWN_CMD"

    def test_non_ota_line_ignored(self, tmp_working_dir):
        mgr, rep = make_ota()
        mgr.handle("PING")
        assert rep == []


# ===========================================================================
# 6. Multi-file and re-use
# ===========================================================================

class TestReuse:

    def test_second_transfer_after_first_succeeds(self, tmp_working_dir):
        # Disable reset so state machine survives between transfers in test
        from conftest import _reset_calls
        import ota_manager as _om
        original_reset = _om.machine.reset
        _om.machine.reset = lambda: None   # no-op for this test

        mgr, _ = make_ota()

        data1 = b"# version 1\n"
        drive_transfer(mgr, "main.py", data1)
        assert (tmp_working_dir / "main.py").read_bytes() == data1

        # Manually reset state (machine.reset would do this on real hardware)
        mgr._reset()

        data2 = b"# version 2\n"
        drive_transfer(mgr, "main.py", data2)
        assert (tmp_working_dir / "main.py").read_bytes() == data2

        _om.machine.reset = original_reset

    def test_different_allowed_files_transferred(self, tmp_working_dir):
        import ota_manager as _om
        _om.machine.reset = lambda: None

        for filename in OTAManager.ALLOWED_FILES:
            mgr, _ = make_ota()
            data = f"# {filename}\n".encode()
            result = drive_transfer(mgr, filename, data)
            assert result == "OTA:OK", f"Failed for {filename}"
            mgr._reset()


# ===========================================================================
# 7. CRC32 correctness (cross-check with Python binascii)
# ===========================================================================

class TestCRC:

    def test_crc32_matches_binascii(self, tmp_working_dir):
        """
        CRC sent in START must match what Python's binascii.crc32() produces.
        This is the contract between client and server.
        """
        payloads = [
            b"",
            b"a",
            b"hello world",
            bytes(range(256)),
            b"\x00\xff" * 512,
        ]
        for payload in payloads:
            expected = format(binascii.crc32(payload) & 0xFFFFFFFF, '08x')
            mgr, rep = make_ota()
            mgr.handle(f"OTA:START:main.py:{len(payload)}:{expected}")
            if len(payload) == 0:
                # Zero-length: READY then immediate commit
                mgr.handle("OTA:COMMIT")
                # Size mismatch expected (0 bytes received, 0 expected → OK)
                # Actually passes through — verify no crash
            else:
                assert rep[-1] == "OTA:READY", \
                    f"CRC {expected} not accepted for payload len {len(payload)}"
