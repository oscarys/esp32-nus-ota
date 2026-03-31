# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025 esp32-nus-ota contributors
# https://github.com/oscarys/esp32-nus-ota

"""
ESP32 MicroPython — NUS + OTA demo
Drop ota_manager.py alongside this file on your device.

Tested with:
  - ESP32 DevKit v1
  - MicroPython v1.23+
  - NUS service UUID: 6e400001-b5a3-f393-e0a9-e50e24dcca9e
"""
import bluetooth
import time
from micropython import const
from ble_nus import BLENUS          # your existing NUS implementation
from ota_manager import OTAManager


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEVICE_NAME  = "ESP32-OTA"

# Optionally set a pre-shared token — clients must include it in OTA:START.
# Set to None to disable auth.
OTA_TOKEN    = None

# Files that may be updated over the air.
# IMPORTANT: keep this hardcoded — never derive it from an updatable file.
OTA_ALLOWED  = {'main.py', 'app.py', 'config.py'}


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
class App:
    def __init__(self):
        self._ble = bluetooth.BLE()
        self._nus = BLENUS(self._ble, name=DEVICE_NAME, on_rx=self._on_rx)

        OTAManager.ALLOWED_FILES = OTA_ALLOWED
        OTAManager.AUTH_TOKEN    = OTA_TOKEN
        self._ota = OTAManager(reply_fn=self._nus.send)

        print(f"[app] advertising as '{DEVICE_NAME}'")

    def _on_rx(self, data):
        """Called by BLENUS on every received NUS packet."""
        line = data.decode('utf-8', 'ignore').strip()

        if line.startswith("OTA:"):
            # Delegate all OTA traffic to OTAManager
            self._ota.handle(line)
        else:
            # Your existing application protocol
            self._handle_app(line)

    def _handle_app(self, line):
        """Handle non-OTA application messages."""
        print(f"[app] rx: {line}")
        if line == "PING":
            self._nus.send("PONG")
        elif line == "VERSION":
            try:
                from config import VERSION
                self._nus.send(f"VERSION:{VERSION}")
            except ImportError:
                self._nus.send("VERSION:unknown")
        # ... add your own commands here

    def run(self):
        while True:
            time.sleep_ms(100)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
App().run()
