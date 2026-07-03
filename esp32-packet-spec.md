# ESP32 BLE Packet Spec

This document describes the JSON packets the ESP32 in `esp32-firmware/VisionVest/VisionVest.ino` currently expects to receive over BLE, and when each packet should be sent.

## Transport

- BLE device name: `VisionVest`
- BLE service UUID: `7B7E1000-7C6B-4B8F-9E2A-6B5F4F0A1000`
- BLE command characteristic UUID: `7B7E1001-7C6B-4B8F-9E2A-6B5F4F0A1000`
- One BLE write should contain one complete JSON object

## Required JSON Shape

Every packet must include all of these fields:

```json
{
  "mode": "awareness",
  "direction": "none",
  "intensity": 0,
  "pattern": "none",
  "priority": 1,
  "ttlMs": 500,
  "confidence": 0,
  "distance": null,
  "seq": 1
}
```

## Field Rules

- `mode`: required string
- `direction`: required string
- `intensity`: required integer from `0` to `255`
- `pattern`: required string
- `priority`: required integer from `0` to `3`
- `ttlMs`: required integer from `1` to `1000`
- `confidence`: required number from `0.0` to `1.0`
- `distance`: required, either `null` or a number `>= 0`
- `seq`: required integer from `0` to `2147483647`

## Valid Values

### `mode`

The ESP32 currently accepts only these mode strings:

- `manual`
- `awareness`
- `object_nav`
- `find_search`
- `find_scan_complete`
- `gps_nav`

Important:

- `gps` is **not** accepted
- use `gps_nav`

### `direction`

The ESP32 currently accepts:

- `left`
- `front`
- `right`
- `back`
- `front-left`
- `front_left`
- `front-right`
- `front_right`
- `back-left`
- `back_left`
- `back-right`
- `back_right`
- `none`

Important:

- in `find_search` and `object_nav`, diagonal directions are normalized by the ESP32:
  - `front-left` and `back-left` become `left`
  - `front-right` and `back-right` become `right`

### `pattern`

The ESP32 currently accepts:

- `steady`
- `slow_pulse`
- `fast_pulse`
- `none`

## Sequence Rule

- `seq` must increase over time
- the ESP32 rejects a packet if its `seq` is exactly the same as the last accepted packet in the current BLE session
- on BLE disconnect, the ESP32 forgets the previous `seq`

Repeated retransmit exception:

- if the phone sends the exact same packet again with the same `seq`, the ESP32 now ignores the duplicate safely instead of treating it as a new command
- this means repeated identical mode-switch packets are harmless

## Packet Types and When to Send Them

## 1. Mode switch only packet

Send this immediately when the user switches app mode, even if you do not yet have a direction to vibrate.

The ESP32 treats a packet as a mode switch only packet when:

- `direction` is `none`
- `intensity` is `0`
- `pattern` is `none`

Behavior:

- updates `gCurrentMode`
- clears any active haptic command
- does not vibrate motors by itself

Example: switch into Awareness

```json
{
  "mode": "awareness",
  "direction": "none",
  "intensity": 0,
  "pattern": "none",
  "priority": 1,
  "ttlMs": 500,
  "confidence": 0,
  "distance": null,
  "seq": 1
}
```

Example: switch into Find Search

```json
{
  "mode": "find_search",
  "direction": "none",
  "intensity": 0,
  "pattern": "none",
  "priority": 1,
  "ttlMs": 500,
  "confidence": 0,
  "distance": null,
  "seq": 2
}
```

Example: switch into GPS Nav

```json
{
  "mode": "gps_nav",
  "direction": "none",
  "intensity": 0,
  "pattern": "none",
  "priority": 1,
  "ttlMs": 500,
  "confidence": 1,
  "distance": null,
  "seq": 3
}
```

## 2. Awareness mode packet

Send the Awareness mode switch packet when the user enters awareness mode.

Behavior on ESP32:

- mode becomes `awareness`
- ultrasonics are enabled
- ultrasonic hazard vibrations may run
- phone-guided vibration does not happen unless you later send a non-neutral awareness packet

Recommended usage:

- usually just send the neutral mode switch packet above

## 3. Find Search packet

Send this when the user is in Find and Go search mode and the vest should guide turning.

Behavior on ESP32:

