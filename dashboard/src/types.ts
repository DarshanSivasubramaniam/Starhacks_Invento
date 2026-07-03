export type Mode = 'manual' | 'awareness' | 'object_nav' | 'find_search' | 'gps_nav'
export type ModeGroup = 'manual' | 'awareness' | 'find_and_go' | 'gps_nav'

export type Direction =
  | 'left'
  | 'front'
  | 'right'
  | 'back'
  | 'front-left'
  | 'front-right'
  | 'back-left'
  | 'back-right'
  | 'none'

export type Pattern = 'steady' | 'slow_pulse' | 'fast_pulse' | 'none'

export type HazardLevel = 'SAFE' | 'CAUTION' | 'DANGER'

export type MotorZone = 'front' | 'back' | 'left' | 'right'

export type ConnectionState = 'disconnected' | 'connecting' | 'live'

export interface TelemetrySensorState {
  valid: boolean
  distanceCm: number
  level: HazardLevel
}

export interface TelemetryPayload {
  version: number
  mode: Mode
  modeGroup: ModeGroup
  findAndGoActive: boolean
  bleConnected: boolean
  hazards: Record<'back' | 'left' | 'right', TelemetrySensorState>
  output: {
    source: string
    motorMask: MotorZone[]
    intensity: number
    pattern: Pattern
  }
  command: {
    active: boolean
    direction: Direction
    pattern: Pattern
    intensity: number
    ttlRemainingMs: number
  }
  uptimeMs: number
}

export interface EventItem {
  id: number
  title: string
  detail: string
  timestampLabel: string
}

export const SENSOR_SIDES = ['back', 'left', 'right'] as const
