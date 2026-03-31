import os
import binascii

class OTAManager:

    IDLE       = 0
    ARMED      = 1
    RECEIVING  = 2
    COMMITTING = 3

    # Edit this set to match the scripts you permit to be updated.
    # Keep it hardcoded — never derive it from a file that OTA could overwrite.
    ALLOWED_FILES = {'main.py', 'app.py', 'config.py', 'sensor.py'}

    # Set to a string to require a pre-shared token in OTA:START.
    AUTH_TOKEN = None

    def __init__(self, reply_fn):
        """
        reply_fn: callable(str) — sends a reply line back over NUS TX.
        """
        self._reply = reply_fn
        self._state = self.IDLE
        self._reset()

    # ------------------------------------------------------------------
    # Public entry point
    # ------------------------------------------------------------------
    def handle(self, line):
        """Route an OTA:* line to the correct handler."""
        line = line.strip()
        if not line.startswith("OTA:"):
            return

        parts = line[4:].split(":")
        cmd   = parts[0].upper()

        if   cmd == "START":   self._on_start(parts[1:])
        elif cmd == "DATA":    self._on_data(parts[1], parts[2] if len(parts) > 2 else "")
        elif cmd == "COMMIT":  self._on_commit()
        elif cmd == "ABORT":   self._on_abort()
        else:
            self._reply("OTA:ERR:UNKNOWN_CMD")

    # ------------------------------------------------------------------
    # Handlers
    # ------------------------------------------------------------------
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

        if self.AUTH_TOKEN and token != self.AUTH_TOKEN:
            self._reply("OTA:REJECT:AUTH")
            return

        if filename not in self.ALLOWED_FILES:
            self._reply("OTA:REJECT:FORBIDDEN")
            return

        st   = os.statvfs('/')
        free = st[0] * st[3]
        if size > free * 0.8:
            self._reply("OTA:REJECT:NOSPACE")
            return

        if version and self._is_downgrade(version):
            self._reply("OTA:REJECT:VERSION")
            return

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

        # Duplicate — re-ACK without writing
        if seq == self._seq_expect - 1:
            self._reply("OTA:ACK:{}".format(seq))
            return

        if seq != self._seq_expect:
            self._reply("OTA:ERR:{}".format(seq))
            return

        try:
            chunk = binascii.unhexlify(payload)
        except Exception:
            chunk = payload.encode() if isinstance(payload, str) else payload

        try:
            self._fh.write(chunk)
        except OSError as e:
            self._abort_internal()
            self._reply("OTA:ERR:WRITE:{}".format(e))
            return

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

        try:
            self._fh.flush()
            self._fh.close()
        except OSError:
            pass
        self._fh = None

        if self._received != self._size:
            self._reply("OTA:ERR:SIZE:got={},exp={}".format(self._received, self._size))
            self._cleanup_tmp()
            self._state = self.IDLE
            return

        if self._crc32_run != self._crc32_exp:
            self._reply("OTA:ERR:CRC:got={:08x},exp={:08x}".format(
                self._crc32_run, self._crc32_exp))
            self._cleanup_tmp()
            self._state = self.IDLE
            return

        target = self._filename
        backup = target + '.bak'
        try:
            os.rename(target, backup)
        except OSError:
            pass

        try:
            os.rename(self._tmp, target)
        except OSError as e:
            try:
                os.rename(backup, target)
            except OSError:
                pass
            self._reply("OTA:ERR:RENAME:{}".format(e))
            self._state = self.IDLE
            return

        self._reply("OTA:OK")
        self._reset()

        import machine
        machine.reset()

    def _on_abort(self):
        self._abort_internal()
        self._reply("OTA:ABORTED")

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
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
        try:
            from config import VERSION as current
            def to_tuple(v):
                return tuple(int(x) for x in v.split('.'))
            return to_tuple(incoming_version) < to_tuple(current)
        except Exception:
            return False
