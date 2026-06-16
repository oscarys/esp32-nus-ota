# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025 esp32-nus-ota contributors
# https://github.com/oscarys/esp32-nus-ota
"""
ESP32 MicroPython — NUS + OTA demo.
Replace BLENUS with your existing NUS implementation.
"""
import bluetooth
import time
from ota_manager import OTAManager

DEVICE_NAME  = "ESP32-OTA"
OTA_TOKEN    = None
OTA_ALLOWED  = {'main.py', 'app.py', 'config.py'}

class App:
    def __init__(self):
        self._ble = bluetooth.BLE()
        # Replace with your NUS class:
        # self._nus = BLENUS(self._ble, name=DEVICE_NAME, on_rx=self._on_rx)
        OTAManager.ALLOWED_FILES = OTA_ALLOWED
        OTAManager.AUTH_TOKEN    = OTA_TOKEN
        self._ota = OTAManager(reply_fn=self._nus_send)

    def _on_rx(self, data):
        line = data.decode('utf-8', 'ignore').strip()
        if line.startswith("OTA:"):
            self._ota.handle(line)
        else:
            self._handle_app(line)

    def _handle_app(self, line):
        if line == "PING":
            self._nus_send("PONG")

    def _nus_send(self, text):
        pass  # replace with your NUS notify call

    def run(self):
        while True:
            time.sleep_ms(100)

App().run()
