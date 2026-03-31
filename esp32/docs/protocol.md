# OTA Protocol Reference

All messages are newline-terminated UTF-8 strings carried over the standard
NUS RX (client→device) and TX (device→client) characteristics.

## Packet format

```
OTA:<COMMAND>[:<field>...]\n
```

Fields are colon-separated. No spaces. All commands are case-insensitive on
receipt; responses are always upper-case.

---

## Commands

### OTA:START

Sent by the client to initiate a transfer.

```
OTA:START:<filename>:<size>:<crc32>[:<version>[:<chunk_size>[:<token>]]]
```

| Field | Type | Required | Description |
|---|---|---|---|
| `filename` | string | yes | Target filename, e.g. `main.py`. Must be in the device allowlist. |
| `size` | integer | yes | Total file size in bytes. |
| `crc32` | hex string | yes | CRC32 of the full file, lowercase hex, zero-padded to 8 chars. |
| `version` | string | no | Semantic version of the new file, e.g. `1.2.3`. Used for downgrade protection. |
| `chunk_size` | integer | no | Bytes of file data per DATA packet. Default 180. |
| `token` | string | no | Pre-shared auth token. Required if `AUTH_TOKEN` is set on the device. |

**Device replies:**

| Reply | Meaning |
|---|---|
| `OTA:READY` | Device is armed and waiting for DATA packets. |
| `OTA:REJECT:FORBIDDEN` | Filename not in allowlist. |
| `OTA:REJECT:NOSPACE` | Insufficient free storage. |
| `OTA:REJECT:AUTH` | Token missing or incorrect. |
| `OTA:REJECT:VERSION` | Incoming version is older than current. |
| `OTA:REJECT:BUSY` | A transfer is already in progress. |
| `OTA:REJECT:BAD_ARGS` | Missing required fields. |

---

### OTA:DATA

Sent by the client, once per chunk, in sequence.

```
OTA:DATA:<seq>:<hex_payload>
```

| Field | Type | Description |
|---|---|---|
| `seq` | integer | Zero-based sequence number. |
| `hex_payload` | hex string | Chunk bytes, hex-encoded (lowercase). Length = `chunk_size × 2` chars, except possibly the last chunk. |

**Why hex-encoded?** NUS carries arbitrary bytes, but encoding as hex makes
the framing trivially robust — no null bytes, no accidental newlines inside
the payload.

**Device replies:**

| Reply | Meaning |
|---|---|
| `OTA:ACK:<seq>` | Chunk received and written. Ready for next. |
| `OTA:ERR:<seq>` | Unexpected sequence number or write error. Client should retransmit. |

**Duplicate handling:** If the device receives `seq == expected - 1`, it
re-sends `OTA:ACK:<seq>` without writing again. This handles the case where
the client missed an ACK and retransmits.

---

### OTA:COMMIT

Sent by the client after all DATA chunks have been acknowledged.

```
OTA:COMMIT
```

Device actions on receipt:
1. Closes and flushes the temp file.
2. Verifies `received_bytes == declared_size`.
3. Verifies CRC32 of received data matches the value from `OTA:START`.
4. Backs up existing target file as `<filename>.bak`.
5. Renames `_ota_tmp` → `<filename>` (atomic on LittleFS).
6. Replies `OTA:OK` or an error.
7. Calls `machine.reset()` (after a short drain delay).

**Device replies:**

| Reply | Meaning |
|---|---|
| `OTA:OK` | Transfer committed. Device will reset momentarily. |
| `OTA:ERR:SIZE:got=N,exp=M` | Received byte count doesn't match declared size. |
| `OTA:ERR:CRC:got=X,exp=Y` | CRC32 mismatch. File not written. |
| `OTA:ERR:RENAME:<msg>` | Filesystem error during rename. Old file restored from backup. |
| `OTA:ERR:NOT_RECEIVING` | COMMIT received before any DATA. |

---

### OTA:ABORT

Sent by the client at any time to cancel the transfer.

```
OTA:ABORT
```

Device discards the buffer, removes `_ota_tmp`, restores any backup, and
returns to IDLE.

**Device reply:** `OTA:ABORTED`

---

## State machine

```
IDLE ──OTA:START(valid)──► ARMED ──OTA:DATA:0──► RECEIVING ──OTA:COMMIT──► COMMITTING
 ▲                           │                       │                          │
 │◄──────ABORT───────────────┘◄──────ABORT───────────┘                    OTA:OK / ERR
 │                                                                              │
 └──────────────────────────────────────────────────────────────────────────────┘
```

---

## Timing and reliability

| Parameter | Default | Notes |
|---|---|---|
| ACK timeout (client) | 8 s | Per chunk, before retry. |
| Max retries (client) | 5 | Per chunk, then ABORT. |
| Commit timeout (client) | 15 s | Device may reset before reply drains — timeout treated as success. |
| Chunk size | 88 bytes raw / 176 chars hex | Safe below default 20-byte MTU after stack fragmentation. Increase to 200 after confirming MTU 512 negotiation. |

---

## CRC32

Both sides use the standard ISO 3309 polynomial (same as Python's
`binascii.crc32()` and Dart's equivalent):

- Polynomial: `0xEDB88320` (reflected)
- Initial value: `0xFFFFFFFF`
- Final XOR: `0xFFFFFFFF`

The client computes CRC32 over the entire file before sending `OTA:START`.
The device accumulates CRC32 incrementally as chunks arrive, using the
running value as the seed for each subsequent `binascii.crc32(chunk, running)`
call. The final accumulated value is compared against the declared CRC at
`COMMIT` time.

---

## Example session

```
→  OTA:START:main.py:312:a3f1c820:1.2.0:88:mytoken
←  OTA:READY
→  OTA:DATA:0:7072696e74282768656c6c6f27290a...   (88 bytes → 176 hex chars)
←  OTA:ACK:0
→  OTA:DATA:1:...
←  OTA:ACK:1
→  OTA:DATA:2:...
←  OTA:ACK:2           ← ACK lost in transit
→  OTA:DATA:2:...      ← client retransmits
←  OTA:ACK:2           ← device re-ACKs without double-writing
→  OTA:DATA:3:...      ← last chunk (may be shorter)
←  OTA:ACK:3
→  OTA:COMMIT
←  OTA:OK
    [device resets]
```
