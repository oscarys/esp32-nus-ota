# esp32/

MicroPython firmware for the ESP32 OTA target.

## Files

| File | Purpose |
|---|---|
| `ota_manager.py` | `OTAManager` class — copy this to your device |
| `main.py` | Demo app wiring NUS + OTA together |
| `docs/approaches.md` | Comparison of OTA approaches |
| `docs/protocol.md` | Full protocol specification |
| `docs/wiring.md` | Integration guide |
| `tests/conftest.py` | pytest stubs for MicroPython-only modules |
| `tests/test_ota_manager.py` | Unit tests (no hardware needed) |

## Deploy

```bash
mpremote cp ota_manager.py :ota_manager.py
mpremote cp main.py :main.py
```

## Run tests

```bash
pip install pytest
pytest esp32/tests/ -v
```
