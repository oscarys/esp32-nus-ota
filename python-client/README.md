# python-client/

Desktop/laptop OTA client. Runs on macOS, Linux, and Windows.

## Install

```bash
pip install -r requirements.txt
```

## Usage

```bash
python ota_client.py --scan
python ota_client.py --file main.py --device "ESP32-OTA"
python ota_client.py --file main.py --address "AA:BB:CC:DD:EE:FF"
python ota_client.py --file main.py --device "ESP32-OTA" --version 1.2.0
python ota_client.py --file main.py --device "ESP32-OTA" --token mySecret
python ota_client.py --file main.py --device "ESP32-OTA" --chunk 64
python ota_client.py --file main.py --device "ESP32-OTA" --verbose
```

## Run tests

```bash
pip install -r requirements-test.txt
pytest tests/ -v
```
