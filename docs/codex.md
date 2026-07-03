# Codex Handoff

This document is a practical handoff for another Codex session working on **VisionVest**.

It is meant to answer three questions quickly:

1. What is this project?
2. Where is the real code?
3. What project-specific decisions and pitfalls should a new agent know before changing anything?

## Project Summary

VisionVest is a wearable assistive navigation system with three major pieces:

- **iPhone app**
  Perception, decision-making, BLE central, GPS, gesture input, voice target input
- **ESP32 firmware**
  BLE peripheral, motor control, ultrasonic awareness, local safety, telemetry
- **Dashboard**
  React/Vite web UI that reads live telemetry from the ESP32 over Wi-Fi

The product name is now **VisionVest**.

Important:

- older docs/code/history may still mention `NavVest`
- the project was recently renamed from `NavVest` / `ChudSense`
- future work should prefer `VisionVest` naming everywhere

## Current Repo Layout

These are the main directories that matter right now:

- `VisionVest/`
  Active iPhone app source
- `VisionVest.xcodeproj/`
  Xcode project
- `esp32-firmware/VisionVest/VisionVest.ino`
  Main ESP32 firmware
- `dashboard/`
  Judge/demo dashboard
- `VisionVestBleConnectionTest/`
  BLE connectivity test sketch
- `VisionVestBlinkTest/`
  Simple LED test sketch
- `VisionVestIphoneOnly/`
  iPhone-only firmware test sketch
- `VisionVestMotorTest/`
  Motor test sketch
- `VisionVestUltrasonicTest/`
  Ultrasonic test sketch
- `esp32-packet-spec.md`
  Source of truth for what BLE packets the ESP32 expects
- `iphone-packet-handoff.md`
  iPhone-side send recommendations
- `BLE_PACKET_FLOW.md`
  Detailed packet flow / mode behavior notes
- `docs/system-overview.md`
  High-level architecture notes

## Main Files To Read First

If another agent needs to get oriented fast, these are the best starting points:

1. `README.md`
2. `esp32-firmware/VisionVest/VisionVest.ino`
3. `esp32-packet-spec.md`
4. `BLE_PACKET_FLOW.md`
5. `VisionVest/ContentView.swift`
6. `VisionVest/BLEVestManager.swift`
7. `VisionVest/VestMessage.swift`
8. `dashboard/src/App.tsx`
9. `dashboard/src/wifi.ts`

## iPhone App Status

The iPhone app is the higher-level intelligence layer.

Current responsibilities include:

- live camera capture
- object detection
- target selection
- direction estimation
- smoothing
- BLE command generation
- mode switching
- Find & Go target flow
- GPS navigation scaffolding
- gesture input
- voice target capture

Important app files:

- `VisionVest/AppCoordinator.swift`
- `VisionVest/ContentView.swift`
- `VisionVest/BLEVestManager.swift`
- `VisionVest/VestMessage.swift`
- `VisionVest/ObjectDetectionManager.swift`
- `VisionVest/TargetSelector.swift`
- `VisionVest/DirectionEstimator.swift`
- `VisionVest/DecisionSmoother.swift`
- `VisionVest/MotionManager.swift`
- `VisionVest/GPSNavigationManager.swift`
- `VisionVest/HandGestureModeSwitchManager.swift`
- `VisionVest/VoiceTargetInputManager.swift`

## ESP32 Firmware Status

Main firmware file:

- `esp32-firmware/VisionVest/VisionVest.ino`

Current firmware responsibilities:

- receive BLE JSON commands
- validate packet fields
- support mode-switch-only packets
- normalize diagonal directions in Find & Go / object nav
- drive motors
- run ultrasonic awareness sensing
- expose telemetry over Wi-Fi
- support a grouped `find_and_go` telemetry state

### Current BLE identity

- device name: `VisionVest`
- service UUID: `7B7E1000-7C6B-4B8F-9E2A-6B5F4F0A1000`
- command characteristic UUID: `7B7E1001-7C6B-4B8F-9E2A-6B5F4F0A1000`

### Current firmware behavior that matters

- ultrasonics are enabled **only** in `awareness`
- ultrasonics are disabled in:
  - `manual`
  - `find_search`
  - `object_nav`
  - `find_scan_complete`
  - `gps_nav`
- `find_scan_complete` triggers a 2-second all-motor buzz
- all active motors currently run at full PWM
- mode-switch-only packets are:
  - `direction = none`
  - `intensity = 0`
  - `pattern = none`
- duplicate retransmits of the exact same packet with the same `seq` are safely ignored

### Current ultrasonic thresholds

- `DANGER`: `<= 80 cm`
- `CAUTION`: `> 80 cm` and `<= 130 cm`
- `SAFE`: `> 130 cm`

