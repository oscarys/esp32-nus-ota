# Wiring OTAManager into your NUS application

## Minimal integration (no watchdog)

```python
from ota_manager import OTAManager

class NUSService:
    def __init__(self):
        self.ota = OTAManager(reply_fn=self._nus_send)

    def _on_rx(self, data):
        line = data.decode('utf-8', 'ignore').strip()
        if line.startswith("OTA:"):
            self.ota.handle(line)
        else:
            self._app_handle(line)

    def _nus_send(self, text):
        self._ble_notify((text + '\n').encode())
```

## Integration with a hardware watchdog

If your application runs a `machine.WDT`, pass the instance to
`OTAManager` so it feeds the watchdog at every critical point during the
transfer — after each chunk write, at the start of the commit sequence,
and immediately before `machine.reset()`.

```python
from machine import WDT
from ota_manager import OTAManager

class NUSService:
    def __init__(self):
        self._wdt = WDT(timeout=3000)        # your existing watchdog
        self.ota  = OTAManager(
            reply_fn = self._nus_send,
            wdt      = self._wdt,            # ← pass it in
        )

    def _on_rx(self, data):
        line = data.decode('utf-8', 'ignore').strip()
        if line.startswith("OTA:"):
            self.ota.handle(line)
        else:
            self._app_handle(line)

    def _on_disconnect(self):
        # Reset OTA state on BLE disconnect so a reconnecting client
        # does not receive OTA:REJECT:BUSY
        self.ota.abort()

    def _nus_send(self, text):
        self._ble_notify((text + '\n').encode())
```

### Where OTAManager feeds the watchdog

| Point | Why |
|---|---|
| `handle()` entry | Keeps WDT alive during inter-packet gaps |
| After `_fh.write()` in `_on_data` | Flash sector erase can block ~50 ms |
| Start of `_on_commit()` | Flush + two renames each touch flash |
| After `sleep_ms(RESET_DELAY_MS)` | Prevents WDT race before reset |

### Watchdog timeout guidance

| Timeout | Notes |
|---|---|
| < 1 s | Risky — temporarily widen during OTA (see below) |
| 1–3 s | Fine with WDT feeds in `OTAManager` |
| > 3 s | Comfortable margin for any realistic transfer |

Your main loop must also feed the watchdog between BLE callbacks.
A `time.sleep_ms(500)` loop is sufficient for a 3-second timeout:

```python
def run(self):
    while True:
        self._wdt.feed()
        time.sleep_ms(500)
```

### Temporarily widening the timeout for very tight watchdogs

`machine.WDT` cannot have its timeout changed after initialisation, but
you can create a new instance with a wider timeout for the duration of
the OTA transfer.  Subclass `OTAManager` and override `_on_start` and
`_on_commit`:

```python
from machine import WDT
from ota_manager import OTAManager

class WatchdogAwareOTA(OTAManager):

    def __init__(self, reply_fn, wdt, ota_timeout_ms=8000):
        super().__init__(reply_fn, wdt)
        self._normal_wdt     = wdt
        self._ota_timeout_ms = ota_timeout_ms

    def _on_start(self, fields):
        # Widen timeout for the transfer window
        self._wdt = WDT(timeout=self._ota_timeout_ms)
        super()._on_start(fields)

    def _on_commit(self):
        super()._on_commit()
        # (machine.reset() is called inside _on_commit, so we never
        # reach here on success — no need to restore the timeout.)

    def _on_abort(self):
        # Restore normal timeout on abort
        self._wdt = WDT(timeout=2000)
        super()._on_abort()
```

---

## Allowlist

```python
OTAManager.ALLOWED_FILES = {'main.py', 'app.py', 'config.py'}
```

Keep this hardcoded. Never derive it from a file that OTA could overwrite.

---

## Auth token

```python
OTAManager.AUTH_TOKEN = "your-pre-shared-secret"
```

Set to `None` (default) to disable. The token is sent in plaintext over
BLE — it prevents accidental updates from unknown clients, not a
determined attacker with a sniffer.

---

## Version guard

`OTAManager` calls `_is_downgrade(incoming_version)` before arming.
The default implementation reads `VERSION` from `config.py` and compares
as a semantic version tuple.  Override in a subclass if your format differs:

```python
class MyOTA(OTAManager):
    def _is_downgrade(self, incoming):
        from config import BUILD_NUMBER
        return int(incoming) < BUILD_NUMBER
```

---

## Recovery from a bad update

If the new file crashes on boot and the BLE is unreachable, connect via
UART and run:

```python
import os
os.rename('main.py.bak', 'main.py')
import machine; machine.reset()
```

Install the boot watchdog in `boot.py` (see `RECOVERY.md`) to make this
automatic.
