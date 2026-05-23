# Feiyu SCORP C2 BLE / AK Protocol — Notes

Distilled from the decompiled stock app at `jadxOutput/`. This is the
reference for Steps 5–10 of `SPEC-flutter-app.md`. Cross-checked from
the actual Java sources cited inline. Anything marked **(TBV)** still
needs empirical verification against the real gimbal.

## 1. Gimbal identification

| Field | Value |
|---|---|
| Stock app BLE name regex | `FY_SCORP_[A-F0-9]{1,2}` (matches `FY_SCORP_C2_*`) |
| Our specific gimbal | name `FY_SCORP_C2_CD`, MAC `78:1C:3C:C9:12:CE` |
| Series in stock app | 7 (SCORP family) |
| `uuidType` (in `gimbal-properties-ble.xml`) | **1** ("g6" profile) |
| `protocolType` | **2** = AK (vs 1=G6, 0=SPG; see `Protocol.Type`) |

Note: there is no explicit `SCORP_C2` entry in the bundled XML; the
gimbal falls under the generic `SCORP` regex. All SCORP variants use
`uuidType=1` and `protocolType=2`, so we can treat C2 the same as the
other SCORPs.

## 2. BLE service / characteristic UUIDs

From `gimbal-properties-ble.xml` (the `uuidType=1` "g6" profile, shared
service for write and notify):

| Role | UUID |
|---|---|
| Service (write **and** notify) | `0000ffff-0000-1000-8000-00805f9b34fb` |
| Write characteristic | `0000ff01-0000-1000-8000-00805f9b34fb` |
| Notify characteristic | `0000ff02-0000-1000-8000-00805f9b34fb` |
| Indication service | (none — `uuidType=1` has no indicate channel) |

In `flutter_blue_plus`, after `connect()` + `discoverServices()`,
filter for the service UUID and grab the matching two characteristics.

## 3. Connect-time sequence (no handshake)

There is **no application-layer pairing/auth frame**. After the GATT
connection is established the stock app does only (in
`ConcomitantObserver.onConnectionStateChanged`, state=5):

1. Reads a "product name" characteristic for model identification —
   optional for us; we already know it's a SCORP.
2. Enables notifications on the notify characteristic (writes `01 00`
   to the CCCD `0x2902` descriptor — flutter_blue_plus does this
   implicitly via `setNotifyValue(true)`).
3. Requests MTU = **512** (`handleSetMTU`, sends `ChangeMtuBuilder(512)`
   with tag `"REQUEST_MTU"`). On success, sets data-writer package size
   to `mtu - 3` (ATT header overhead).
4. Calls `resetWriteOptions()` — uses EasyBLE library defaults (write
   **with response**, no extra delays).

**For the Dart port:** after `connect()`:
1. `discoverServices()`
2. `device.requestMtu(512)` (returns the negotiated MTU, usually
   smaller than requested)
3. find the notify characteristic, `setNotifyValue(true)`
4. start listening for frames

No frames need to be sent before commands are accepted.

## 4. Write mode and pacing

- **Write mode:** EasyBLE `WriteOptions` default with no overrides ⇒
  `BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT` = **write with
  response**. Use `withoutResponse: false` in `flutter_blue_plus`.
- **Package size (effective MTU for our writes):** `negotiated_mtu - 3`,
  capped at the gimbal's declared `maxPackageSize`. With MTU=512 this
  is up to ~509 bytes — far beyond any single AK frame we'll send.
  Hard fallback to 20 bytes for Pixel phones and a couple of Samsung
  models; not relevant for the user's phone.
- **Inter-write delay:** no explicit delay set (defaults to 0).

## 5. AK frame format

Constants from `Protocol.java`:

```
Header.NORMAL1 = 0xA5  (signed byte -91)
Header.NORMAL2 = 0x5A  (signed byte 90)
```

Endianness: `AkProtocol.IS_BIG_ENDIAN = false` → **little-endian** for
all multi-byte fields.

Frame layout, from `AkCmdWriter.generateWholeCmd` (the canonical
encoder):

| Offset | Length | Field | Notes |
|---:|---:|---|---|
| 0 | 1 | `0xA5` (NORMAL1) | sync |
| 1 | 1 | `0x5A` (NORMAL2) | sync |
| 2 | 1 | `0x03` | constant. Probably source addr / proto-version. Always 3. |
| 3 | 1 | `target` | destination, see `AkProtocol.Target` |
| 4–5 | 2 | `(cmdType << 13) \| cmdId` | LE 16-bit; top 3 bits = cmdType, low 13 = cmdId |
| 6 | 1 | `msgId` | message sequence id; stock app always sends `0` |
| 7–8 | 2 | `dataLength` | LE 16-bit; length of payload only |
| 9..9+L-1 | L | payload | |
| 9+L..10+L | 2 | CRC-16/CCITT-XModem | LE 16-bit; computed over bytes [2..8+L] (everything except the 2 sync bytes and the CRC itself) |

