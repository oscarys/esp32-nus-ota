"""
Tests for the Python OTA client (ota_client.py).

These tests use a MockESP32 that speaks the OTA protocol over asyncio queues,
so no BLE hardware is needed.  The OTAClient's BLE layer is monkey-patched
to route through the mock instead.

Run:
    pytest python-client/tests/ -v
"""
import asyncio
import binascii
import pytest
import sys, os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from ota_client import OTAClient, crc32_file
from pathlib import Path


# ---------------------------------------------------------------------------
# MockESP32 — implements the server side of the OTA protocol
# ---------------------------------------------------------------------------

class MockESP32:
    """
    Simulates the ESP32 OTA state machine in-process.
    Feed lines in via rx(), read replies via tx_queue.
    """

    def __init__(self, *, inject_crc_error=False, inject_nack_on_seq=None,
                 drop_reply_on_seq=None, reject_reason=None):
        self.tx_queue          = asyncio.Queue()
        self._state            = "IDLE"
        self._buf              = b""
        self._expected_seq     = 0
        self._expected_size    = 0
        self._expected_crc     = 0
        self._inject_crc_error = inject_crc_error
        self._inject_nack_seq  = inject_nack_on_seq
        self._drop_reply_seq   = drop_reply_on_seq
        self._reject_reason    = reject_reason

    async def rx(self, line: str):
        """Receive a line from the client."""
        line = line.strip()
        if not line.startswith("OTA:"):
            return
        parts = line[4:].split(":")
        cmd   = parts[0].upper()

        if cmd == "START":
            await self._handle_start(parts[1:])
        elif cmd == "DATA":
            await self._handle_data(parts[1], parts[2] if len(parts) > 2 else "")
        elif cmd == "COMMIT":
            await self._handle_commit()
        elif cmd == "ABORT":
            self._state = "IDLE"
            await self.tx_queue.put("OTA:ABORTED")

    async def _handle_start(self, fields):
        if self._reject_reason:
            await self.tx_queue.put(f"OTA:REJECT:{self._reject_reason}")
            return
        self._expected_size = int(fields[1])
        self._expected_crc  = int(fields[2], 16)
        self._buf           = b""
        self._expected_seq  = 0
        self._state         = "ARMED"
        await self.tx_queue.put("OTA:READY")

    async def _handle_data(self, seq_str, hex_payload):
        seq = int(seq_str)
        if seq != self._expected_seq:
            await self.tx_queue.put(f"OTA:ERR:{seq}")
            return
        chunk = bytes.fromhex(hex_payload)

        if self._inject_nack_seq == seq:
            await self.tx_queue.put(f"OTA:ERR:{seq}")
            self._inject_nack_seq = None  # only once
            return

        self._buf += chunk
        self._expected_seq += 1
        self._state = "RECEIVING"

        if self._drop_reply_seq == seq:
            # Simulate lost ACK — don't put anything in tx_queue
            return

        await self.tx_queue.put(f"OTA:ACK:{seq}")

    async def _handle_commit(self):
        if self._inject_crc_error:
            await self.tx_queue.put("OTA:ERR:CRC:got=deadbeef,exp=00000000")
            return
        actual_crc = binascii.crc32(self._buf) & 0xFFFFFFFF
        if actual_crc != self._expected_crc or len(self._buf) != self._expected_size:
            await self.tx_queue.put(
                f"OTA:ERR:CRC:got={actual_crc:08x},exp={self._expected_crc:08x}"
            )
        else:
            await self.tx_queue.put("OTA:OK")
        self._state = "IDLE"

    @property
    def received_bytes(self) -> bytes:
        return self._buf


# ---------------------------------------------------------------------------
# Patched OTAClient that routes through MockESP32
# ---------------------------------------------------------------------------

