import { useEffect, useMemo, useRef, useState } from 'react'
import './App.css'
import { connectTelemetryPoller, type TelemetryPollerSession } from './wifi'
import type { ConnectionState, EventItem, HazardLevel, MotorZone, TelemetryPayload, TelemetrySensorState } from './types'
import { SENSOR_SIDES } from './types'

const DEFAULT_BASE_URL = 'http://192.168.4.1'
const BASE_URL_STORAGE_KEY = 'navvest-base-url'

function formatMode(mode: string) {
  return mode
    .split('_')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

function displayMode(telemetry: TelemetryPayload | null) {
  if (!telemetry) {
    return 'Unknown'
  }

  return formatMode(telemetry.modeGroup)
}

function formatLabel(value: string) {
  return value
    .split(/[_-]/)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

function formatSource(source: string) {
  switch (source) {
    case 'ultrasonic_danger':
      return 'Ultrasonic danger response'
    case 'ultrasonic_caution':
      return 'Ultrasonic caution response'
    case 'iphone':
      return 'Guidance cue'
    case 'idle':
      return 'No haptic output'
    default:
      return source.replace(/_/g, ' ')
  }
}

function formatPattern(pattern: string) {
  return pattern.replace(/_/g, ' ')
}

function describeMotorMask(motorMask: MotorZone[]) {
  if (motorMask.length === 0) {
    return 'None'
  }

  return motorMask.map((zone) => zone.charAt(0).toUpperCase() + zone.slice(1)).join(' + ')
}

function formatSensorCaption(sensor: TelemetrySensorState | null) {
  if (!sensor) {
    return 'guidance cue'
  }

  if (!sensor.valid) {
    return 'No echo'
  }

  return `${Math.round(sensor.distanceCm)} cm`
}

function hazardRank(level: HazardLevel) {
  switch (level) {
    case 'DANGER':
      return 2
    case 'CAUTION':
      return 1
    case 'SAFE':
    default:
      return 0
  }
}

function findPriorityHazard(telemetry: TelemetryPayload) {
  return SENSOR_SIDES.reduce(
    (best, side) => {
      const sensor = telemetry.hazards[side]
      if (hazardRank(sensor.level) > hazardRank(best.level)) {
        return { side, level: sensor.level }
      }
      return best
    },
    { side: 'back', level: 'SAFE' as HazardLevel },
  )
}

function lowerCaseDirection(direction: string) {
  return formatLabel(direction).toLowerCase()
}

function describeTarget(telemetry: TelemetryPayload | null, hazardHeadline: { side: string; level: HazardLevel } | null) {
  if (!telemetry) {
    return 'Waiting for live target data.'
  }

  const direction = telemetry.command.direction
  const hasGuidanceTarget = telemetry.command.active && direction !== 'none'

  switch (telemetry.mode) {
    case 'find_search':
      return hasGuidanceTarget
        ? `Search target is being tracked ${lowerCaseDirection(direction)} of the wearer.`
        : 'Find/Search is active, but no target is currently locked.'
    case 'object_nav':
      return hasGuidanceTarget
        ? `Navigation object is being guided ${lowerCaseDirection(direction)} of the wearer.`
        : 'Object navigation is active, but no object is currently selected.'
    case 'gps_nav':
      return hasGuidanceTarget
        ? `Waypoint guidance is pulling ${lowerCaseDirection(direction)}.`
        : 'GPS navigation is active, but no directional cue is currently active.'
    case 'manual':
      return hasGuidanceTarget
        ? `Manual guidance is currently set ${lowerCaseDirection(direction)}.`
        : 'Manual mode is active with no directional cue.'
    case 'awareness':
    default:
      if (hazardHeadline && hazardHeadline.level !== 'SAFE') {
        return `Obstacle watch is focused on the ${hazardHeadline.side} side.`
      }
      return 'Obstacle watch is active with no close hazards.'
  }
}

function describeOutputSentence(telemetry: TelemetryPayload | null, hazardHeadline: { side: string; level: HazardLevel } | null) {
  if (!telemetry) {
    return 'Connect to the ESP32 to start the live haptic story.'
  }

  const activeZones = telemetry.output.motorMask.map((zone) => zone.toUpperCase())
  const zoneText = activeZones.length > 0 ? activeZones.join(' + ') : 'no motor zones'
  const patternText = formatPattern(telemetry.output.pattern)

  switch (telemetry.output.source) {
    case 'ultrasonic_danger':
      return `${formatLabel(hazardHeadline?.side ?? 'back')} danger detected. ${zoneText} motor zone is firing with a ${patternText} alert.`
    case 'ultrasonic_caution':
      return `${formatLabel(hazardHeadline?.side ?? 'back')} caution detected. ${zoneText} motor zone is pulsing a ${patternText} warning.`
    case 'iphone':
      return `Guidance is steering the wearer toward ${formatLabel(telemetry.command.direction)} with a ${patternText} haptic cue.`
    case 'idle':
    default:
      return 'The vest is currently quiet with no active haptic output.'
  }
}

function activeDecisionLayer(telemetry: TelemetryPayload | null) {
  if (!telemetry) {
    return 'none'
  }

  if (telemetry.output.source === 'ultrasonic_danger') {
    return 'danger'
  }

  if (telemetry.output.source === 'iphone') {
    return 'guidance'
  }

  if (telemetry.output.source === 'ultrasonic_caution') {
    return 'caution'
  }

  return 'none'
}

function freshnessLabel(lastUpdateMs: number | null, nowMs: number) {
  if (lastUpdateMs === null) {
    return 'Waiting'
  }

  const delta = Math.max(0, nowMs - lastUpdateMs)
  if (delta < 700) {
    return 'Live'
  }
  if (delta < 2500) {
    return `${(delta / 1000).toFixed(1)}s ago`
  }
  return 'Stale'
}

function makeTimestampLabel(date: Date) {
  return date.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

function App() {
  const [connectionState, setConnectionState] = useState<ConnectionState>('disconnected')
  const [telemetry, setTelemetry] = useState<TelemetryPayload | null>(null)
  const [lastUpdateMs, setLastUpdateMs] = useState<number | null>(null)
  const [nowMs, setNowMs] = useState(() => Date.now())
  const [events, setEvents] = useState<EventItem[]>([])
  const [statusMessage, setStatusMessage] = useState('Enter the ESP32 URL and start live Wi-Fi telemetry.')
  const [baseUrl, setBaseUrl] = useState(() => window.localStorage.getItem(BASE_URL_STORAGE_KEY) ?? DEFAULT_BASE_URL)
  const [isFullscreen, setIsFullscreen] = useState(() => document.fullscreenElement !== null)

  const sessionRef = useRef<TelemetryPollerSession | null>(null)
  const previousTelemetryRef = useRef<TelemetryPayload | null>(null)
  const eventIdRef = useRef(0)

  const pushEvent = (title: string, detail: string) => {
    const timestamp = new Date()
    setEvents((current) =>
      [
        {
          id: ++eventIdRef.current,
          title,
          detail,
          timestampLabel: makeTimestampLabel(timestamp),
        },
        ...current,
      ].slice(0, 5),
    )
  }

  const absorbTelemetry = (nextTelemetry: TelemetryPayload) => {
    const previousTelemetry = previousTelemetryRef.current

    setTelemetry(nextTelemetry)
    setLastUpdateMs(Date.now())
    setConnectionState('live')
    setStatusMessage(`Live telemetry streaming from ${baseUrl.replace(/\/$/, '')}/telemetry`)

    if (!previousTelemetry) {
      pushEvent('Feed online', `${displayMode(nextTelemetry)} data stream active`)
    } else {
      if (previousTelemetry.modeGroup !== nextTelemetry.modeGroup) {
        pushEvent('Mode changed', `${displayMode(previousTelemetry)} -> ${displayMode(nextTelemetry)}`)
      }

      for (const side of SENSOR_SIDES) {
        const previousLevel = previousTelemetry.hazards[side].level
        const nextLevel = nextTelemetry.hazards[side].level
        if (previousLevel !== nextLevel) {
          pushEvent(`${side.toUpperCase()} sensor`, `${previousLevel} -> ${nextLevel}`)
        }
      }

      const previousMotors = previousTelemetry.output.motorMask.join(',')
      const nextMotors = nextTelemetry.output.motorMask.join(',')
      if (
        previousTelemetry.output.source !== nextTelemetry.output.source ||
        previousMotors !== nextMotors ||
        previousTelemetry.output.pattern !== nextTelemetry.output.pattern
      ) {
        pushEvent(
          'Output changed',
          `${formatSource(nextTelemetry.output.source)} on ${describeMotorMask(nextTelemetry.output.motorMask)}`,
        )
      }
    }

    previousTelemetryRef.current = nextTelemetry
  }

  useEffect(() => {
    const interval = window.setInterval(() => {
      setNowMs(Date.now())
    }, 200)

    return () => {
      window.clearInterval(interval)
    }
  }, [])

  useEffect(() => {
    window.localStorage.setItem(BASE_URL_STORAGE_KEY, baseUrl)
  }, [baseUrl])

  useEffect(() => {
    const handleFullscreenChange = () => {
      setIsFullscreen(document.fullscreenElement !== null)
    }

    document.addEventListener('fullscreenchange', handleFullscreenChange)
    return () => {
      document.removeEventListener('fullscreenchange', handleFullscreenChange)
    }
  }, [])

  const handleDisconnect = async () => {
    const session = sessionRef.current
    sessionRef.current = null

    if (session) {
      await session.disconnect()
    }

    setConnectionState('disconnected')
    setStatusMessage('Disconnected. Last known vest state is still visible.')
    pushEvent('Disconnected', 'Stopped polling the ESP32 telemetry endpoint')
  }

  const handleConnect = async () => {
    if (sessionRef.current) {
      await handleDisconnect()
    }

    setConnectionState('connecting')
    setStatusMessage(`Connecting to ${baseUrl.replace(/\/$/, '')}/telemetry ...`)
    previousTelemetryRef.current = null
    setLastUpdateMs(null)

    try {
      const session = await connectTelemetryPoller(
        baseUrl,
        (payload) => {
          absorbTelemetry(payload)
        },
        (message) => {
          if (telemetry) {
            setConnectionState('disconnected')
          }
          setStatusMessage(message)
        },
      )

      sessionRef.current = session
      pushEvent('Polling started', `Watching ${baseUrl.replace(/\/$/, '')}/telemetry`)
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Could not connect to the ESP32 telemetry endpoint'
      setConnectionState('disconnected')
      setStatusMessage(message)
      pushEvent('Connection failed', message)
    }
  }

  useEffect(() => {
    return () => {
      void sessionRef.current?.disconnect()
    }
  }, [])

  const handleToggleFullscreen = async () => {
    if (document.fullscreenElement) {
      await document.exitFullscreen()
      return
    }

    await document.documentElement.requestFullscreen()
  }

  const activeTelemetry = telemetry
  const freshness = freshnessLabel(lastUpdateMs, nowMs)
  const hazardHeadline = activeTelemetry ? findPriorityHazard(activeTelemetry) : null
  const ultrasonicEnabled = activeTelemetry?.mode === 'awareness'
  const outputSentence = describeOutputSentence(activeTelemetry, hazardHeadline)
  const targetDescription = describeTarget(activeTelemetry, hazardHeadline)
  const winningLayer = activeDecisionLayer(activeTelemetry)

  const heroState = useMemo(() => {
    const motorMask = new Set(activeTelemetry?.output.motorMask ?? [])
    const commandDirection = activeTelemetry?.command.direction ?? 'none'
    return {
      front: motorMask.has('front'),
      back: motorMask.has('back'),
      left: motorMask.has('left'),
      right: motorMask.has('right'),
      frontLeft: commandDirection === 'front-left' || (motorMask.has('front') && motorMask.has('left')),
      frontRight: commandDirection === 'front-right' || (motorMask.has('front') && motorMask.has('right')),
    }
  }, [activeTelemetry])

  return (
    <main className={`dashboard-shell connection-${connectionState}`}>
      <section className="topbar panel">
        <div className="brand-block">
          <p className="eyebrow">VisionVest Judge Dashboard</p>
          <h1>Live ESP32 Wi-Fi telemetry.</h1>
        </div>

        <div className="status-grid">
          <div className="status-card">
            <span className="status-label">Connection</span>
            <strong className={`status-value state-${connectionState}`}>{connectionState}</strong>
            <span className="status-detail">Polling the ESP32 directly over its own Wi-Fi access point.</span>
          </div>
          <div className="status-card">
            <span className="status-label">Mode</span>
            <strong className="status-value">{displayMode(activeTelemetry)}</strong>
            <span className="status-detail">
              {ultrasonicEnabled ? 'Ultrasonic awareness enabled' : 'Ultrasonic alerts muted'}
            </span>
          </div>
          <div className="status-card">
            <span className="status-label">Freshness</span>
            <strong className="status-value">{freshness}</strong>
            <span className="status-detail">{statusMessage}</span>
          </div>
          <div className="status-card">
            <span className="status-label">Endpoint</span>
            <strong className="status-value endpoint-value">{baseUrl}</strong>
            <span className="status-detail">Default AP endpoint is `http://192.168.4.1/telemetry`.</span>
          </div>
          <div className="status-actions">
            <label className="endpoint-field">
              <span>ESP32 URL</span>
              <input
                value={baseUrl}
                onChange={(event) => setBaseUrl(event.target.value)}
                placeholder="http://192.168.4.1"
                spellCheck={false}
              />
            </label>
            <div className="action-row">
              <button className="action-button primary" onClick={handleConnect} disabled={connectionState === 'connecting'}>
                {sessionRef.current ? 'Reconnect' : 'Connect'}
              </button>
              <button className="action-button" onClick={handleToggleFullscreen}>
                {isFullscreen ? 'Exit Full Screen' : 'Full Screen'}
              </button>
              <button className="action-button muted" onClick={handleDisconnect} disabled={!sessionRef.current}>
                Disconnect
              </button>
            </div>
          </div>
        </div>
      </section>

      <section className="main-grid">
        <section className="hero-column panel">
          <div className="hero-copy">
            <p className="eyebrow">Vest activity</p>
            <div className="hero-summary">
              <h2>{activeTelemetry ? displayMode(activeTelemetry) : 'Waiting for telemetry'}</h2>
              <p>{targetDescription}</p>
            </div>
          </div>

          <div className="vest-stage">
            <svg className="vest-silhouette" viewBox="0 0 360 420" aria-hidden="true">
              <path d="M122 36h116l40 48 28 120-34 168H88L54 204l28-120 40-48Z" />
              <path d="M144 36v66h72V36" />
              <path d="M112 112h136" />
              <path d="M132 148v188" />
              <path d="M228 148v188" />
            </svg>
            <div className={`hazard-arc arc-left level-${(activeTelemetry?.hazards.left.level ?? 'SAFE').toLowerCase()}`} />
            <div className={`hazard-arc arc-back level-${(activeTelemetry?.hazards.back.level ?? 'SAFE').toLowerCase()}`} />
            <div className={`hazard-arc arc-right level-${(activeTelemetry?.hazards.right.level ?? 'SAFE').toLowerCase()}`} />

            <div className="vest-shell-body">
              <div className={`motor-zone motor-front-left ${heroState.frontLeft ? 'command-active' : ''}`}>
                <span>FRONT LEFT</span>
                <small>{heroState.frontLeft ? 'active cue' : 'guide'}</small>
              </div>
              <div
                className={`motor-zone motor-front ${heroState.front ? `pattern-${activeTelemetry?.output.pattern ?? 'none'} active` : ''} command-zone`}
              >
                <span>FRONT</span>
                <small>{heroState.front ? 'active cue' : 'guide'}</small>
              </div>
              <div className={`motor-zone motor-front-right ${heroState.frontRight ? 'command-active' : ''}`}>
                <span>FRONT RIGHT</span>
                <small>{heroState.frontRight ? 'active cue' : 'guide'}</small>
              </div>
              <div
                className={`motor-zone motor-left hazard-${(activeTelemetry?.hazards.left.level ?? 'SAFE').toLowerCase()} ${heroState.left ? 'active' : ''}`}
              >
                <span>LEFT</span>
                <small>{formatSensorCaption(activeTelemetry?.hazards.left ?? null)}</small>
              </div>
              <div className="vest-core">
                <span className="vest-title">{activeTelemetry ? displayMode(activeTelemetry) : 'Offline'}</span>
                <strong>{activeTelemetry ? describeMotorMask(activeTelemetry.output.motorMask) : 'No motors'}</strong>
                <small>{activeTelemetry ? `${activeTelemetry.output.intensity}/255 intensity` : 'No telemetry yet'}</small>
              </div>
              <div
                className={`motor-zone motor-right hazard-${(activeTelemetry?.hazards.right.level ?? 'SAFE').toLowerCase()} ${heroState.right ? 'active' : ''}`}
              >
                <span>RIGHT</span>
                <small>{formatSensorCaption(activeTelemetry?.hazards.right ?? null)}</small>
              </div>
              <div
                className={`motor-zone motor-back hazard-${(activeTelemetry?.hazards.back.level ?? 'SAFE').toLowerCase()} ${heroState.back ? 'active' : ''}`}
              >
                <span>BACK</span>
                <small>{formatSensorCaption(activeTelemetry?.hazards.back ?? null)}</small>
              </div>
            </div>
          </div>

          <div className="target-chip">
            <span className="target-chip-label">Detected target</span>
            <strong>{targetDescription}</strong>
          </div>
        </section>

        <section className="output-column">
          <article className="panel output-card">
            <p className="eyebrow">Current output</p>
            <h2 className="output-sentence">{outputSentence}</h2>
            <p className="output-description">This sentence updates live to explain the vest response in plain English.</p>

            <div className="metric-grid">
              <div className="metric-card">
                <span className="metric-label">Mode</span>
                <strong>{activeTelemetry ? displayMode(activeTelemetry) : 'Offline'}</strong>
              </div>
              <div className="metric-card">
                <span className="metric-label">Active motors</span>
                <strong>{activeTelemetry ? describeMotorMask(activeTelemetry.output.motorMask) : 'None'}</strong>
              </div>
              <div className="metric-card">
                <span className="metric-label">Pattern</span>
                <strong>{activeTelemetry ? formatPattern(activeTelemetry.output.pattern) : 'none'}</strong>
              </div>
              <div className="metric-card">
                <span className="metric-label">Intensity</span>
                <strong>{activeTelemetry ? activeTelemetry.output.intensity : 0}</strong>
              </div>
            </div>
          </article>

          <article className="panel decision-card">
            <p className="eyebrow">Decision ladder</p>
            <ul className="decision-ladder">
              <li>
                <div className={`decision-step ${winningLayer === 'danger' ? 'step-winning' : ''}`}>
                  <span className="decision-rank">1</span>
                  <div>
                    <strong>Danger override</strong>
                    <p>Closest danger obstacle takes full priority and immediately drives haptics.</p>
                  </div>
                </div>
              </li>
              <li>
                <div className={`decision-step ${winningLayer === 'guidance' ? 'step-winning' : ''}`}>
                  <span className="decision-rank">2</span>
                  <div>
                    <strong>Guidance cue</strong>
                    <p>Directional guidance wins whenever danger is not active.</p>
                  </div>
                </div>
              </li>
              <li>
                <div className={`decision-step ${winningLayer === 'caution' ? 'step-winning' : ''}`}>
                  <span className="decision-rank">3</span>
                  <div>
                    <strong>Caution warning</strong>
                    <p>Caution obstacles pulse only when danger and guidance are both inactive.</p>
                  </div>
                </div>
              </li>
            </ul>
            <p className="decision-note">
              {winningLayer === 'none'
                ? 'No layer is currently winning because the vest is idle.'
                : `${formatLabel(winningLayer)} is currently winning the arbitration.`}
            </p>
          </article>
        </section>
      </section>

      <section className="event-strip panel">
        <div className="event-strip-header">
          <p className="eyebrow">Recent events</p>
          <span className="event-strip-note">The most recent five live telemetry changes stay visible for judges.</span>
        </div>
        <div className="event-list">
          {events.length > 0 ? (
            events.map((event) => (
              <article key={event.id} className="event-card">
                <span className="event-time">{event.timestampLabel}</span>
                <strong>{event.title}</strong>
                <p>{event.detail}</p>
              </article>
            ))
          ) : (
            <article className="event-card placeholder">
              <strong>No events yet</strong>
              <p>Connect to the ESP32 telemetry URL to begin the live hardware narrative.</p>
            </article>
          )}
        </div>
      </section>
    </main>
  )
}

export default App