Total frame length = `11 + L`.

### CmdType values (`AkProtocol.CmdType`)

| Name | Value |
|---|---:|
| PUSH | 0 |
| SET | 1 |
| GET | 2 |
| RESPONSE_SET | 3 |
| RESPONSE_GET | 4 |

### Target values (`AkProtocol.Target`)

| Name | Value |
|---|---:|
| GIMBAL_A | 0 |
| GIMBAL_B | 1 |
| GIMBAL_C | 2 |
| KEYBOARD | 4 |
| BLUETOOTH | 6 |
| FOCUS_FOLLOWER | 7 |
| REMOTE | 8 |
| USB_HUB | 9 |
| AI_MODULE | 10 |
| VCAM | 12 |
| MULTIFUNCTION_KNOB | 13 |
| IMAGE_TRANSMISSION | 15 |
| BLE_REMOTE | 17 |
| HANDLE_BLE | 18 |

For our purposes, **target = 0 (GIMBAL_A)** for all commands.

### CRC algorithm

CCITT-XModem variant. From `cn.wandersnail.commons.util.MathUtils.calcCRC_CCITT_XModem`.
Parameters (standard XModem):
- polynomial `0x1021`
- initial value `0x0000`
- no input/output reflection
- no final XOR

Dart implementation will live in `lib/ble/crc.dart` and ship with unit
tests against fixtures derived from the frames in §9.

## 6. cmdId values (`AkProtocol.CmdId` — the on-wire values)

These are the **wire** cmdIds — what goes in bytes 4–5 of the frame.
There is also a separate higher-level enum `protocol/RequestId.java`
whose numeric values **differ**, and which is translated inside
`AkGeneralParamsRequester.requestSet/requestGet` (decompilation of
those two methods failed; the translation table is opaque from
jadx). When in doubt, use the `AkProtocol.CmdId` numbers below.

Relevant for Phase 0:

| Name | Wire cmdId | Notes |
|---|---:|---|
| `CONTROL_JOYSTICK` | 14 | **The motion primitive we ended up using.** Payload: 5 bytes `[enableRoll, courseSpeed_lo, courseSpeed_hi, pitchSpeed_lo, pitchSpeed_hi]`, speeds signed-16-bit LE, stock-app range 60–100. cmdType=PUSH. |
| `GIMBAL_STATE` | 30 | Push from gimbal with current angles. See §8. |
| `USE_MODE` | 51 | Single-byte payload, cmdType=SET. Value mapping per SCORP-C2 firmware (verified empirically): 1=PF (display "PF"), 2=PTF (display "PTF"), 3=FPV (display "FPV"). The AI-suggested mapping with LK/FFC at 3/4 does **not** match this firmware; no true Lock mode is reachable via this command on SCORP-C2. |
| `GIMBAL_RESTART` | 52 | True power-cycle restart. Avoid. |
| `FOLLOW_MODE` | 50 | High-level enum `RequestId.FOLLOW_MODE = 54` translated to wire 50. |
| `ROTATE_SPECIFIED_ANGLE` | 93 (`0x5D`) | Absolute single-axis goto. Payload: `int[2] = {axis, angle * 10}` packed as 2 × 16-bit LE = 4 bytes. Axis: 0=COURSE, 1=ROLL, 2=PITCH. Angle in decidegrees on the wire. cmdType=SET. **SCORP-C2 firmware does NOT support this** — the gimbal-properties XML's SCORP entry omits `<rotateSpecifiedAngle/>`. Used in stock app only by `CameraBalanceActivityViewModel.setPitchAngle` and `AutoMoveControllerImpl2`, which run only on capable models. |
| `ROTATE_RELATIVE_ANGLE` | 115 | Relative all-axes-at-once. Payload: `int[4] = {course, roll, pitch, 1}` (each 16-bit LE = 8 bytes), in decidegrees, with destAddress=9 (USB_HUB) rather than 0. Used only by gyroscope-sensor flow in the stock app. **Untested on SCORP-C2** but likely shares the same fate as `ROTATE_SPECIFIED_ANGLE`. |
| `TAKE_PHOTO` | 63 | For the follow-up step after Phase 0. |
| `INCEPTION_MODE` | 84 | All-axis lock with rotation parameters. More complex payload (type/speed/rotationMode); not a simple toggle. |
| `PANORAMIC_SHOOTING` | 133 | Stock-app panorama (not for our flow). |

