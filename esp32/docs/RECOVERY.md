# Recovery guide

This document covers every known failure scenario for the NUS-based OTA update system,
ranked roughly by likelihood, with diagnosis steps and recovery procedures for each.

---

## Failure scenarios at a glance

| Scenario | Needs UART? | Auto-recovers? |
|---|---|---|
| CRC mismatch on commit | No | Yes — old file untouched |
| Power loss mid-transfer | No | Yes — old file untouched |
| Power loss during rename | **Yes** | No (see boot watchdog) |
| New code crashes on boot | **Yes** (or boot watchdog) | With watchdog: yes |
| Filesystem full | No | Yes — transfer aborted cleanly |
| BLE drop mid-transfer | No | With disconnect hook or ABORT prefix |

---

## Scenario 1 — CRC mismatch on commit

**Trigger:** A chunk arrived corrupted (rare over BLE but possible). The device
computes a different CRC32 than the value declared in `OTA:START`.

**What the device does:**
1. Replies `OTA:ERR:CRC:got=<x>,exp=<y>`
2. Deletes `_ota_tmp`
3. Returns to `IDLE`

`main.py` is never touched. The old code keeps running.

**Recovery:** None required — just retry the transfer from the client.

**REPL check (optional):**
```python
import os
os.listdir('/')  # confirm _ota_tmp is absent, main.py is present
```

---

## Scenario 2 — Power loss or reset mid-transfer (before COMMIT)

**Trigger:** Device loses power or is manually reset while `OTA:DATA` packets
are still flowing, before `OTA:COMMIT` is sent.

**What happens:** `_ota_tmp` is left as a partial file on the filesystem.
`main.py` is untouched. On reboot the old code runs normally.

**Recovery:** None required. The partial temp file wastes a few KB.

**REPL cleanup (optional):**
```python
import os
try:
    os.remove('_ota_tmp')
except OSError:
    pass
```

---

## Scenario 3 — Power loss during the commit rename window ⚠️

This is the only scenario that can leave the device in a state where it
will not boot without UART intervention.

**The commit sequence:**
```
A:  os.rename('main.py', 'main.py.bak')   ← backup old file
B:  os.rename('_ota_tmp', 'main.py')      ← put new file in place
C:  machine.reset()
```

| Power dies between… | Result |
|---|---|
| A and B | `main.py` is missing — device won't boot |
| B and C | New code in place — next power cycle boots it fine |

On LittleFS (the MicroPython default on ESP32) both renames are close to
atomic, making this window extremely narrow. But it exists.

**REPL recovery — connect via UART:**
```python
import os
os.rename('main.py.bak', 'main.py')
import machine; machine.reset()
```

**Preventive measure:** The boot watchdog in Scenario 4 also covers this
case — if `main.py` is missing, the watchdog's `except OSError` on the
boot-count read will execute the rollback branch.

---

## Scenario 4 — New code crashes on boot (bad update)

**Trigger:** The transfer and commit succeed, the device resets, and the new
`main.py` raises an unhandled exception before the NUS service initialises.
The device is now unreachable over BLE — you cannot OTA again because OTA
depends on NUS being up.

**REPL recovery — connect via UART:**
```python
import os
os.rename('main.py.bak', 'main.py')
import machine; machine.reset()
```

### Boot watchdog (eliminates UART intervention)

Add this to `boot.py` so the device rolls back automatically after three
consecutive failed boots:

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
    # Three consecutive failed boots — roll back to previous version
    try:
        os.rename('main.py.bak', 'main.py')
        print('[boot] rolled back after 3 failed boots')
    except OSError as e:
        print('[boot] rollback failed:', e)
    boots = 0

with open(_COUNT_FILE, 'w') as f:
    f.write(str(boots + 1))
```

Then, once your application has started successfully (NUS is advertising,
your app loop is running), clear the counter:

```python
# In main.py, after successful startup:
import os
try:
    os.remove('_boot_count')
except OSError:
    pass
