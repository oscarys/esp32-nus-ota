# esp32-nus-ota

Over-the-air MicroPython script updates for ESP32 via BLE, using the Nordic UART Service (NUS) as transport.
No custom GATT service, no re-pairing — OTA traffic rides alongside your existing NUS application protocol.

## How it works

![Protocol sequence](esp32/docs/img/protocol_sequence.svg)

OTA messages are newline-terminated ASCII lines prefixed with `OTA:`, multiplexed over the standard NUS RX/TX characteristics.
Your existing `on_rx` handler routes lines that start with `OTA:` to the `OTAManager` and passes everything else to your application.

See [`esp32/docs/RECOVERY.md`](esp32/docs/RECOVERY.md) for failure scenarios and recovery procedures,
[`esp32/docs/approaches.md`](esp32/docs/approaches.md) for the full approach comparison
and [`esp32/docs/protocol.md`](esp32/docs/protocol.md) for the full protocol specification.

## Contents

| Folder | What it is |
|---|---|
| [`esp32/`](esp32/) | MicroPython firmware — `OTAManager` class + wiring demo |
| [`python-client/`](python-client/) | Desktop/laptop CLI tool (Python + bleak) |
| [`flutter-client/`](flutter-client/) | Android Flutter app with OTA screen |
| [`esp32/docs/`](esp32/docs/) | Protocol reference, wiring guide, approach comparison |

## Quick start

### ESP32

Copy `esp32/ota_manager.py` to your device, then add two lines to your existing NUS handler:

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

### Python client

```bash
pip install bleak
python python-client/ota_client.py --scan
python python-client/ota_client.py --device "ESP32-OTA" --file main.py
```

### Flutter (Android)

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => OtaScreen(connectedDevice: yourBluetoothDevice),
));
```

## Running the tests

```bash
pip install pytest pytest-asyncio bleak
pytest esp32/tests/ python-client/tests/ -v
```

## License

GPL-3.0 — see [LICENSE](LICENSE).
