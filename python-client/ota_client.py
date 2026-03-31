#!/usr/bin/env python3
"""
BLE OTA Client for ESP32 MicroPython / NUS-based OTA
Requires: pip install bleak
Usage:
    python ota_client.py --file main.py --device "ESP32-OTA"
    python ota_client.py --file main.py --address "AA:BB:CC:DD:EE:FF"
    python ota_client.py --scan          # list nearby NUS devices
"""

import asyncio
import argparse
import binascii
import os
import sys
import time
from pathlib import Path

from bleak import BleakClient, BleakScanner
from bleak.backends.characteristic import BleakGATTCharacteristic

# ---------------------------------------------------------------------------
# Nordic UART Service (NUS) UUIDs  — standard, must match your ESP32 firmware
# ---------------------------------------------------------------------------
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_TX_UUID      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # ESP32 → client (notify)
NUS_RX_UUID      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # client → ESP32 (write)

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
DEFAULT_CHUNK    = 176       # bytes of file data per DATA packet
ACK_TIMEOUT      = 8.0       # seconds to wait for ACK before giving up
MAX_RETRIES      = 5         # retries per chunk before aborting
SCAN_TIMEOUT     = 8.0       # seconds to scan for devices


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def crc32_file(path: Path) -> int:
    crc = 0
    with open(path, 'rb') as f:
        while chunk := f.read(4096):
            crc = binascii.crc32(chunk, crc) & 0xFFFFFFFF
    return crc


def progress_bar(done: int, total: int, width: int = 36) -> str:
    pct   = done / total if total else 0
    filled = int(width * pct)
    bar   = '#' * filled + '-' * (width - filled)
    return f"[{bar}] {pct*100:5.1f}%  {done}/{total} B"


# ---------------------------------------------------------------------------
# Scanner
# ---------------------------------------------------------------------------
async def scan():
    print("Scanning for BLE devices with NUS service …\n")
    devices = await BleakScanner.discover(timeout=SCAN_TIMEOUT,
                                          service_uuids=[NUS_SERVICE_UUID])
    if not devices:
        print("No NUS devices found.")
        return
    print(f"{'Address':<20}  {'Name'}")
    print("-" * 48)
    for d in devices:
        print(f"{d.address:<20}  {d.name or '(unnamed)'}")


