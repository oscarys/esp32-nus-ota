# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2025 esp32-nus-ota contributors
# https://github.com/oscarys/esp32-nus-ota
"""
ESP32 MicroPython — NUS + OTA demo with hardware watchdog integration.

Replace BLENUS with your existing NUS implementation.
Adjust WDT_TIMEOUT_MS to match your application's watchdog timeout.
"""
import bluetooth
import time
from machine import WDT
from ota_manager import OTAManager

DEVICE_NAME    = "ESP32-OTA"
OTA_TOKEN      = None                    # set to a string to enable auth
OTA_ALLOWED    = {'main.py', 'app.py', 'config.py'}
WDT_TIMEOUT_MS = 3000                   # must be > RESET_DELAY_MS (200)


class App:
    def __init__(self):
        # Initialise hardware watchdog — must be fed at least every
        # WDT_TIMEOUT_MS milliseconds or the device resets.
        self._wdt = WDT(timeout=WDT_TIMEOUT_MS)

        self._ble = bluetooth.BLE()

        # Replace BLENUS with your NUS implementation:
        # self._nus = BLENUS(
        #     self._ble,
        #     name=DEVICE_NAME,
        #     on_rx=self._on_rx,
        #     on_disconnect=self._on_disconnect,
        # )

        OTAManager.ALLOWED_FILES = OTA_ALLOWED
        OTAManager.AUTH_TOKEN    = OTA_TOKEN

        # Pass the watchdog to OTAManager so it can feed it during
        # long flash writes and inter-packet gaps.
        self._ota = OTAManager(reply_fn=self._nus_send, wdt=self._wdt)

        print(f"[app] advertising as '{DEVICE_NAME}'")

    # ------------------------------------------------------------------
    # NUS callbacks
    # ------------------------------------------------------------------

    def _on_rx(self, data):
        """Called by the NUS layer on every received packet."""
        line = data.decode('utf-8', 'ignore').strip()
        if line.startswith("OTA:"):
            self._ota.handle(line)
        else:
            self._handle_app(line)

    def _on_disconnect(self):
        """Called by the NUS layer when the central disconnects.

        Resets the OTA state machine so a reconnecting client gets a
        clean IDLE state rather than OTA:REJECT:BUSY.
        """
        self._ota.abort()

    # ------------------------------------------------------------------
    # Application protocol
    # ------------------------------------------------------------------

    def _handle_app(self, line):
        if line == "PING":
            self._nus_send("PONG")
        elif line == "VERSION":
            try:
                from config import VERSION
                self._nus_send("VERSION:{}".format(VERSION))
            except ImportError:
                self._nus_send("VERSION:unknown")
        # ... add your own commands here

    # ------------------------------------------------------------------
    # NUS send wrapper
    # ------------------------------------------------------------------

    def _nus_send(self, text):
        """Send a line to the connected client over NUS TX."""
        # self._nus.send((text + '\n').encode())
        pass  # replace with your NUS notify call

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def run(self):
        """Main loop — feeds the watchdog and yields to the BLE scheduler."""
        while True:
            self._wdt.feed()
            time.sleep_ms(500)   # well under WDT_TIMEOUT_MS


App().run()