## Dashboard Status

The dashboard reads telemetry from the ESP32 over Wi-Fi.

Important files:

- `dashboard/src/App.tsx`
- `dashboard/src/wifi.ts`
- `dashboard/src/types.ts`

Important behavior:

- dashboard uses telemetry endpoint:
  - `http://192.168.4.1/telemetry`
- dashboard now displays grouped `modeGroup`
- `find_search`, `object_nav`, and scan-complete effect are grouped as:
  - `find_and_go`

Known good verification:

- `npm run build` in `dashboard/` passes

## Packet / Mode Contract

The ESP32 expects JSON BLE packets with:

- `mode`
- `direction`
- `intensity`
- `pattern`
- `priority`
- `ttlMs`
- `confidence`
- `distance`
- `seq`

Important accepted mode strings:

- `manual`
- `awareness`
- `find_search`
- `find_scan_complete`
- `object_nav`
- `gps_nav`

Important:

- `gps` is **not** accepted
- use `gps_nav`

### Find & Go behavior

Find & Go is not represented as a single raw mode in firmware.

Instead, it spans:

- `find_search`
- `object_nav`
- `find_scan_complete` effect window

Telemetry now exposes:

- `mode`
  raw firmware mode
- `modeGroup`
  grouped mode for UI/debugging
- `findAndGoActive`
  boolean convenience flag

This was added because the user was having trouble seeing when the vest had entered Find & Go.

## Important Project Decisions

These are deliberate decisions that should not be accidentally undone:

### 1. Find & Go should be shown as one grouped state

The dashboard should present Find & Go clearly, even though the firmware internally moves between `find_search` and `object_nav`.

### 2. Ultrasonics only run in awareness

This was explicitly requested and implemented.

Do not re-enable ultrasonic behavior in Find & Go or GPS unless the user asks.

### 3. Cardinal guidance is preferred in Find & Go

For Find & Go and object navigation:

- left means turn left
- right means turn right
- front means go forward
- back means turn around / reverse

Diagonal directions are normalized to left/right in firmware.

### 4. Mode-entry packets matter

The iPhone should send neutral entry packets on mode change so the firmware can change state immediately even without an active cue.

### 5. The project name is VisionVest

If a future agent sees `NavVest`, it is legacy naming unless there is a technical reason to preserve it.

## Known Gotchas

### 1. Firmware compile verification is not available locally

`arduino-cli` is not installed in this environment.

That means:

- firmware code can be edited
- firmware logic can be inspected
- but local compile validation was not possible in these sessions

Any firmware changes should be described honestly as uncompiled unless the environment changes.

### 2. Dashboard builds, firmware does not compile locally

This is a recurring pattern:

- dashboard: verifiable with `npm run build`
- ESP32 firmware: not verifiable locally right now

### 3. Renaming collision already happened once

There is already a top-level `VisionVest/` directory for the iPhone app.

Because of that, the ESP32 firmware lives at:

- `esp32-firmware/VisionVest/VisionVest.ino`

That structure is intentional and avoids colliding with the iPhone app folder.

### 4. Old docs may still mention earlier names

Some older notes or generated docs may still refer to:

- `NavVest`
- `ChudSense`

New work should use `VisionVest`.

## Recommended Workflow For Another Codex Session

When touching the project, a good order is:

1. Read `README.md`
2. Read `esp32-packet-spec.md`
3. Read the specific code area being changed
4. Verify whether the change affects:
   - iPhone app
   - firmware
   - dashboard
   - packet contract
5. If packet semantics change:
   - update `esp32-packet-spec.md`
   - update `iphone-packet-handoff.md`
   - update `README.md` if user-facing behavior changed
6. If dashboard changes:
   - run `npm run build`

## If The Next Agent Is Asked About Demo Priorities

The user explicitly preferred:

- **Find & Go first** in demos

Reason:

- it shows the AI/perception side more clearly than awareness mode

## If The Next Agent Is Asked About Project Messaging

The user has already said:

- the project should be referred to as **VisionVest**

There is also a prepared Devpost-style writeup in the repo:

- `devpost-about-project.md`

## Quick State Snapshot

At the time of this handoff:

- project naming has been shifted to `VisionVest`
- README has been rewritten as a polished whole-project document
- firmware/dashboard packet flow has been aligned around grouped Find & Go state
- dashboard build is passing
- firmware compile still has not been locally verified due to missing `arduino-cli`

## Best One-Sentence Summary

VisionVest is a full-stack wearable assistive navigation system where the iPhone interprets the world, the ESP32 turns those decisions into haptic guidance, and the dashboard exposes the vest’s live internal state for debugging and demos.