- mode becomes `find_search`
- ultrasonics are disabled
- left and right should be used as turn cues
- diagonals are collapsed to left or right

Example: tell user to turn left

```json
{
  "mode": "find_search",
  "direction": "left",
  "intensity": 110,
  "pattern": "slow_pulse",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 0.7,
  "distance": null,
  "seq": 10
}
```

Recommended meanings in Find Search:

- `left`: turn left
- `right`: turn right
- `front`: keep moving forward
- `back`: turn around
- `none`: no turn cue

## 4. Find Scan Complete packet

Send this once when the 360 scan is finished.

Behavior on ESP32:

- triggers a 2-second all-motor buzz
- does not permanently change the current mode
- should be treated as a one-shot event

Example:

```json
{
  "mode": "find_scan_complete",
  "direction": "none",
  "intensity": 0,
  "pattern": "none",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 0,
  "distance": null,
  "seq": 11
}
```

## 5. Object Nav packet

Send this when the app has a target lock and wants to actively guide the user toward the object.

Behavior on ESP32:

- mode becomes `object_nav`
- ultrasonics are disabled
- diagonal directions are normalized to left or right

Example:

```json
{
  "mode": "object_nav",
  "direction": "front",
  "intensity": 150,
  "pattern": "steady",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 0.9,
  "distance": 1.8,
  "seq": 12
}
```

Use `distance` when you have a real estimated target distance. Otherwise use `null`.

## 6. GPS Nav packet

Send this when the user is in GPS navigation mode.

Behavior on ESP32:

- mode becomes `gps_nav`
- ultrasonics are disabled
- phone-guided haptics can be sent with normal directional packets

Example neutral entry packet:

```json
{
  "mode": "gps_nav",
  "direction": "none",
  "intensity": 0,
  "pattern": "none",
  "priority": 1,
  "ttlMs": 500,
  "confidence": 1,
  "distance": null,
  "seq": 20
}
```

Example turn-right guidance packet:

```json
{
  "mode": "gps_nav",
  "direction": "right",
  "intensity": 140,
  "pattern": "slow_pulse",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 0.8,
  "distance": null,
  "seq": 21
}
```

## 7. Manual packet

The ESP32 accepts `manual`, but there is no special manual-only behavior in the current firmware beyond setting mode and using the packet as a normal phone haptic command.

Example:

```json
{
  "mode": "manual",
  "direction": "front",
  "intensity": 255,
  "pattern": "steady",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 1,
  "distance": null,
  "seq": 30
}
```

## Timing Expectations

- send a neutral mode switch packet immediately when the user changes modes
- if the phone sends that same mode-switch packet multiple times for reliability, that is okay
- send active guidance packets repeatedly while guidance is ongoing
- keep `ttlMs` short enough that stale cues expire quickly
- a common good range is `300` to `500` ms

## Rejection Conditions

The ESP32 will reject a packet if:

- JSON is malformed
- any required field is missing
- any field has the wrong type
- `mode` is unknown
- `direction` is unknown
- `pattern` is unknown
- `intensity` is outside `0..255`
- `priority` is outside `0..3`
- `ttlMs` is outside `1..1000`
- `confidence` is outside `0.0..1.0`
- `distance` is negative
- `seq` duplicates the last accepted `seq`

## Current ESP32 Behavior Summary

- ultrasonics are enabled only in `awareness`
- ultrasonics are disabled in:
  - `manual`
  - `object_nav`
  - `find_search`
  - `find_scan_complete`
  - `gps_nav`
- `find_scan_complete` causes a 2-second all-motor buzz
- when any motor is active, the ESP32 currently drives motors at full PWM
- current ultrasonic thresholds are:
  - `DANGER`: `<= 80 cm`
  - `CAUTION`: `> 80 cm` and `<= 130 cm`
  - `SAFE`: `> 130 cm`

## Telemetry Mode Group

The ESP32 telemetry now exposes both:

- `mode`: the raw internal mode such as `find_search` or `object_nav`
- `modeGroup`: a higher-level grouped mode for the dashboard

Current grouped values:

- `manual`
- `awareness`
- `find_and_go`
- `gps_nav`

`modeGroup` becomes `find_and_go` whenever the vest is in:

- `find_search`
- `object_nav`
- the `find_scan_complete` effect window

Telemetry also includes:

- `findAndGoActive`: `true` when Find and Go is active
