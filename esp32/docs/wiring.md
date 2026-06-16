# Wiring OTAManager into your NUS application

## Minimal integration

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

## Allowlist

```python
OTAManager.ALLOWED_FILES = {'main.py', 'app.py', 'config.py'}
```

Keep this hardcoded. Never derive it from a file that OTA could overwrite.

## Auth token

```python
OTAManager.AUTH_TOKEN = "your-pre-shared-secret"
```

Set to `None` (default) to disable.

## Recovery after a bad update

```python
# In MicroPython REPL over UART:
import os
os.rename('main.py.bak', 'main.py')
import machine; machine.reset()
```
