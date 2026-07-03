# iPhone Packet Handoff

This file lists the BLE packets the iPhone side should send so the ESP32 vest and dashboard stay in sync during mode changes, Find & Go search, scan completion, and navigation.

All packets use the existing JSON shape:

```json
{
  "mode": "awareness",
  "direction": "front",
  "intensity": 180,
  "pattern": "slow_pulse",
  "priority": 2,
  "ttlMs": 300,
  "confidence": 0.82,
  "distance": 1.6,
  "seq": 14
}
```

## Important Rules

- `seq` must always increase.
- `ttlMs` must stay between `1` and `1000`.
- `distance` can be `null`.
- The ESP32 currently accepts these `mode` strings:
  - `manual`
  - `awareness`
  - `object_nav`
  - `find_search`
  - `find_scan_complete`
  - `gps_nav`
- The ESP32 does **not** currently accept `gps`. If the iPhone wants GPS mode to work, it should send `gps_nav`.

## Direction Rules For Find & Go

For Find & Go, only use these directions:

- `left`
- `right`
- `front`
- `back`
- `none`

Do **not** send diagonal directions like:

- `front_left`
- `front_right`
- `back_left`
- `back_right`

For Find & Go:

- `left` means turn left
- `right` means turn right
- `front` means move forward
- `back` means turn around / reverse direction

The firmware now collapses any old diagonal Find & Go directions into plain `left` or `right`, but the iPhone side should send only cardinal directions going forward.

## Why These Extra Packets Are Needed

Right now, switching modes on the iPhone does not always send an immediate BLE packet. That means:

- the vest may keep the old mode
- the dashboard may keep showing the old mode
- Find & Go may still look like `awareness` until the first active directional command appears

The fix is to send a neutral "mode entry" packet immediately when the app changes into a new mode, even if there is no active direction yet.

## Packets To Add

### 1. Enter Find & Go Search

Send this immediately when the app switches into Find & Go search/scanning mode.

Purpose:

- sets the vest mode to `find_search`
- updates the dashboard immediately
- does not activate any motors yet

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
  "seq": 100
}
```

### 2. Find & Go Search Direction Guidance

Send these continuously during the 360 scan or during remembered-bearing search when the app wants the user to turn.

Example left turn:

```json
{
  "mode": "find_search",
  "direction": "left",
  "intensity": 110,
  "pattern": "slow_pulse",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 0,
  "distance": null,
  "seq": 101
}
```

Example front-left turn:
Example right turn:

```json
{
  "mode": "find_search",
  "direction": "right",
  "intensity": 110,
  "pattern": "slow_pulse",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 0,
  "distance": null,
  "seq": 102
}
```

Purpose:

- tells the vest which way to turn during Find & Go
- keeps the dashboard in `find_search`
- uses motor direction cues instead of ultrasonic awareness

### 3. Find & Go 360 Scan Complete

Send this once when the user finishes the full 360 scan and reaches the original angle.

Purpose:

- triggers the 2-second all-motor buzz on the ESP32
- does **not** replace the normal Find & Go mode permanently

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
  "seq": 103
}
```

### 4. Enter Object Navigation

Send this immediately when the app transitions from search into target-acquired navigation.

Purpose:

- sets the vest mode to `object_nav`
- updates the dashboard immediately
- tells the user where the acquired object is

Example:

```json
{
  "mode": "object_nav",
  "direction": "right",
  "intensity": 180,
  "pattern": "slow_pulse",
  "priority": 2,
  "ttlMs": 300,
  "confidence": 0.82,
  "distance": 1.6,
  "seq": 104
}
```

If the app enters `object_nav` but has no directional cue yet, it should still send a neutral entry packet like this:

```json
{
  "mode": "object_nav",
  "direction": "none",
  "intensity": 0,
  "pattern": "none",
  "priority": 1,
  "ttlMs": 500,
  "confidence": 0,
  "distance": null,
  "seq": 105
}
```

### 5. Arrival / Stop On Target

If the target is reached and the app wants to signal arrival, keep using `object_nav` but send a stop-style packet.

```json
{
  "mode": "object_nav",
  "direction": "none",
  "intensity": 255,
  "pattern": "fast_pulse",
  "priority": 3,
  "ttlMs": 300,
  "confidence": 0.9,
  "distance": 0.8,
  "seq": 106
}
```

### 6. Enter Awareness

If the app switches back into awareness, send an immediate awareness packet even if there is no stable obstacle yet.

Purpose:

- updates vest mode back to `awareness`
- updates the dashboard immediately

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
  "seq": 107
}
```

### 7. Enter GPS

If GPS mode is used, the iPhone should send `gps_nav`, not `gps`.

Use this when switching into GPS mode:

```json
{
  "mode": "gps_nav",
  "direction": "front_right",
  "intensity": 150,
  "pattern": "slow_pulse",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 1,
  "distance": 42.0,
  "seq": 108
}
```

If the app enters GPS mode with no active bearing yet, send this neutral entry packet:

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
  "seq": 109
}
```

## Minimum Required Additions

If the team only has time for the smallest fix, add these first:

1. Immediate `find_search` neutral entry packet when Find & Go starts
2. Existing directional `find_search` packets during scan/search
3. Existing one-shot `find_scan_complete` packet
4. Immediate `object_nav` packet when target lock/navigation begins

Those four changes should make:

- the vest leave `awareness` immediately
- the dashboard show `find_search` correctly
- the 360 scan completion buzz work
- Find & Go directional turning cues keep working after mode entry

## Recommended Find & Go Flow

1. User enters Find & Go
   - send neutral `find_search`
2. User performs 360 scan
   - send directional `find_search` packets as needed
3. Scan completes
   - send one `find_scan_complete`
4. If target visible and stable
   - send `object_nav`
5. If target lost but remembered bearing exists
   - continue sending directional `find_search`