## 7. The motion situation — resolved during Phase 0

### What we tried

1. **`ROTATE_RELATIVE_ANGLE` (cmdId 115)** — sent with our initial
   speculative 6-byte payload format. Gimbal didn't move. Later, with
   the *correct* 4-int format and `destAddress=9`, still untested but
   irrelevant for our use case (see below).
2. **`ROTATE_SPECIFIED_ANGLE` (cmdId 93)** — tested both speculative and
   correct payload format (`int[2]={axis, angle*10}`). Gimbal didn't
   move. The SCORP entry in `gimbal-properties-ble.xml` does **not**
   declare `<rotateSpecifiedAngle/>`, so the firmware genuinely doesn't
   accept this command.
3. **`USE_MODE = 3` (cmdId 51)** — attempted to put the gimbal in a
   protocol-level Lock mode. The mode value did take effect (visible in
   `GIMBAL_STATE` byte 0 bits 0–2), but for SCORP-C2 the firmware label
   for value 3 is "FPV", not Lock; there is no protocol value for
   true Lock on this gimbal. The M button on the handle cycles values
   1/2/3 only (PF/PTF/FPV); double-tap M is a no-op.

### What works

**Closed-loop joystick control**, mirroring stock-app
`SingleTimeMoveControllerImpl`:

- `CONTROL_JOYSTICK` (cmdId 14, cmdType=PUSH, 5-byte payload) is sent
  every 50 ms while a move is active.
- Speed magnitude is tapered with remaining distance (60 fast / 40
  medium / 25 slow shelves).
- Each `GIMBAL_STATE` push updates our cached orientation; arrival is
  detected when the angular delta from the start position reaches
  `target - margin`. After arrival, one final `(0,0)` joystick is sent.

### Empirical findings (SCORP-C2 firmware)

- Average angular rate across all speed shelves: **~5 °/s**. So a 20°
  move takes ~4 s, a 90° move ~18 s.
- **Pitch overshoot**: every tilt move overshoots its target by
  consistently **~1°** in the direction of motion. We pre-subtract 1°
  from the requested pitch delta (`_pitchCoastCompensation`) so the
  natural coast lands at the user-intended angle.
- **Course (yaw) does not** show the same overshoot bias — passed
  through unchanged.
- **Post-move drift**: after a move ends and we stop sending joystick
  frames, the gimbal's follow-mode controller pulls the orientation
  back toward the handle pose at ~1° per 25 s. Acceptable for typical
  panorama-shoot durations.
- No true protocol-level Lock mode exists for SCORP-C2. A
  position-hold heartbeat (sending `(0,0)` joystick at 200 ms intervals
  after a move) was tried — it caused races with corrective passes and
  was removed.

### Final motion architecture in our app

- Pan / Tilt: single closed-loop pass with tapered speed shelves +
  arrival margin + pitch coast compensation.
- Level: iterative `moveByAngle(yawDelta, pitchDelta)` driving toward
  `(0, 0)`, up to 4 passes, exits early when both axes are within 0.5°
  of zero.
- Safety: per-axis stall detection (0.2° / 500 ms) + 60 s absolute
  fallback.

This delivers ~0.5° accuracy, which is well within the working overlap
range for 90 mm + 30% panorama stitching (see SPEC-flutter-app.md
Phase 2 outline).

## 8. GIMBAL_STATE parser (current orientation)

From `GimbalStateParser.parse`. The gimbal pushes this frame
periodically. Payload (`data[]` is the AK frame's payload, i.e. the
bytes between length field and CRC):

| Offset | Length | Field | Interpretation |
|---:|---:|---|---|
| 0 | 1 | flag byte | bits 0–2 follow mode (verified — see §6 for SCORP-C2 values), bit 6 install orientation, bit 7 timelapse state, bits 3–4 vertical avail/mode |
| 1–2 | 2 | **pitch** | signed 16-bit LE, units = 0.01° (signedness confirmed empirically: tilt down → negative reading) |
| 3–4 | 2 | **roll** | signed 16-bit LE, 0.01° (signedness assumed same as pitch) |
| 5–6 | 2 | **course (yaw)** | signed 16-bit LE, 0.01° (yaw wraparound not extensively tested but `_angleDiff` in our code handles either signed [-180,180] or unsigned [0,360] correctly) |
| 7 | 1 | battery level | percent |
| 8 | 1 | flags | bit 2 standby, bit 3 selfie |
| 9 | 1 | taskType | optional |
| 10 | 1 | pitchStrength | optional |
| 11 | 1 | rollStrength | optional |
| 12 | 1 | courseStrength | optional |
| 13 | 1 | handleLevel | optional |
| 14–15 | 2 | peripherals bitfield | optional |
| 16 | 1 | followMode override | optional (overrides bits 0–2 of byte 0) |
| 17 | 1 | bleRemoteState | optional |

