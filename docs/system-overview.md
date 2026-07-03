# System Overview

## Architecture Summary

VisionVest is organized as a split-compute wearable system:

- The iPhone is responsible for camera perception, object detection, target
  selection, direction reasoning, future depth integration, future speech, and
  BLE central communication.
- The ESP32 is responsible for BLE peripheral communication, local sensor
  handling, safety arbitration, haptic motor control, watchdog behavior, and
  telemetry.

## Responsibility Boundary

### iPhone

- Captures camera frames.
- Runs object detection and later higher-level perception modules.
- Chooses a primary target and estimates body-relative direction.
- Synthesizes structured commands for downstream execution.
- Sends commands to the vest over BLE when transport is added.

### ESP32

- Receives structured commands from the iPhone.
- Validates and buffers the latest usable command.
- Drives haptic outputs according to direction, intensity, and pattern.
- Monitors ultrasonic sensors for local safety overrides.
- Stops or overrides actuation when commands are stale or hazards are detected.

## Incremental Build Strategy

The system is intentionally built in this order:

1. iPhone app foundation
2. Camera pipeline
3. Object detection
4. Target selection and direction logic
5. Local command synthesis
6. BLE transport
7. ESP32 receive path
8. Haptics and safety logic

This sequencing keeps early milestones focused on perception and decision-making
before introducing hardware complexity.
