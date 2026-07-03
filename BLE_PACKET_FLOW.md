# BLE Packet Flow

This document describes the current JSON packets the iPhone app sends to the ESP32 vest.

## Send Timing

The app sends the current active command over BLE on a timer.

- BLE timer interval: `0.10s`
- BLE minimum send interval: `0.12s`
- Effective send rate: about one packet every `120ms`

If there is no active command, no packet is sent.

## Shared Packet Format

All command packets use this structure:

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

Fields:

- `mode`: source/type of command.
- `direction`: one of `front`, `back`, `left`, `right`, or `none`.
- `intensity`: motor strength, typically `0...255`.
- `pattern`: vibration pattern, such as `steady`, `slow_pulse`, `fast_pulse`, or `none`.
- `priority`: command priority. Higher values should override lower values on the ESP32.
- `ttlMs`: command time-to-live in milliseconds.
- `confidence`: detector confidence, or `1.0` for GPS/manual commands.
- `distance`: distance in meters if available, otherwise `null`.
- `seq`: increasing sequence number assigned by the iPhone BLE send path.

## Mode Values

Current `mode` values:

- `manual`: manual/test command.
- `awareness`: normal obstacle awareness.
- `find_search`: Find & Go scan/search/bearing guidance.
- `find_scan_complete`: one-time packet after Find & Go 360 scan completes.
- `object_nav`: object navigation toward a selected target, also used for local camera safety override.
- `gps_nav`: GPS bearing guidance.

## Mode Switching

Switching modes sends one neutral mode-entry packet immediately.

If BLE is not connected yet, that one mode-entry packet stays pending and is sent once when the BLE timer can deliver it.

After that, the next active command uses the packet type for the new mode:

- Awareness sends `awareness` packets once a stable obstacle target exists.
- Find & Go sends `find_search`, `find_scan_complete`, or `object_nav` depending on state.
- GPS sends `gps_nav` packets unless local camera safety has higher priority.
- GPS local camera safety override sends `object_nav`.

## Find & Go Flow

### 1. Enter Find & Go

The user switches to Find & Go using the UI or hand gesture.

The app sends a neutral `find_search` mode-entry packet:

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
  "seq": 1
}
```

### 2. Start Target Voice Capture

The user shows `4` fingers with the left hand, pointing right.

Phone behavior:

- Vibrates once locally.
- Starts voice target recording.

BLE behavior:

- No BLE packet is sent for recording start.

### 3. Finish Target Voice Capture

The user shows `4` fingers again.

Phone behavior:

- Vibrates once locally.
- Stops voice target recording.
- If a target was recognized, buzzes twice to tell the user to start the 360 spin.

BLE behavior:

- No BLE packet is sent for recording finish.

### 4. During 360 Scan

Once a target exists and the scan is not complete, the app sends `find_search` packets.

Example:

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
  "seq": 12
}
```

During the scan, the app may see the requested object and remember its best bearing/position. It does not start object navigation until the full 360 scan is complete.

If a closer/clearer matching object appears later in the scan, the remembered target can be replaced.

In Find & Go search, `left` means turn left and `right` means turn right.

### 5. 360 Scan Complete

When the scan finishes, the app sends one transition packet:

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
  "seq": 13
}
```

This packet is sent once per Find & Go scan.

### 6. Navigation After Scan

After `find_scan_complete`, normal navigation/search packets begin.

If the target is visible and stable, the app sends `object_nav`:

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
  "seq": 14
}
```

If the target is close enough to count as arrival/stop, the app sends:

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
  "seq": 15
}
```

If the target is not visible after the scan, but the app has a remembered bearing, it sends `find_search` bearing guidance:

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
  "seq": 16
}
```

### 7. Restart Find & Go Target Capture

At any point during Find & Go, showing `4` fingers again can restart the target capture flow.

## Awareness Example

```json
{
  "mode": "awareness",
  "direction": "left",
  "intensity": 120,
  "pattern": "steady",
  "priority": 2,
  "ttlMs": 300,
  "confidence": 0.73,
  "distance": 2.7,
  "seq": 20
}
```

## GPS Example

```json
{
  "mode": "gps_nav",
  "direction": "right",
  "intensity": 150,
  "pattern": "slow_pulse",
  "priority": 1,
  "ttlMs": 300,
  "confidence": 1,
  "distance": 42.0,
  "seq": 21
}
```

## GPS Safety Override

GPS mode can be overridden by local camera safety.

If the camera sees a higher-priority nearby obstacle while GPS is active, the app sends `object_nav` instead of `gps_nav`.

Example:

```json
{
  "mode": "object_nav",
  "direction": "front",
  "intensity": 255,
  "pattern": "fast_pulse",
  "priority": 3,
  "ttlMs": 300,
  "confidence": 0.88,
  "distance": 0.7,
  "seq": 22
}
```
