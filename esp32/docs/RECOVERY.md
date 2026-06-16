# Recovery guide

This document covers every known failure scenario for the NUS-based OTA
update system, ranked roughly by likelihood, with diagnosis steps and
recovery procedures for each.

---

## Failure scenarios at a glance

| Scenario | Needs UART? | Auto-recovers? |
|---|---|---|
| CRC mismatch on commit | No | Yes — old file untouched |
| Power loss mid-transfer | No | Yes — old file untouched |
| Power loss during rename | **Yes** | With boot watchdog: yes |
| New code crashes on boot | **Yes** | With boot watchdog: yes |
| Filesystem full | No | Yes — transfer aborted cleanly |
| BLE drop mid-transfer | No | With disconnect hook or ABORT prefix |
| Hardware WDT fires mid-transfer | No | Yes — if WDT fed correctly in OTAManager |
| Hardware WDT fires during rename | **Yes** | With boot watchdog: yes |

---

## Scenario 1 — CRC mismatch on commit

**Trigger:** A chunk arrived corrupted. The device computes a different
CRC32 than the value declared in `OTA:START`.

**What the device does:**
1. Replies `OTA:ERR:CRC:got=<x>,exp=<y>`
2. Deletes `_ota_tmp`
3. Returns to `IDLE`

`main.py` is never touched. The old code keeps running.

**Recovery:** None required — just retry the transfer.

**REPL check (optional):**
```python
import os
os.listdir('/')  # confirm _ota_tmp is absent, main.py is present
```

---

## Scenario 2 — Power loss or reset mid-transfer (before COMMIT)

**Trigger:** Device loses power or resets while `OTA:DATA` packets are
still flowing, before `OTA:COMMIT` is sent.

**What happens:** `_ota_tmp` may be left as a partial file. `main.py` is
untouched. On reboot the old code runs normally.

**Recovery:** None required.

**REPL cleanup (optional):**
```python
import os
try:
    os.remove('_ota_tmp')
except OSError:
    pass
```

---

## Scenario 3 — Power loss (or WDT reset) during the commit rename window ⚠️

This is the only scenario that can leave the device unable to boot
without intervention.  A hardware watchdog makes it more likely than a
random power cut because WDT resets happen at predictable intervals.

**The commit sequence:**
```
A:  os.rename('main.py', 'main.py.bak')   ← backup old file
B:  os.rename('_ota_tmp', 'main.py')      ← put new file in place
C:  time.sleep_ms(200)                    ← flush BLE reply
D:  machine.reset()
```

| Reset occurs between… | Result |
|---|---|
| A and B | `main.py` missing — device will not boot |
| B and C/D | New code in place — next power cycle boots it fine |

On LittleFS both renames are close to atomic, making this window
extremely narrow.  The `OTAManager._feed()` call at the start of
`_on_commit()` buys time before the rename sequence begins, reducing
the risk further.  The boot watchdog below eliminates it entirely.

**REPL recovery — connect via UART:**
```python
import os
os.rename('main.py.bak', 'main.py')
import machine; machine.reset()
```

---

## Scenario 4 — New code crashes on boot (bad update)

**Trigger:** Transfer and commit succeed.  The device resets.  The new
`main.py` raises an unhandled exception before the NUS service
initialises.  The device is now unreachable over BLE.

**REPL recovery — connect via UART:**
```python
import os
os.rename('main.py.bak', 'main.py')
import machine; machine.reset()
```

### Boot watchdog — eliminates UART intervention for Scenarios 3 and 4

Add this to `boot.py`.  It increments a counter on every boot and rolls
back to `main.py.bak` after three consecutive failed boots (i.e. boots
where `main.py` never cleared the counter).

```python
# boot.py — OTA boot watchdog
import os

_COUNT_FILE = '_boot_count'

try:
    with open(_COUNT_FILE, 'r') as f:
        boots = int(f.read().strip())
except OSError:
    boots = 0

if boots >= 3:
    try:
        os.rename('main.py.bak', 'main.py')
        print('[boot] rolled back after 3 failed boots')
    except OSError as e:
        print('[boot] rollback failed:', e)
    boots = 0

with open(_COUNT_FILE, 'w') as f:
    f.write(str(boots + 1))
```

Then, once your application has started successfully — NUS is
advertising, your main loop is running — clear the counter:

```python
# In main.py, after successful startup:
import os
try:
    os.remove('_boot_count')
except OSError:
    pass
```

This also covers Scenario 3: if `main.py` is missing (rename window
power cut), `os.rename('main.py.bak', 'main.py')` in the watchdog
restores it before MicroPython tries to run `main.py`.

---

## Scenario 5 — Filesystem full during transfer

**Trigger:** `_on_data` raises `OSError` on `self._fh.write()`.

**What the device does:**
1. Calls `_abort_internal()` — closes and deletes `_ota_tmp`
2. Replies `OTA:ERR:WRITE:<errno>`
3. Returns to `IDLE`

