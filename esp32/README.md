# esp32/

MicroPython firmware for the ESP32 OTA target.

## Files

| File | Purpose |
|---|---|
| `ota_manager.py` | `OTAManager` class — copy this to your device |
| `main.py` | Demo app wiring NUS + OTA together |
| `docs/protocol.md` | Full protocol specification |
| `docs/wiring.md` | Integration guide |
| `tests/conftest.py` | pytest stubs for MicroPython-only modules |
| `tests/test_ota_manager.py` | Unit tests (run on desktop, no hardware needed) |

## Deploy

```bash
# Using mpremote
mpremote cp ota_manager.py :ota_manager.py
mpremote cp main.py :main.py

# Using ampy
ampy --port /dev/ttyUSB0 put ota_manager.py
ampy --port /dev/ttyUSB0 put main.py
```

## Configure

Edit `ota_manager.py` before deploying:

```python
# Files permitted to be updated over the air
OTAManager.ALLOWED_FILES = {'main.py', 'app.py', 'config.py'}

# Optional pre-shared auth token (None = disabled)
OTAManager.AUTH_TOKEN = None
```

## Run tests

```bash
cd esp32/tests
pip install pytest
pytest -v
```
