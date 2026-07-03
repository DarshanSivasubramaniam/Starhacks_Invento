# VisionVest Judge Dashboard

Local Wi-Fi dashboard for demoing the VisionVest hardware to judges.

## What it does

- Polls live telemetry from the ESP32 over its own Wi-Fi access point
- Keeps the iPhone on BLE control while the dashboard mirrors the vest state
- Shows sensor state, motor output, mode, and recent events in one place
- Runs locally in Chrome or Edge on your laptop

## Local development

```bash
npm install
npm run dev
```

Open the local Vite URL in Chrome or Edge.

## Connecting to the ESP32

1. Flash the latest `esp32-firmware/VisionVest/VisionVest.ino`
2. Open Serial Monitor at `115200`
3. Join the laptop to the ESP32 Wi-Fi network:
   - SSID: `Generic32`
   - Password: `StarkHacks2026`
4. Wait for a line like:
   `WIFI: telemetry server ready at http://192.168.4.1/telemetry`
5. Run the dashboard and keep the default `http://192.168.4.1`
6. Click `Connect`

## Build

```bash
npm run build
```