# ---------------------------------------------------------------------------
# OTA Client
# ---------------------------------------------------------------------------
class OTAClient:
    def __init__(self, file_path: str, chunk_size: int = DEFAULT_CHUNK,
                 version: str = None, token: str = None, verbose: bool = False):
        self.path       = Path(file_path)
        self.chunk_size = chunk_size
        self.version    = version
        self.token      = token
        self.verbose    = verbose

        self._ack_event  = asyncio.Event()
        self._last_reply = ""
        self._client     = None

    # ------------------------------------------------------------------
    # BLE notification handler — runs in bleak callback thread
    # ------------------------------------------------------------------
    def _on_notify(self, _char: BleakGATTCharacteristic, data: bytearray):
        line = data.decode('utf-8', errors='ignore').strip()
        if self.verbose:
            print(f"  << {line}")
        self._last_reply = line
        self._ack_event.set()

    # ------------------------------------------------------------------
    # Send a line over NUS RX (client → ESP32)
    # ------------------------------------------------------------------
    async def _send(self, text: str):
        if self.verbose:
            print(f"  >> {text}")
        payload = (text + '\n').encode()
        await self._client.write_gatt_char(NUS_RX_UUID, payload, response=False)

    # ------------------------------------------------------------------
    # Wait for a reply that starts with expected prefix
    # ------------------------------------------------------------------
    async def _wait_for(self, prefix: str, timeout: float = ACK_TIMEOUT) -> str:
        deadline = time.monotonic() + timeout
        while True:
            self._ack_event.clear()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Timed out waiting for {prefix}")
            try:
                await asyncio.wait_for(self._ack_event.wait(), timeout=remaining)
            except asyncio.TimeoutError:
                raise TimeoutError(f"Timed out waiting for {prefix}")
            if self._last_reply.startswith(prefix):
                return self._last_reply

    # ------------------------------------------------------------------
    # Main transfer
    # ------------------------------------------------------------------
    async def run(self, address: str):
        if not self.path.exists():
            print(f"Error: file not found: {self.path}")
            sys.exit(1)

        file_data = self.path.read_bytes()
        file_size = len(file_data)
        file_crc  = crc32_file(self.path)
        filename  = self.path.name

        print(f"\nFile    : {self.path}")
        print(f"Size    : {file_size} bytes")
        print(f"CRC32   : {file_crc:08x}")
        print(f"Chunks  : {-(-file_size // self.chunk_size)}")  # ceiling div
        print(f"Target  : {address}\n")

        async with BleakClient(address, timeout=15.0) as client:
            self._client = client
            print(f"Connected to {client.address}")

            # Subscribe to NUS TX notifications
            await client.start_notify(NUS_TX_UUID, self._on_notify)

            # ---- HANDSHAKE ----
            start_cmd = f"OTA:START:{filename}:{file_size}:{file_crc:08x}"
            if self.version:
                start_cmd += f":{self.version}"
            elif self.token:
                start_cmd += f":0.0.0"   # placeholder version when only token given
            if self.token:
                start_cmd += f":{self.token}"

            print("Sending OTA:START …")
            await self._send(start_cmd)

            try:
                reply = await self._wait_for("OTA:", timeout=10.0)
            except TimeoutError:
                print("Error: no response to OTA:START — is OTA enabled on device?")
                return False

            if not reply.startswith("OTA:READY"):
                print(f"Error: device rejected start: {reply}")
                return False

            print("Device ready. Starting transfer …\n")

            # ---- DATA TRANSFER ----
            total_chunks = -(-file_size // self.chunk_size)
            seq          = 0
            offset       = 0
            t_start      = time.monotonic()

            while offset < file_size:
                chunk    = file_data[offset : offset + self.chunk_size]
                hex_data = binascii.hexlify(chunk).decode()
                pkt      = f"OTA:DATA:{seq}:{hex_data}"

                retries = 0
                while retries < MAX_RETRIES:
                    await self._send(pkt)
                    try:
                        reply = await self._wait_for(f"OTA:", timeout=ACK_TIMEOUT)
                    except TimeoutError:
                        retries += 1
                        print(f"\n  Timeout on seq {seq}, retry {retries}/{MAX_RETRIES}")
                        continue

                    if reply == f"OTA:ACK:{seq}":
                        break                          # success
                    elif reply.startswith("OTA:ERR:"):
                        retries += 1
                        print(f"\n  Device NACK on seq {seq}: {reply}, retry {retries}/{MAX_RETRIES}")
                    else:
                        # Unexpected reply — could be app traffic, keep waiting
                        retries += 1

                else:
                    print(f"\nFatal: too many retries on chunk {seq}. Sending ABORT.")
                    await self._send("OTA:ABORT")
                    return False

                offset += len(chunk)
                seq    += 1

                # Progress
                elapsed = time.monotonic() - t_start
                rate    = offset / elapsed if elapsed > 0 else 0
                eta     = (file_size - offset) / rate if rate > 0 else 0
                bar     = progress_bar(offset, file_size)
                print(f"\r{bar}  {rate/1024:.1f} kB/s  ETA {eta:.0f}s  ", end='', flush=True)

            print(f"\n\nAll {total_chunks} chunks sent. Sending OTA:COMMIT …")

            # ---- COMMIT ----
            await self._send("OTA:COMMIT")
            try:
                reply = await self._wait_for("OTA:", timeout=15.0)
            except TimeoutError:
                print("Timeout waiting for commit reply — device may have already reset.")
                return True   # optimistic — often the reset fires before we get OTA:OK

            if reply.startswith("OTA:OK"):
                elapsed = time.monotonic() - t_start
                print(f"Success! Transfer complete in {elapsed:.1f}s")
                print("Device is resetting …")
                return True
            else:
                print(f"Commit failed: {reply}")
                return False


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
async def main():
    parser = argparse.ArgumentParser(description="BLE OTA client for ESP32 NUS")
    group  = parser.add_mutually_exclusive_group()
    group.add_argument("--device",  metavar="NAME",    help="BLE device name to connect to")
    group.add_argument("--address", metavar="ADDRESS", help="BLE MAC/UUID address to connect to")
    group.add_argument("--scan",    action="store_true", help="Scan and list NUS devices")

    parser.add_argument("--file",    metavar="PATH",   help="File to transfer")
    parser.add_argument("--chunk",   metavar="BYTES",  type=int, default=DEFAULT_CHUNK,
                        help=f"Chunk size in bytes (default {DEFAULT_CHUNK})")
    parser.add_argument("--version", metavar="X.Y.Z",  help="Version string sent in OTA:START")
    parser.add_argument("--token",   metavar="SECRET", help="Auth token sent in OTA:START")
    parser.add_argument("--verbose", action="store_true", help="Print all BLE packets")
    args = parser.parse_args()

    if args.scan:
        await scan()
        return

    if not args.file:
        parser.error("--file is required unless --scan is specified")

    address = args.address

    if args.device and not address:
        print(f"Scanning for '{args.device}' …")
        device = await BleakScanner.find_device_by_name(args.device, timeout=SCAN_TIMEOUT)
        if not device:
            print(f"Error: device '{args.device}' not found.")
            sys.exit(1)
        address = device.address
        print(f"Found at {address}")

    if not address:
        parser.error("Specify --device NAME or --address ADDRESS")

    client = OTAClient(
        file_path  = args.file,
        chunk_size = args.chunk,
        version    = args.version,
        token      = args.token,
        verbose    = args.verbose,
    )
    ok = await client.run(address)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    asyncio.run(main())