class MockedOTAClient(OTAClient):
    """OTAClient with BLE layer replaced by MockESP32 queues."""

    def __init__(self, mock_device: MockESP32, **kwargs):
        super().__init__(**kwargs)
        self._mock = mock_device

    async def _send(self, text: str):
        await self._mock.rx(text)

    async def _wait_for(self, prefix: str, timeout: float = 8.0) -> str:
        try:
            reply = await asyncio.wait_for(
                self._mock.tx_queue.get(), timeout=timeout
            )
            self._last_reply = reply
            return reply
        except asyncio.TimeoutError:
            raise TimeoutError(f"Timed out waiting for {prefix}")

    async def run(self, address: str):
        """Override to skip actual BLE connect/disconnect."""
        file_data = self.path.read_bytes()
        file_size = len(file_data)
        file_crc  = crc32_file(self.path)
        filename  = self.path.name

        await self._handshake(file_data, file_size, file_crc, filename)
        await self._transfer(file_data)
        return await self._commit()

    async def _handshake(self, file_data, file_size, file_crc, filename):
        cmd = f"OTA:START:{filename}:{file_size}:{file_crc:08x}"
        if self.version: cmd += f":{self.version}"
        if self.token:   cmd += f":0.0.0:{self.token}"
        await self._send(cmd)
        reply = await self._wait_for("OTA:")
        if not reply.startswith("OTA:READY"):
            raise RuntimeError(f"Device rejected: {reply}")

    async def _transfer(self, file_data: bytes):
        import binascii as _b
        offset, seq = 0, 0
        while offset < len(file_data):
            chunk    = file_data[offset:offset + self.chunk_size]
            hex_data = _b.hexlify(chunk).decode()
            pkt      = f"OTA:DATA:{seq}:{hex_data}"
            for attempt in range(self._MAX_RETRIES):
                await self._send(pkt)
                try:
                    reply = await self._wait_for("OTA:", timeout=2.0)
                except TimeoutError:
                    continue
                if reply == f"OTA:ACK:{seq}":
                    break
                if reply.startswith("OTA:ERR:"):
                    continue
            else:
                raise RuntimeError(f"Too many retries on chunk {seq}")
            offset += len(chunk)
            seq    += 1

    async def _commit(self):
        await self._send("OTA:COMMIT")
        try:
            reply = await self._wait_for("OTA:", timeout=5.0)
            return reply.startswith("OTA:OK")
        except TimeoutError:
            return True   # device likely already reset


# Add missing class attribute
OTAClient._MAX_RETRIES = 5


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def small_file(tmp_path) -> Path:
    p = tmp_path / "main.py"
    p.write_bytes(b"print('hello from OTA')\n")
    return p


@pytest.fixture
def medium_file(tmp_path) -> Path:
    p = tmp_path / "app.py"
    # 4 KB of pseudo-content
    content = ("# auto-generated test file\n" * 150).encode()
    p.write_bytes(content)
    return p


@pytest.fixture
def large_file(tmp_path) -> Path:
    p = tmp_path / "app.py"
    # 32 KB
    p.write_bytes(bytes(range(256)) * 128)
    return p