**Code in parser:**
```
GimbalState(followMode, courseAngle, rollAngle, pitchAngle, ...)
  followMode = data[0] & 0x07 (or data[16] if present)
  pitchAngle  = bytesToInt(data[1], data[2]) / 100.0
  rollAngle   = bytesToInt(data[3], data[4]) / 100.0
  courseAngle = bytesToInt(data[5], data[6]) / 100.0
  batLevel    = data[7]
```

**Signedness verification plan (Step 8):** point the gimbal pitch ~30°
down by hand. If the parser shows ~−30°, `bytesToInt` is signed
(two's-complement sign-extension). If it shows ~327° or some large
positive number, it's unsigned and we need to sign-extend ourselves
for pitch and roll.

**Yaw wraparound:** at this stage assume the firmware reports yaw in
the range [−180°, +180°] (signed). If during testing we see a sudden
jump from ~+359° to ~−1° as the gimbal pans through "north", the
range is actually [0°, 360°] unsigned and we'd need to unwrap. **(TBV)**

## 9. Worked example frames

### Example: get GIMBAL_STATE

Request: GET of cmdId 30 with no payload.

```
header:    A5 5A
const:     03
target:    00              (GIMBAL_A)
cmd16:     1E 40           (cmdType=2 GET in top 3 bits, cmdId=30 in low 13 bits)
                            (2 << 13) | 30 = 0x401E, LE = 1E 40
msgId:     00
length:    00 00
payload:   (none)
crc:       <2 bytes>       (CRC-16/CCITT-XModem over 03 00 1E 40 00 00 00)
```

Total frame: `A5 5A 03 00 1E 40 00 00 00 <crc-lo> <crc-hi>` — 11 bytes.

The CRC value is to be computed in the Dart codec; we'll compare
against an actual TX from the stock app once we have a sniff, or just
trust the algorithm.

### Example: GIMBAL_STATE response/push

A typical RX push would be (illustrative, exact bytes vary):

```
A5 5A 03 ?? <cmd16 lo hi> <msgId> <len lo hi>
       payload[0..N]:
           flags
           pitch_lo pitch_hi roll_lo roll_hi course_lo course_hi
           bat ...
       crc_lo crc_hi
```

Where the `cmd16` would be `(0 << 13) | 30 = 0x001E` for a PUSH, or
`(4 << 13) | 30 = 0x801E` for RESPONSE_GET, depending on how the
firmware reports it.

### Example: CONTROL_JOYSTICK (the motion primitive we use)

Payload: 5 bytes `[enableRoll, course_lo, course_hi, pitch_lo, pitch_hi]`
where speeds are signed 16-bit LE. cmdType = PUSH (0).

```
A5 5A 03 00 0E 00 00 05 00 <enableRoll> <course_lo> <course_hi> <pitch_lo> <pitch_hi> <crc_lo> <crc_hi>
```

cmd16 = `(0 << 13) | 14 = 0x000E`, LE = `0E 00`.

### Example: SET USE_MODE (cmdId 51) with value=3 (SCORP-C2 "FPV")

Payload: 1 byte `[3]`. cmdType = SET (1).

```
A5 5A 03 00 33 20 00 01 00 03 <crc_lo> <crc_hi>
```

cmd16 = `(1 << 13) | 51 = 0x2033`, LE = `33 20`. Sent at the start of
each `moveByAngle` call by our app (though on SCORP-C2 the resulting
mode is "FPV" rather than a true Lock — see §6).

## 10. Things deliberately NOT covered here

- The `BeforeAkProtocol` (older protocol). The SCORP series uses AK
  (`protocolType=2`); we ignore Before-Ak entirely.
- Full enumeration of `AkProtocol.CmdId` values. See the source file
  if needed; only the ones used in Phase 0 are listed in §6.
- OTA / firmware update commands.
- Camera-side control (USB, hot-shoe, PTP) — we use the gimbal's
  shutter cable.
- The mapping between `RequestId.java` (high-level) and
  `AkProtocol.CmdId` (wire). Since we'll build our own commands by
  cmdId directly, we don't need it.