```

The counter increments on every boot and is only cleared when the app reaches
a known-good state. If it reaches 3 without being cleared, the watchdog
restores the backup and resets — no UART needed.

---

## Scenario 5 — Filesystem full during transfer

**Trigger:** `_on_data` raises `OSError` on `self._fh.write(chunk)` because
the filesystem has no free space.

**What the device does:**
1. Calls `_abort_internal()` — closes and deletes `_ota_tmp`
2. Replies `OTA:ERR:WRITE:<errno>`
3. Returns to `IDLE`

`main.py` is untouched. The pre-check in `_on_start` (80% headroom rule)
catches most cases before any data flows, but files written by the application
between the check and the transfer can close the gap.

**REPL diagnosis:**
```python
import os
st = os.statvfs('/')
block  = st[0]
free   = st[3]
print(f"Free: {block * free / 1024:.1f} KB  ({free} blocks of {block} B)")
os.listdir('/')
```

**Recovery:** Free space (remove logs, old `.bak` files, etc.), then retry
the transfer.

---

## Scenario 6 — BLE connection drops mid-transfer

**Trigger:** The client disconnects unexpectedly (app backgrounded, phone
goes out of range, OS kills the BLE connection) while a transfer is in
progress.

**What happens:** The NUS layer closes but `OTAManager` is still in
`RECEIVING` state with `_fh` open. It sits there indefinitely — there is
no timeout in the state machine.

On reconnect, the client sends a fresh `OTA:START`, and the manager replies
`OTA:REJECT:BUSY` because `_state != IDLE`.

### Fix A — disconnect hook in your NUS handler (recommended)

Wire the BLE disconnect event to `ota.abort()`:

```python
def _on_disconnect(self):
    self.ota.abort()   # silently resets state to IDLE, cleans up _ota_tmp
```

This is the cleanest solution. Check your NUS implementation for the
disconnect callback name — in the standard MicroPython `bluetooth.BLE`
API it arrives as `_IRQ_CENTRAL_DISCONNECT` in the IRQ handler.

### Fix B — ABORT prefix on every new session (quick workaround)

Have the client send `OTA:ABORT` unconditionally before every `OTA:START`:

```python
# In ota_client.py / NusOtaService.dart, before the handshake:
await send("OTA:ABORT")
await asyncio.sleep(0.2)   # give the device time to process
# Now send OTA:START as normal
```

The device responds `OTA:ABORTED` if armed/receiving, or ignores it and
replies `OTA:ABORTED` from IDLE — either way it ends up in IDLE, ready for
a fresh START.

**REPL to unstick without a restart (if you have UART):**
```python
# Assuming ota is your OTAManager instance:
ota._abort_internal()
# or simply reset the device:
import machine; machine.reset()
```

---

## General UART recovery procedure

If the device is unresponsive over BLE and you need to intervene via UART:

1. Connect your UART adapter (TX→RX, RX→TX, GND→GND).
2. Open a serial terminal at 115200 baud.
3. Press Ctrl-C to interrupt any running code and get the REPL prompt `>>>`.
4. Run the appropriate recovery commands from the scenarios above.
5. Call `machine.reset()` or press Ctrl-D to soft-reset.

**Useful REPL one-liners:**

```python
# List all files and their sizes
import os
for f in os.listdir('/'):
    st = os.stat(f)
    print(f'{f:30s}  {st[6]} B')

# Check filesystem free space
st = os.statvfs('/')
print(f'Free: {st[0]*st[3]//1024} KB  Total: {st[0]*st[2]//1024} KB')

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

## Hardening checklist

Before deploying to a device you cannot easily reach with UART:

- [ ] `boot.py` boot watchdog installed and tested
- [ ] Application clears `_boot_count` on successful startup
- [ ] `_on_disconnect` hook calls `ota.abort()` in your NUS handler
- [ ] Client sends `OTA:ABORT` before every `OTA:START` as belt-and-suspenders
- [ ] `OTAManager.ALLOWED_FILES` is hardcoded and reviewed
- [ ] At least one spare `.bak` recovery was tested end-to-end on the bench