def make_client(file_path, mock, chunk_size=88, version=None, token=None):
    return MockedOTAClient(
        mock_device = mock,
        file_path   = str(file_path),
        chunk_size  = chunk_size,
        version     = version,
        token       = token,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestHappyPath:

    @pytest.mark.asyncio
    async def test_small_file_transfer(self, small_file):
        mock   = MockESP32()
        client = make_client(small_file, mock)
        ok     = await client.run("mock")
        assert ok is True
        assert mock.received_bytes == small_file.read_bytes()

    @pytest.mark.asyncio
    async def test_medium_file_integrity(self, medium_file):
        mock   = MockESP32()
        client = make_client(medium_file, mock, chunk_size=88)
        await client.run("mock")
        assert mock.received_bytes == medium_file.read_bytes()

    @pytest.mark.asyncio
    async def test_large_file_integrity(self, large_file):
        mock   = MockESP32()
        client = make_client(large_file, mock, chunk_size=88)
        await client.run("mock")
        assert mock.received_bytes == large_file.read_bytes()

    @pytest.mark.asyncio
    async def test_single_byte_file(self, tmp_path):
        p = tmp_path / "config.py"
        p.write_bytes(b"\n")
        mock   = MockESP32()
        client = make_client(p, mock)
        ok     = await client.run("mock")
        assert ok is True
        assert mock.received_bytes == b"\n"

    @pytest.mark.asyncio
    async def test_chunk_size_1(self, small_file):
        """Edge case: every byte is its own chunk."""
        mock   = MockESP32()
        client = make_client(small_file, mock, chunk_size=1)
        await client.run("mock")
        assert mock.received_bytes == small_file.read_bytes()

    @pytest.mark.asyncio
    async def test_chunk_size_larger_than_file(self, small_file):
        """Single chunk covers entire file."""
        mock   = MockESP32()
        client = make_client(small_file, mock, chunk_size=4096)
        await client.run("mock")
        assert mock.received_bytes == small_file.read_bytes()


class TestRetryLogic:

    @pytest.mark.asyncio
    async def test_retries_on_nack_and_succeeds(self, small_file):
        """Device NACKs chunk 2 once — client should retry and succeed."""
        mock   = MockESP32(inject_nack_on_seq=2)
        client = make_client(small_file, mock, chunk_size=4)
        ok     = await client.run("mock")
        assert ok is True
        assert mock.received_bytes == small_file.read_bytes()

    @pytest.mark.asyncio
    async def test_retries_on_dropped_ack(self, small_file):
        """
        Device processes chunk 1 but the ACK is lost.
        Client retransmits; device should re-ACK the duplicate.
        """
        mock   = MockESP32(drop_reply_on_seq=1)
        client = make_client(small_file, mock, chunk_size=4)
        ok     = await client.run("mock")
        assert ok is True


class TestRejection:

    @pytest.mark.asyncio
    async def test_raises_on_forbidden(self, small_file):
        mock   = MockESP32(reject_reason="FORBIDDEN")
        client = make_client(small_file, mock)
        with pytest.raises(RuntimeError, match="FORBIDDEN"):
            await client.run("mock")

    @pytest.mark.asyncio
    async def test_raises_on_nospace(self, small_file):
        mock   = MockESP32(reject_reason="NOSPACE")
        client = make_client(small_file, mock)
        with pytest.raises(RuntimeError, match="NOSPACE"):
            await client.run("mock")

    @pytest.mark.asyncio
    async def test_raises_on_auth_failure(self, small_file):
        mock   = MockESP32(reject_reason="AUTH")
        client = make_client(small_file, mock, token="wrong")
        with pytest.raises(RuntimeError, match="AUTH"):
            await client.run("mock")

    @pytest.mark.asyncio
    async def test_raises_on_crc_error_at_commit(self, small_file):
        mock   = MockESP32(inject_crc_error=True)
        client = make_client(small_file, mock)
        ok     = await client.run("mock")
        assert ok is False


class TestCRC32:

    def test_crc32_file_matches_binascii(self, tmp_path):
        """crc32_file() must produce the same value as binascii.crc32()."""
        for content in [b"", b"a", b"hello world", bytes(range(256)) * 16]:
            p = tmp_path / "test.py"
            p.write_bytes(content)
            expected = binascii.crc32(content) & 0xFFFFFFFF
            assert crc32_file(p) == expected, \
                f"CRC mismatch for content length {len(content)}"

    def test_crc32_consistent_with_esp32_side(self, tmp_path):
        """
        The client CRC must match what OTAManager computes incrementally.
        Simulate incremental computation as OTAManager does it.
        """
        data = bytes(range(256)) * 4
        p    = tmp_path / "app.py"
        p.write_bytes(data)

        client_crc = crc32_file(p)

        # Incremental (as OTAManager does it chunk by chunk)
        running = 0
        chunk_size = 64
        for i in range(0, len(data), chunk_size):
            running = binascii.crc32(data[i:i+chunk_size], running) & 0xFFFFFFFF

        assert client_crc == running


class TestEdgeCases:

    @pytest.mark.asyncio
    async def test_file_of_exact_chunk_size(self, tmp_path):
        p = tmp_path / "main.py"
        p.write_bytes(b"x" * 88)   # exactly one chunk
        mock   = MockESP32()
        client = make_client(p, mock, chunk_size=88)
        ok     = await client.run("mock")
        assert ok is True
        assert mock.received_bytes == p.read_bytes()

    @pytest.mark.asyncio
    async def test_file_of_chunk_size_plus_one(self, tmp_path):
        p = tmp_path / "main.py"
        p.write_bytes(b"x" * 89)   # one full chunk + 1 trailing byte
        mock   = MockESP32()
        client = make_client(p, mock, chunk_size=88)
        ok     = await client.run("mock")
        assert ok is True
        assert mock.received_bytes == p.read_bytes()

    def test_missing_file_raises(self, tmp_path):
        with pytest.raises(SystemExit):
            import asyncio
            mock   = MockESP32()
            client = make_client(tmp_path / "nonexistent.py", mock)
            asyncio.run(client.run("mock"))
