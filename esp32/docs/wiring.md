# Wiring OTAManager into your NUS application

## Minimal integration (5 lines)

If your NUS service already has an `on_rx` callback, the integration is:

```python
from ota_manager import OTAManager

class NUSService:
    def __init__(self):
        # your existing BLE setup ...
        self.ota = OTAManager(reply_fn=self._nus_send)

    def _on_rx(self, data):
        line = data.decode('utf-8', 'ignore').strip()
        if line.startswith("OTA:"):
            self.ota.handle(line)       # OTA traffic
        else:
            self._app_handle(line)      # your existing app protocol

    def _nus_send(self, text):
        """Send a line back to the client over NUS TX."""
        self._ble_notify((text + '\n').encode())
```

`OTAManager` is stateless between transfers and thread-safe for the
single-threaded MicroPython scheduler.

---

## Configuring the allowlist

Edit the class variable before instantiation, or override it in a subclass:

```python
OTAManager.ALLOWED_FILES = {
    'main.py',
    'app.py',
    'config.py',
    'lib/sensor.py',
}
```

The allowlist is checked against the literal filename field from `OTA:START`.
Path separators and traversal sequences (`../`, `/`) in the filename cause an
immediate `OTA:REJECT:FORBIDDEN` before any file I/O.

**Keep the allowlist hardcoded.** Do not read it from a file that could itself
be updated over OTA.

---

## Optional auth token

```python
OTAManager.AUTH_TOKEN = "your-pre-shared-secret"
```

Set to `None` (default) to disable auth. When set, the client must include the
token as the last field of `OTA:START` or the transfer is rejected.

The token travels in plaintext over BLE. It is not a cryptographic
guarantee — it prevents accidental updates from unknown clients, not a
determined attacker with a BLE sniffer. For stronger security, implement
a challenge-response mechanism on top of the protocol.

---

## Version guard

`OTAManager` calls `_is_downgrade(incoming_version)` before arming.
The default implementation reads `VERSION` from `config.py` and does a
semantic version comparison:

```python
# config.py
VERSION = "1.2.3"
```

Override `_is_downgrade` in a subclass if your version format differs:

```python
class MyOTAManager(OTAManager):
    def _is_downgrade(self, incoming):
        from config import BUILD_NUMBER
        return int(incoming) < BUILD_NUMBER
```

---

## Filesystem layout after a successful update

```
/main.py          ← new version (just committed)
/main.py.bak      ← previous version (backup)
```

The temp file `/_ota_tmp` is always removed — either on successful commit
(after rename) or on abort/error.

---

## Recovering from a bad update

If the new `main.py` crashes on boot, you can recover via UART:

```python
# In MicroPython REPL over UART:
import os
os.rename('main.py.bak', 'main.py')
import machine; machine.reset()
```

Consider adding a boot-count watchdog to automate this:

```python
# boot.py
import os, nvs  # or use a small flag file

boots = 0
try:
    with open('_boot_count', 'r') as f:
        boots = int(f.read().strip())
except:
    pass

if boots >= 3:
    # Three failed boots — restore backup
    try:
        os.rename('main.py.bak', 'main.py')
    except:
        pass
    boots = 0

with open('_boot_count', 'w') as f:
    f.write(str(boots + 1))
```

Clear `_boot_count` from your `main.py` on successful startup.
