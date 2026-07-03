# VisionVest

VisionVest is a wearable assistive navigation system that combines **iPhone-based perception** with **ESP32-powered haptic feedback** to help users understand nearby space through touch.

Instead of relying only on spoken directions, VisionVest communicates with directional vibration cues around the body. The iPhone interprets the environment using the camera, motion sensors, voice input, gestures, and GPS, while the ESP32 executes those decisions in real time and provides local safety behavior through onboard ultrasonic sensing.

## Why VisionVest

Many navigation tools for blind and low-vision users depend heavily on audio. Audio is useful, but it also competes with the real-world sounds people already rely on, like traffic, voices, footsteps, and crosswalk signals.

VisionVest explores a different interaction model:

- **Touch for guidance**
- **Vision and sensing for perception**
- **Wearable hardware for immediate feedback**

The result is a system that feels more physical, more intuitive, and less disruptive than constant spoken output.

## What The System Does

At a high level, VisionVest turns perception into directional haptics.

The system supports:

- **Awareness Mode**
  Passive obstacle awareness with directional haptic alerts
- **Find & Go**
  Search for a chosen object, complete a 360 scan, then guide the user toward it
- **Object Navigation**
  Continue haptic guidance once a target is actively tracked
- **GPS Navigation**
  Provide directional guidance toward a saved destination

At runtime, the flow looks like this:

1. The iPhone captures live sensor data.
2. The app detects objects, selects targets, and estimates relative direction.
3. The phone sends compact BLE commands to the vest.
4. The ESP32 interprets those commands and drives the correct motors.
5. In awareness mode, the vest also uses onboard ultrasonic sensors for local obstacle alerts.
6. A live dashboard mirrors the vest state over Wi-Fi for demos and debugging.

## System Architecture

### iPhone App

The iPhone is the perception and decision-making layer. It is responsible for:

- Live camera capture
- Object detection and target selection
- Direction estimation
- 360-degree scan tracking for Find & Go
- Hand-gesture mode switching
- Voice-based target capture
- GPS-based navigation cues
- BLE packet generation and transmission

### ESP32 Firmware

The ESP32 is the real-time execution and local safety layer. It is responsible for:

- Receiving BLE commands from the iPhone
- Parsing the project's JSON command protocol
- Managing haptic output modes and motor control
- Running ultrasonic awareness sensing
- Applying mode-specific behavior
- Serving live telemetry over Wi-Fi for the dashboard

### Dashboard

The dashboard is a React + Vite web app that connects to the ESP32's Wi-Fi telemetry endpoint. It is designed for:

- Judge demos
- Live observability
- Hardware debugging
- Verifying mode transitions and output behavior

## Hardware Overview

The wearable hardware is built around an **ESP32-S3** and includes:

- Four directional DC vibration motors
- Three ultrasonic sensors for back, left, and right awareness
- A NeoPixel status indicator
- BLE communication with the iPhone
- Wi-Fi telemetry for the dashboard

This split is intentional: the iPhone handles heavier perception and navigation logic, while the ESP32 handles fast hardware response and safety-critical local behavior.

## Software Overview

The active iPhone app lives in the `VisionVest/` Xcode source folder and `VisionVest.xcodeproj`.

Important modules include:

- `AppCoordinator.swift`
  Manages app mode and high-level state
- `ContentView.swift`
  Main app UI and operator flow
- `BLEVestManager.swift`
  Handles BLE discovery, connection, and command sending
- `VestMessage.swift`
  Defines the outgoing BLE packet structure
- `CameraManager.swift`
  Owns camera capture and frame sampling
- `FrameProcessor.swift`
  Bridges camera frames into the perception pipeline
- `ObjectDetectionManager.swift`
  Runs detection and publishes navigation state
- `TargetSelector.swift`
  Chooses the active target
- `DirectionEstimator.swift`
  Converts target position into body-relative guidance
- `DecisionSmoother.swift`
  Reduces flicker in direction decisions
- `MotionManager.swift`
  Tracks 360-degree rotation for Find & Go
- `GPSNavigationManager.swift`
  Produces GPS guidance output
- `HandGestureModeSwitchManager.swift`
  Supports gesture-driven mode switching
- `VoiceTargetInputManager.swift`
  Captures the spoken Find & Go target

## Firmware Overview

The active ESP32 firmware lives at:

- [esp32-firmware/VisionVest/VisionVest.ino](./esp32-firmware/VisionVest/VisionVest.ino)

The firmware currently supports:

- BLE command reception
- Mode switching through neutral entry packets
- Full-power motor driving when active
- Awareness-mode ultrasonic sensing
- Find & Go scan-complete haptic event
- Wi-Fi telemetry for the dashboard
- Grouped telemetry state for `find_and_go`

Supporting test sketches are included in:

- `VisionVestBleConnectionTest/`
- `VisionVestBlinkTest/`
- `VisionVestIphoneOnly/`
- `VisionVestMotorTest/`
- `VisionVestUltrasonicTest/`

## Modes

### Awareness

Used for passive obstacle awareness.

