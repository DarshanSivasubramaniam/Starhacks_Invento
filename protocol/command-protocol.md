# Command Protocol

## Purpose

This document defines the first shared command packet exchanged between the
iPhone compute stack and the ESP32 execution layer.

The initial version uses JSON for readability, debugging, and easier iteration.
It can be replaced with a more compact transport format later without changing
the logical fields.

## Packet Fields

| Field | Type | Description |
| --- | --- | --- |
| `mode` | string enum | High-level operating mode such as `idle`, `awareness`, or `object_nav`. |
| `direction` | string enum | Intended body-relative direction such as `left`, `front`, `right`, `back`, or `stop`. |
| `intensity` | integer | Haptic strength from `0` to `255`. |
| `pattern` | string enum | Haptic pattern such as `steady`, `slow_pulse`, or `fast_pulse`. |
| `priority` | integer | Relative command priority used by downstream arbitration logic. |
| `ttlMs` | integer | Time-to-live in milliseconds. Commands are stale after this duration. |
| `confidence` | float | Confidence score from `0.0` to `1.0`. |
| `seq` | integer | Monotonic sequence number for ordering and debug visibility. |

## JSON Example

```json
{
  "mode": "object_nav",
  "direction": "left",
  "intensity": 180,
  "pattern": "steady",
  "priority": 2,
  "ttlMs": 300,
  "confidence": 0.84,
  "seq": 15
}
```

## Initial Validation Rules

- All fields are required in the first working version.
- `intensity` must stay within `0...255`.
- `confidence` must stay within `0.0...1.0`.
- `ttlMs` must be greater than `0`.
- `seq` should increase for each newly emitted command.
- Unknown enum values should be treated as invalid by receivers.

## Versioning Note

This first protocol revision does not add an explicit `version` field yet. If
the packet shape changes, the next protocol revision should add versioning
before BLE interoperability is treated as stable.
