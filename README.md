# esp32-nus-ota

Over-the-air MicroPython script updates for ESP32 via Bluetooth LE, using the
Nordic UART Service (NUS) as the transport. No custom GATT service, no
re-pairing — OTA traffic rides alongside your existing NUS application protocol.

```
Phone / laptop  ──BLE NUS──►  ESP32 MicroPython
OTA:START  ────────────────►
           ◄────────────────  OTA:READY
OTA:DATA:0 ────────────────►
           ◄────────────────  OTA:ACK:0
   ...            ...
OTA:COMMIT ────────────────►
           ◄────────────────  OTA:OK  →  machine.reset()
```

## Contents

| Folder | What it is |
|---|---|
| [`esp32/`](esp32/) | MicroPython firmware — `OTAManager` class + wiring demo |
| [`python-client/`](python-client/) | Desktop/laptop CLI tool (Python + bleak) |
| [`flutter-client/`](flutter-client/) | Android Flutter app with OTA screen |
| [`docs/`](esp32/docs/) | Protocol reference, wiring guide |

## How it works

OTA messages are newline-terminated ASCII lines prefixed with `OTA:`,
multiplexed over the standard NUS RX/TX characteristics. Your existing NUS
`on_rx` handler routes lines that start with `OTA:` to the `OTAManager`
and passes everything else to your application as before.

A full transfer has three phases:

1. **Handshake** — client sends `OTA:START` with filename, size, CRC32, and
   optional version/token. Device validates and replies `OTA:READY` or
   `OTA:REJECT:<reason>`.

2. **Transfer** — client sends hex-encoded chunks as `OTA:DATA:<seq>:<hex>`.
   Device replies `OTA:ACK:<seq>` or `OTA:ERR:<seq>`. Lost ACKs and
   out-of-order chunks are handled automatically.

3. **Commit** — client sends `OTA:COMMIT`. Device verifies CRC32, renames
   the temp file to the target atomically, backs up the old file, replies
   `OTA:OK`, and calls `machine.reset()`.

See [`esp32/docs/protocol.md`](esp32/docs/protocol.md) for the full
specification.

## Quick start

### ESP32

Copy `esp32/ota_manager.py` to your device, then add two lines to your
existing NUS handler:

```python
from ota_manager import OTAManager

class NUSService:
    def __init__(self):
        self.ota = OTAManager(reply_fn=self._nus_send)

    def _on_rx(self, data):
        line = data.decode('utf-8', 'ignore').strip()
        if line.startswith("OTA:"):
            self.ota.handle(line)   # ← OTA traffic
        else:
            self._app_handle(line)  # ← your existing logic
```

Edit `OTAManager.ALLOWED_FILES` to list the scripts you permit to be updated.

### Python client

```bash
pip install bleak
python python-client/ota_client.py --scan
python python-client/ota_client.py --device "ESP32-OTA" --file main.py
```

### Flutter (Android)

```dart
// Already connected via your existing BLE code:
Navigator.push(context, MaterialPageRoute(
  builder: (_) => OtaScreen(connectedDevice: yourBluetoothDevice),
));
```

See [`flutter-client/README.md`](flutter-client/README.md) for full setup.

## Security

- **Allowlist** — only files explicitly listed in `ALLOWED_FILES` can be
  written. Path traversal attempts are rejected before any file I/O.
- **CRC32 verification** — the full file CRC is checked before the target
  file is overwritten.
- **Atomic rename** — `_ota_tmp` → `target.py` only happens after CRC passes.
- **Backup** — the previous version is preserved as `target.py.bak`.
- **Optional auth token** — a pre-shared token field in `OTA:START` prevents
  casual updates from unknown clients.

## Running the tests

```bash
pip install pytest pytest-asyncio bleak
pytest esp32/tests/ python-client/tests/ -v
```

See [`esp32/tests/`](esp32/tests/) and [`python-client/tests/`](python-client/tests/)
for details.

## Contributing

Pull requests welcome. Please run the test suite before opening a PR.
New protocol features should include tests for both the ESP32 and client sides.

## License

MIT — see [LICENSE](LICENSE).
