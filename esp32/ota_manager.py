# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025 esp32-nus-ota contributors
# https://github.com/oscarys/esp32-nus-ota

import os
import binascii
import time


class OTAManager:
    """
    NUS-based OTA update manager for ESP32 MicroPython.

    Receives OTA:* commands over the Nordic UART Service and manages
    the full transfer lifecycle: handshake → chunked transfer → commit.

    Parameters
    ----------
    reply_fn : callable(str)
        Sends a reply line back to the client over NUS TX.
        Called with a plain string (no trailing newline needed here —
        add one in your NUS send wrapper if required).
    wdt : machine.WDT or None
        Active hardware watchdog instance.  Pass None to disable WDT
        integration.  When provided, the watchdog is fed at every key
        point in the transfer so a long BLE gap or flash erase cannot
        trigger an unintended reset.
    """

    # ------------------------------------------------------------------ #
    # States                                                               #
    # ------------------------------------------------------------------ #
    IDLE       = 0
    ARMED      = 1
    RECEIVING  = 2
    COMMITTING = 3

    # ------------------------------------------------------------------ #
    # Configuration — edit before deploying                               #
    # ------------------------------------------------------------------ #

    # Files that may be updated over the air.
    # IMPORTANT: keep this hardcoded — never derive it from a file that
    # OTA could itself overwrite.
    ALLOWED_FILES = {'main.py', 'app.py', 'config.py', 'sensor.py'}

    # Pre-shared auth token.  Set to None to disable authentication.
    # The token travels in plaintext over BLE — it prevents accidental
    # updates from unknown clients, not a determined attacker.
    AUTH_TOKEN = None

    # Milliseconds to wait after sending OTA:OK before calling
    # machine.reset(), giving the BLE stack time to flush the reply.
    RESET_DELAY_MS = 500

    # ------------------------------------------------------------------ #
    # Public interface                                                     #
    # ------------------------------------------------------------------ #

    def __init__(self, reply_fn, wdt=None):
        self._reply = reply_fn
        self._wdt   = wdt
        self._state = self.IDLE
        self._reset()

    def handle(self, line):
        """
        Route an OTA:* line to the correct handler.
        Call this from your NUS on_rx callback for every line that
        starts with 'OTA:'.
        """
        self._feed()                        # keep WDT alive on every packet

        line  = line.strip()
        if not line.startswith("OTA:"):
            return

        parts = line[4:].split(":")
        cmd   = parts[0].upper()

        if   cmd == "START":  self._on_start(parts[1:])
        elif cmd == "DATA":   self._on_data(parts[1],
                                            parts[2] if len(parts) > 2 else "")
        elif cmd == "COMMIT": self._on_commit()
        elif cmd == "ABORT":  self._on_abort()
        else:
            self._reply("OTA:ERR:UNKNOWN_CMD")

    # ------------------------------------------------------------------ #
    # Handlers                                                             #
    # ------------------------------------------------------------------ #

    def _on_start(self, fields):
        if self._state != self.IDLE:
            self._reply("OTA:REJECT:BUSY")
            return

        if len(fields) < 3:
            self._reply("OTA:REJECT:BAD_ARGS")
            return

        filename   = fields[0]
        size       = int(fields[1])
        crc32_exp  = int(fields[2], 16)
        version    = fields[3] if len(fields) > 3 else None
        chunk_size = int(fields[4]) if len(fields) > 4 else 180
        token      = fields[5] if len(fields) > 5 else None

        # --- Auth ---
        if self.AUTH_TOKEN and token != self.AUTH_TOKEN:
            self._reply("OTA:REJECT:AUTH")
            return

        # --- Allowlist ---
        if filename not in self.ALLOWED_FILES:
            self._reply("OTA:REJECT:FORBIDDEN")
            return

        # --- Free space (keep 20 % headroom) ---
        st   = os.statvfs('/')
        free = st[0] * st[3]
        if size > free * 0.8:
            self._reply("OTA:REJECT:NOSPACE")
            return

        # --- Version guard ---
        if version and self._is_downgrade(version):
            self._reply("OTA:REJECT:VERSION")
            return

        # --- Arm ---
        self._filename   = filename
        self._size       = size
        self._crc32_exp  = crc32_exp
        self._chunk_size = chunk_size
        self._seq_expect = 0
        self._received   = 0
        self._crc32_run  = 0
        self._tmp        = '_ota_tmp'
        self._fh         = open(self._tmp, 'wb')
        self._state      = self.ARMED

        self._reply("OTA:READY")

    def _on_data(self, seq_str, payload):
        if self._state not in (self.ARMED, self.RECEIVING):
            self._reply("OTA:ERR:NOT_READY")
            return

        try:
            seq = int(seq_str)
        except ValueError:
            self._reply("OTA:ERR:BAD_SEQ")
            return

        # Duplicate — re-ACK without writing (client missed our previous ACK)
        if seq == self._seq_expect - 1:
            self._reply("OTA:ACK:{}".format(seq))
            return

        # Out-of-order
        if seq != self._seq_expect:
            self._reply("OTA:ERR:{}".format(seq))
            return

        # Decode hex payload
        try:
            chunk = binascii.unhexlify(payload)
        except Exception:
            chunk = payload.encode() if isinstance(payload, str) else payload

        # Write chunk — may block up to ~50 ms on a sector erase
        try:
            self._fh.write(chunk)
        except OSError as e:
            self._abort_internal()
            self._reply("OTA:ERR:WRITE:{}".format(e))
            return

        # Feed WDT immediately after the flash write — the write is the
        # longest blocking operation in the hot path
        self._feed()

        # Accumulate running CRC32
        self._crc32_run = binascii.crc32(chunk, self._crc32_run) & 0xFFFFFFFF
        self._received += len(chunk)
        self._seq_expect += 1
        self._state = self.RECEIVING

        self._reply("OTA:ACK:{}".format(seq))

    def _on_commit(self):
        if self._state != self.RECEIVING:
            self._reply("OTA:ERR:NOT_RECEIVING")
            return

        self._state = self.COMMITTING

        # Feed WDT before the commit sequence — flush + two renames
        # can each trigger a flash erase.
        self._feed()

        # Close temp file
        try:
            self._fh.flush()
            self._fh.close()
        except OSError:
            pass
        self._fh = None

        # Size check
        if self._received != self._size:
            self._reply("OTA:ERR:SIZE:got={},exp={}".format(
                self._received, self._size))
            self._cleanup_tmp()
            self._state = self.IDLE
            return

        # CRC check
        if self._crc32_run != self._crc32_exp:
            self._reply("OTA:ERR:CRC:got={:08x},exp={:08x}".format(
                self._crc32_run, self._crc32_exp))
            self._cleanup_tmp()
            self._state = self.IDLE
            return

        # Backup existing target file
        target = self._filename
        backup = target + '.bak'
        try:
            os.rename(target, backup)
        except OSError:
            pass  # no existing file — fine

        # Atomic rename of temp file to target
        try:
            os.rename(self._tmp, target)
        except OSError as e:
            try:
                os.rename(backup, target)   # restore backup on failure
            except OSError:
                pass
            self._reply("OTA:ERR:RENAME:{}".format(e))
            self._state = self.IDLE
            return

        # Rename succeeded — remove the backup to keep the filesystem clean.
        # We keep it until here so it's available for emergency recovery
        # right up until the new file is confirmed in place.
        try:
            os.remove(backup)
        except OSError:
            pass  # no backup existed — fine

        # Send success reply, then reset
        self._reply("OTA:OK")
        self._reset()

        # Give the BLE stack time to flush OTA:OK before we reset,
        # then feed the WDT one last time to avoid a race between the
        # sleep and the watchdog timeout.
        import machine
        time.sleep_ms(self.RESET_DELAY_MS)
        self._feed()
        machine.reset()

    def abort(self):
        """
        Public abort — call from outside the OTA protocol, e.g. from a
        BLE disconnect handler, to reset the state machine to IDLE.
        Cleans up any open temp file without sending a reply.
        """
        self._abort_internal()

    def _on_abort(self):
        self._abort_internal()
        self._reply("OTA:ABORTED")

    # ------------------------------------------------------------------ #
    # Helpers                                                              #
    # ------------------------------------------------------------------ #

    def _feed(self):
        """Feed the hardware watchdog if one was provided."""
        if self._wdt is not None:
            self._wdt.feed()

    def _abort_internal(self):
        if self._fh:
            try:
                self._fh.close()
            except OSError:
                pass
            self._fh = None
        self._cleanup_tmp()
        self._reset()

    def _cleanup_tmp(self):
        try:
            os.remove(self._tmp)
        except OSError:
            pass

    def _reset(self):
        self._state      = self.IDLE
        self._filename   = None
        self._size       = 0
        self._crc32_exp  = 0
        self._crc32_run  = 0
        self._chunk_size = 180
        self._seq_expect = 0
        self._received   = 0
        self._fh         = None
        self._tmp        = '_ota_tmp'

    def _is_downgrade(self, incoming_version):
        """
        Return True if incoming_version is older than the version stored
        in config.VERSION.  Override in a subclass if your version format
        differs from semantic versioning (MAJOR.MINOR.PATCH).
        """
        try:
            from config import VERSION as current
            def to_tuple(v):
                return tuple(int(x) for x in v.split('.'))
            return to_tuple(incoming_version) < to_tuple(current)
        except Exception:
            return False    # no version info available — allow update
