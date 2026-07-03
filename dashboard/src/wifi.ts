import type { Direction, HazardLevel, ModeGroup, MotorZone, Pattern, TelemetryPayload } from './types'

const TELEMETRY_POLL_INTERVAL_MS = 250

export interface TelemetryPollerSession {
  disconnect: () => Promise<void>
}

function parseMode(value: unknown): TelemetryPayload['mode'] {
  switch (value) {
    case 'manual':
    case 'awareness':
    case 'object_nav':
    case 'find_search':
    case 'gps_nav':
      return value
    default:
      return 'manual'
  }
}

function parseModeGroup(value: unknown): ModeGroup {
  switch (value) {
    case 'manual':
    case 'awareness':
    case 'find_and_go':
    case 'gps_nav':
      return value
    default:
      return 'manual'
  }
}

function parsePattern(value: unknown): Pattern {
  switch (value) {
    case 'steady':
    case 'slow_pulse':
    case 'fast_pulse':
    case 'none':
      return value
    default:
      return 'none'
  }
}

function parseDirection(value: unknown): Direction {
  switch (value) {
    case 'left':
    case 'front':
    case 'right':
    case 'back':
    case 'front-left':
    case 'front-right':
    case 'back-left':
    case 'back-right':
    case 'none':
      return value
    default:
      return 'none'
  }
}

function parseHazardLevel(value: unknown): HazardLevel {
  switch (value) {
    case 'SAFE':
    case 'CAUTION':
    case 'DANGER':
      return value
    default:
      return 'SAFE'
  }
}

function parseMotorMask(value: unknown): MotorZone[] {
  if (!Array.isArray(value)) {
    return []
  }

  return value.filter(
    (entry): entry is MotorZone =>
      entry === 'front' || entry === 'back' || entry === 'left' || entry === 'right',
  )
}

function parseSensor(value: unknown): TelemetryPayload['hazards']['back'] {
  const sensor = typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}

  return {
    valid: sensor.valid === true,
    distanceCm: typeof sensor.distanceCm === 'number' ? sensor.distanceCm : 0,
    level: parseHazardLevel(sensor.level),
  }
}

function normalizeTelemetry(value: unknown): TelemetryPayload {
  const payload = typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
  const hazards =
    typeof payload.hazards === 'object' && payload.hazards !== null
      ? (payload.hazards as Record<string, unknown>)
      : {}
  const output =
    typeof payload.output === 'object' && payload.output !== null
      ? (payload.output as Record<string, unknown>)
      : {}
  const command =
    typeof payload.command === 'object' && payload.command !== null
      ? (payload.command as Record<string, unknown>)
      : {}

  return {
    version: typeof payload.version === 'number' ? payload.version : 1,
    mode: parseMode(payload.mode),
    modeGroup: parseModeGroup(payload.modeGroup),
    findAndGoActive: payload.findAndGoActive === true,
    bleConnected: payload.bleConnected === true,
    hazards: {
      back: parseSensor(hazards.back),
      left: parseSensor(hazards.left),
      right: parseSensor(hazards.right),
    },
    output: {
      source: typeof output.source === 'string' ? output.source : 'idle',
      motorMask: parseMotorMask(output.motorMask),
      intensity: typeof output.intensity === 'number' ? output.intensity : 0,
      pattern: parsePattern(output.pattern),
    },
    command: {
      active: command.active === true,
      direction: parseDirection(command.direction),
      pattern: parsePattern(command.pattern),
      intensity: typeof command.intensity === 'number' ? command.intensity : 0,
      ttlRemainingMs: typeof command.ttlRemainingMs === 'number' ? command.ttlRemainingMs : 0,
    },
    uptimeMs: typeof payload.uptimeMs === 'number' ? payload.uptimeMs : 0,
  }
}

async function fetchTelemetry(baseUrl: string, signal: AbortSignal): Promise<TelemetryPayload> {
  const normalizedBaseUrl = baseUrl.replace(/\/$/, '')
  const response = await fetch(`${normalizedBaseUrl}/telemetry`, {
    method: 'GET',
    mode: 'cors',
    cache: 'no-store',
    signal,
  })

  if (!response.ok) {
    throw new Error(`ESP32 telemetry request failed: ${response.status}`)
  }

  return normalizeTelemetry(await response.json())
}

export async function connectTelemetryPoller(
  baseUrl: string,
  onTelemetry: (payload: TelemetryPayload) => void,
  onStatus: (message: string) => void,
): Promise<TelemetryPollerSession> {
  const controller = new AbortController()

  await fetchTelemetry(baseUrl, controller.signal).then(onTelemetry)

  let pollTimer: number | null = null
  let pollInFlight = false
  let disconnected = false

  pollTimer = window.setInterval(async () => {
    if (pollInFlight || disconnected) {
      return
    }

    pollInFlight = true
    try {
      const payload = await fetchTelemetry(baseUrl, controller.signal)
      onTelemetry(payload)
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Telemetry polling failed'
      onStatus(`Waiting for ESP32 telemetry... ${message}`)
    } finally {
      pollInFlight = false
    }
  }, TELEMETRY_POLL_INTERVAL_MS)

  return {
    disconnect: async () => {
      disconnected = true
      controller.abort()
      if (pollTimer !== null) {
        window.clearInterval(pollTimer)
        pollTimer = null
      }
    },
  }
}