`main.py` is untouched.  The `_on_start` pre-check (80 % headroom rule)
catches most cases before any data flows, but files written by the
application between the check and the transfer can close the gap.

**REPL diagnosis:**
```python
import os
st = os.statvfs('/')
print('Free: {} KB'.format(st[0] * st[3] // 1024))
os.listdir('/')
```

**Recovery:** Free space (remove logs, old `.bak` files, etc.) then retry.

---

## Scenario 6 — BLE connection drops mid-transfer

**Trigger:** Client disconnects unexpectedly while a transfer is in
progress.

**What happens:** `OTAManager` stays in `RECEIVING` state with `_fh`
open indefinitely — the state machine has no timeout.  On reconnect the
client's fresh `OTA:START` gets `OTA:REJECT:BUSY`.

### Fix A — disconnect hook (recommended)

Wire the BLE disconnect event to `ota.abort()`:

```python
def _on_disconnect(self):
    self.ota.abort()   # resets state to IDLE, cleans up _ota_tmp
```

Check your NUS implementation for the disconnect callback.  In the
standard MicroPython `bluetooth.BLE` API it arrives as
`_IRQ_CENTRAL_DISCONNECT` in the IRQ handler.

### Fix B — ABORT prefix on every new session (belt-and-suspenders)

Have the client send `OTA:ABORT` unconditionally before every `OTA:START`:

```python
# In ota_client.py, before the handshake:
await send("OTA:ABORT")
await asyncio.sleep(0.2)
# Now send OTA:START
```

The device replies `OTA:ABORTED` from any state and returns to `IDLE`,
ready for a fresh start.  Both fixes can coexist.

**REPL to unstick (if you have UART):**
```python
import machine; machine.reset()
```

---

## Scenario 7 — Hardware watchdog fires mid-transfer

**Trigger:** Your application runs a `machine.WDT` and `OTAManager` was
not passed the `wdt` parameter, so nobody is feeding the watchdog during
the transfer.  A long inter-packet BLE gap, a flash sector erase
(~50 ms), or the `time.sleep_ms(200)` before reset triggers the WDT.

**What happens:** Depends on where in the transfer the reset occurs:

- During `OTA:DATA` → same as Scenario 2 (safe, `_ota_tmp` abandoned)
- During commit rename → same as Scenario 3 (dangerous)
- During `sleep_ms(200)` after `OTA:OK` → new code is already in place,
  device reboots into it; the client times out waiting for the reply but
  can detect the reconnect and consider the transfer successful

**Prevention:** Always pass your watchdog instance to `OTAManager`:

```python
from machine import WDT
wdt = WDT(timeout=3000)
ota = OTAManager(reply_fn=nus_send, wdt=wdt)
```

`OTAManager` then feeds the watchdog at four points:
- `handle()` entry — covers inter-packet gaps
- After `_fh.write()` — covers flash erase stalls
- Start of `_on_commit()` — covers the rename sequence
- After `sleep_ms(RESET_DELAY_MS)` — covers the BLE flush wait

See `wiring.md` for timeout guidance and the `WatchdogAwareOTA` subclass
for very tight timeouts (< 1 s) that need widening during OTA.

---

## General UART recovery procedure

If the device is unreachable over BLE:

1. Connect your UART adapter (TX→RX, RX→TX, GND→GND).
2. Open a terminal at **115200 baud**.
3. Press **Ctrl-C** to interrupt running code and reach the REPL `>>>`.
4. Run the recovery commands for your scenario (see above).
5. Press **Ctrl-D** or call `machine.reset()` to reboot.

**Useful REPL one-liners:**

```python
# List files and sizes
import os
for f in os.listdir('/'):
    print('{:30s}  {} B'.format(f, os.stat(f)[6]))

# Check free space
st = os.statvfs('/')
print('Free: {} KB  Total: {} KB'.format(
    st[0]*st[3]//1024, st[0]*st[2]//1024))

# Roll back to previous version
os.rename('main.py.bak', 'main.py')

# Remove leftover temp file
os.remove('_ota_tmp')

# Remove stuck boot counter
os.remove('_boot_count')

# Soft reset
import machine; machine.reset()
```

---

## Pre-deployment hardening checklist

Run through this before deploying to a device that is difficult to reach
with a UART cable.

- [ ] `boot.py` boot watchdog installed and tested (manual rollback verified)
- [ ] Application clears `_boot_count` on successful startup
- [ ] `OTAManager` instantiated with `wdt=` parameter
- [ ] Main loop feeds watchdog at interval well below WDT timeout
- [ ] `_on_disconnect` hook calls `ota.abort()` in your NUS handler
- [ ] Client sends `OTA:ABORT` before every `OTA:START` as belt-and-suspenders
- [ ] `OTAManager.ALLOWED_FILES` is hardcoded and reviewed
- [ ] End-to-end rollback tested on the bench (transfer a crashing file,
      confirm three-boot watchdog restores the working version)
- [ ] WDT-during-rename tested: cut power during a commit, confirm
      boot watchdog recovers cleanly