- The vest can warn about nearby obstacles using left, right, and back ultrasonic sensors.
- The phone can also provide awareness-style guidance from its perception stack.
- Ultrasonic sensing is enabled only in this mode.

### Find & Go

Used for AI-assisted target search.

Typical flow:

1. The user enters Find & Go.
2. The app sends a neutral `find_search` mode-entry packet.
3. The user provides a target object.
4. The app performs a 360-degree scan.
5. The vest signals scan completion with a full buzz.
6. The app transitions into directional search or object navigation.

This is the most AI-heavy part of the project and the most important mode during demos.

### Object Navigation

Used once a target has been identified and the system is actively guiding the user toward it.

- Directional cues are sent through BLE
- Left and right cues map directly to turning guidance
- The vest follows phone guidance rather than ultrasonic behavior

### GPS Navigation

Used for destination-based navigation.

- The phone computes heading/location guidance
- The vest renders that guidance as directional haptic cues
- The BLE mode used by the firmware is `gps_nav`

## BLE Command Protocol

The phone sends one JSON packet per BLE write.

Typical packet:

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

Key ideas in the protocol:

- Every packet includes mode, direction, pattern, intensity, priority, TTL, confidence, distance, and sequence number
- Neutral mode-entry packets are used so the ESP32 can switch behavior immediately
- The firmware tolerates repeated identical packets for reliable mode switching
- `gps_nav` is used instead of `gps`

Detailed documentation:

- [BLE_PACKET_FLOW.md](./BLE_PACKET_FLOW.md)
- [esp32-packet-spec.md](./esp32-packet-spec.md)
- [iphone-packet-handoff.md](./iphone-packet-handoff.md)

## Dashboard

The dashboard lives in `dashboard/` and reads telemetry from the ESP32 over Wi-Fi.

It shows:

- Current mode
- Grouped `find_and_go` state
- BLE connection status
- Active haptic output
- Motor zones
- Ultrasonic hazard levels
- Live mode transitions for demos

This dashboard became one of the most valuable development tools in the project because it made the vest's internal state visible instead of forcing us to infer behavior from motor output alone.

## Repository Layout

```text
.
|-- BLE_PACKET_FLOW.md
|-- VisionVest/                    # Active iPhone app source
|-- VisionVest.xcodeproj/          # Xcode project
|-- Ultralytics/                   # Detection integration utilities
|-- esp32-firmware/
|   `-- VisionVest/
|       `-- VisionVest.ino         # Main ESP32 firmware
|-- VisionVestBleConnectionTest/
|-- VisionVestBlinkTest/
|-- VisionVestIphoneOnly/
|-- VisionVestMotorTest/
|-- VisionVestUltrasonicTest/
|-- dashboard/                     # Judge/demo telemetry dashboard
|-- docs/
|-- protocol/
|-- tests/
|-- esp32-packet-spec.md
`-- iphone-packet-handoff.md
```

## Running The Project

### iPhone App

Requirements:

- Xcode
- Physical iPhone
- Camera permission
- Bluetooth permission
- Microphone / speech permission
- Motion access
- Location access for GPS mode

Open:

- [VisionVest.xcodeproj](./VisionVest.xcodeproj)

Then build and run the app on a real device.

### ESP32 Firmware

Flash:

- [esp32-firmware/VisionVest/VisionVest.ino](./esp32-firmware/VisionVest/VisionVest.ino)

The firmware is written for the ESP32 Arduino environment and depends on:

- ArduinoJson
- Adafruit NeoPixel
- NimBLE-Arduino

### Dashboard

From `dashboard/`:

```bash
npm install
npm run dev
```

For a production build:

```bash
npm run build
```

The default telemetry endpoint is:

- `http://192.168.4.1/telemetry`

## Current State

What is already working in this repository:

- Live camera preview
- Object detection integration
- Detection overlays
- Target selection and direction estimation
- BLE command generation and transmission
- Find & Go flow with scan-complete signaling
- GPS guidance scaffolding
- ESP32 motor control and mode handling
- Awareness-mode ultrasonic sensing
- Wi-Fi telemetry dashboard

What still benefits from continued refinement:

- Detector tuning and dataset quality
- End-to-end field testing
- GPS route robustness
- Additional user testing on haptic cue design
- Final production polish across UI and hardware packaging

## Why This Project Matters

VisionVest is more than just an app and more than just a hardware prototype. It is a full-stack assistive system that combines:

- embedded systems
- mobile perception
- BLE communication
- real-time haptics
- wearable interaction design

We built it to explore a simple but important idea: navigation does not always need to be spoken. Sometimes the best interface is something you can feel.

## Additional Documentation

- [BLE_PACKET_FLOW.md](./BLE_PACKET_FLOW.md)
- [docs/system-overview.md](./docs/system-overview.md)
- [esp32-packet-spec.md](./esp32-packet-spec.md)
- [iphone-packet-handoff.md](./iphone-packet-handoff.md)

[![Devpost](https://img.shields.io/badge/Devpost-View_Project-blue)](https://devpost.com/software/visionvest)

