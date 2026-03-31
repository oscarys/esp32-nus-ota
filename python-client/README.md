# python-client/

Desktop/laptop OTA client. Runs on macOS, Linux, and Windows.
Uses [bleak](https://github.com/hbldh/bleak) for cross-platform BLE.

## Install

```bash
pip install -r requirements.txt
```

## Usage

```bash
# Scan for nearby NUS devices
python ota_client.py --scan

# Transfer by device name
python ota_client.py --file main.py --device "ESP32-OTA"

# Transfer by MAC/UUID address
python ota_client.py --file main.py --address "AA:BB:CC:DD:EE:FF"

# With version guard
python ota_client.py --file main.py --device "ESP32-OTA" --version 1.2.0

# With auth token
python ota_client.py --file main.py --device "ESP32-OTA" --token mySecret

# Smaller chunks if you hit MTU issues
python ota_client.py --file main.py --device "ESP32-OTA" --chunk 64

# Verbose — print every BLE packet
python ota_client.py --file main.py --device "ESP32-OTA" --verbose
```

## Platform notes

**macOS** — bleak uses CoreBluetooth UUIDs instead of MAC addresses.
Run `--scan` first to find the correct UUID for `--address`.

**Linux** — requires BlueZ 5.43+. Run as root or add your user to the
`bluetooth` group:
```bash
sudo usermod -aG bluetooth $USER
```

**Windows** — requires Windows 10 1903+ (WinRT BLE stack).

## Run tests

```bash
pip install -r requirements-test.txt
pytest tests/ -v
```

No hardware needed — tests use a mock ESP32 that speaks the OTA protocol
over asyncio queues.
