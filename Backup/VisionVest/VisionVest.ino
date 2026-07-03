#include <Arduino.h>
#include <ArduinoJson.h>
#include <Adafruit_NeoPixel.h>
#include <NimBLEDevice.h>
#include <esp32-hal-ledc.h>
#include <string>

// ============================================================================
// 1. Pin definitions and constants
// ============================================================================

static const char *BLE_DEVICE_NAME = "VisionVest";
static const char *BLE_SERVICE_UUID = "7B7E1000-7C6B-4B8F-9E2A-6B5F4F0A1000";
static const char *BLE_COMMAND_CHAR_UUID = "7B7E1001-7C6B-4B8F-9E2A-6B5F4F0A1000";

static const uint8_t BACK_ENA_PIN = 4;
static const uint8_t BACK_IN1_PIN = 5;
static const uint8_t BACK_IN2_PIN = 6;
static const uint8_t FRONT_IN3_PIN = 7;
static const uint8_t FRONT_IN4_PIN = 15;
static const uint8_t FRONT_ENB_PIN = 16;

static const uint8_t LEFT_ENA_PIN = 18;
static const uint8_t LEFT_IN1_PIN = 8;
static const uint8_t LEFT_IN2_PIN = 3;
static const uint8_t RIGHT_IN3_PIN = 46;
static const uint8_t RIGHT_IN4_PIN = 9;
static const uint8_t RIGHT_ENB_PIN = 10;

static const uint8_t ULTRASONIC_BACK_TRIG_PIN = 41;
static const uint8_t ULTRASONIC_BACK_ECHO_PIN = 42;
static const uint8_t ULTRASONIC_LEFT_TRIG_PIN = 39;
static const uint8_t ULTRASONIC_LEFT_ECHO_PIN = 40;
static const uint8_t ULTRASONIC_RIGHT_TRIG_PIN = 21;
static const uint8_t ULTRASONIC_RIGHT_ECHO_PIN = 47;

static const uint8_t NEOPIXEL_PIN = 38;
static const uint8_t NEOPIXEL_COUNT = 1;

static const uint32_t SERIAL_BAUD_RATE = 115200;
static const uint32_t LOG_INTERVAL_MS = 500;
static const uint32_t LEDC_FREQUENCY_HZ = 5000;
static const uint8_t LEDC_RESOLUTION_BITS = 8;
static const uint8_t MOTOR_PWM_CHANNEL_BACK = 0;
static const uint8_t MOTOR_PWM_CHANNEL_FRONT = 1;
static const uint8_t MOTOR_PWM_CHANNEL_LEFT = 2;
static const uint8_t MOTOR_PWM_CHANNEL_RIGHT = 3;

static const uint32_t SLOW_PULSE_ON_MS = 500;
static const uint32_t SLOW_PULSE_OFF_MS = 500;
static const uint32_t FAST_PULSE_ON_MS = 150;
static const uint32_t FAST_PULSE_OFF_MS = 150;

static const uint8_t ULTRASONIC_SENSOR_COUNT = 3;
static const uint8_t ULTRASONIC_MOVING_AVERAGE_WINDOW = 5;
static const uint8_t ULTRASONIC_INVALID_CLEAR_COUNT = 3;
static const uint32_t ULTRASONIC_START_INTERVAL_MS = 60;
static const uint32_t ULTRASONIC_TRIGGER_LOW_US = 2;
static const uint32_t ULTRASONIC_TRIGGER_HIGH_US = 10;
static const uint32_t ULTRASONIC_ECHO_TIMEOUT_US = 25000;
static const float ULTRASONIC_MAX_VALID_CM = 400.0f;
static const float DANGER_THRESHOLD_CM = 50.0f;
static const float CAUTION_THRESHOLD_CM = 100.0f;

static const size_t JSON_DOC_CAPACITY = 512;
static const size_t REJECTION_REASON_SIZE = 96;
static const uint16_t BLE_COMMAND_MAX_LEN = 256;

static const uint8_t COLOR_RED_R = 255;
static const uint8_t COLOR_RED_G = 0;
static const uint8_t COLOR_RED_B = 0;
static const uint8_t COLOR_YELLOW_R = 255;
static const uint8_t COLOR_YELLOW_G = 160;
static const uint8_t COLOR_YELLOW_B = 0;
static const uint8_t COLOR_GREEN_R = 0;
static const uint8_t COLOR_GREEN_G = 255;
static const uint8_t COLOR_GREEN_B = 0;
static const uint8_t COLOR_BLUE_R = 0;
static const uint8_t COLOR_BLUE_G = 0;
static const uint8_t COLOR_BLUE_B = 255;

// ============================================================================
// 2. Enums and structs
// ============================================================================

enum Mode {
  MANUAL,
  AWARENESS,
  OBJECT_NAV,
  FIND_SEARCH,
  GPS_NAV
};

enum Direction {
  DIR_LEFT,
  DIR_FRONT,
  DIR_RIGHT,
  DIR_BACK,
  DIR_FRONT_LEFT,
  DIR_FRONT_RIGHT,
  DIR_BACK_LEFT,
  DIR_BACK_RIGHT,
  DIR_NONE
};

enum Pattern {
  PATTERN_STEADY,
  PATTERN_SLOW_PULSE,
  PATTERN_FAST_PULSE,
  PATTERN_NONE
};

enum HazardLevel {
  SAFE,
  CAUTION,
  DANGER
};

struct VestCommand {
  Mode mode;
  Direction direction;
  uint8_t intensity;
  Pattern pattern;
  uint8_t priority;
  uint16_t ttlMs;
  float confidence;
  bool hasDistance;
  float distanceMeters;
  uint32_t seq;
  uint32_t receivedAtMs;
  uint32_t expiresAtMs;
};

struct HazardState {
  HazardLevel back;
  HazardLevel left;
  HazardLevel right;
  float backCm;
  float leftCm;
  float rightCm;
};

struct HapticOutput {
  Direction direction;
  uint8_t intensity;
  Pattern pattern;
  uint8_t priority;
  const char *source;
  uint8_t motorMask;
};

enum UltrasonicMeasurementState {
  US_IDLE,
  US_TRIGGER_LOW,
  US_TRIGGER_HIGH,
  US_WAIT_FOR_ECHO_RISE,
  US_WAIT_FOR_ECHO_FALL,
  US_COMPLETE,
  US_TIMEOUT
};

struct UltrasonicSensorState {
  const char *name;
  uint8_t trigPin;
  uint8_t echoPin;
  float samples[ULTRASONIC_MOVING_AVERAGE_WINDOW];
  uint8_t sampleCount;
  uint8_t nextSampleIndex;
  bool hasValidAverage;
  float averagedCm;
  UltrasonicMeasurementState state;
  uint32_t stateStartedUs;
  uint32_t measurementStartedUs;
  uint32_t echoRiseUs;
  float pendingDistanceCm;
  uint8_t invalidReadStreak;
};

struct PendingCommandSlot {
  VestCommand command;
  bool hasCommand;
};

// ============================================================================
// 3. Global state variables
// ============================================================================

Adafruit_NeoPixel gNeoPixel(NEOPIXEL_COUNT, NEOPIXEL_PIN, NEO_GRB + NEO_KHZ800);

NimBLEServer *gBleServer = nullptr;
NimBLECharacteristic *gCommandCharacteristic = nullptr;

volatile bool gBleConnected = false;
volatile bool newCommandAvailable = false;

portMUX_TYPE gCommandMux = portMUX_INITIALIZER_UNLOCKED;

PendingCommandSlot gPendingCommand = {};
VestCommand gActiveCommand = {};
bool gHasActiveCommand = false;
Mode gCurrentMode = AWARENESS;

bool gSessionHasAcceptedSeq = false;
uint32_t gLastAcceptedSeq = 0;

UltrasonicSensorState gUltrasonicSensors[ULTRASONIC_SENSOR_COUNT] = {
    {"back", ULTRASONIC_BACK_TRIG_PIN, ULTRASONIC_BACK_ECHO_PIN, {0}, 0, 0, false, 0.0f, US_IDLE, 0, 0, 0, 0.0f, 0},
    {"left", ULTRASONIC_LEFT_TRIG_PIN, ULTRASONIC_LEFT_ECHO_PIN, {0}, 0, 0, false, 0.0f, US_IDLE, 0, 0, 0, 0.0f, 0},
    {"right", ULTRASONIC_RIGHT_TRIG_PIN, ULTRASONIC_RIGHT_ECHO_PIN, {0}, 0, 0, false, 0.0f, US_IDLE, 0, 0, 0, 0.0f, 0},
};

int8_t gActiveUltrasonicIndex = -1;
uint8_t gNextUltrasonicIndex = 0;
uint32_t gLastUltrasonicStartMs = 0;

uint32_t gLastLogMs = 0;
uint32_t gPatternPhaseStartedMs = 0;

uint8_t gCurrentMotorMask = 0;
uint8_t gCurrentMotorDuty = 0;

HazardState gCurrentHazardState = {SAFE, SAFE, SAFE, 0.0f, 0.0f, 0.0f};
HapticOutput gCurrentOutput = {DIR_NONE, 0, PATTERN_NONE, 0, "idle", 0};
HapticOutput gLastAppliedOutput = {DIR_NONE, 0, PATTERN_NONE, 0, "idle", 0};

// ============================================================================
// 4. BLE server and callbacks
// ============================================================================

class VisionVestServerCallbacks : public NimBLEServerCallbacks {
 public:
  void onConnect(NimBLEServer *pServer, NimBLEConnInfo &connInfo) override;
  void onDisconnect(NimBLEServer *pServer, NimBLEConnInfo &connInfo, int reason) override;
};

class VisionVestCommandCallbacks : public NimBLECharacteristicCallbacks {
 public:
  void onWrite(NimBLECharacteristic *pCharacteristic, NimBLEConnInfo &connInfo) override;
};

VisionVestServerCallbacks gServerCallbacks;
VisionVestCommandCallbacks gCommandCallbacks;

void restartAdvertising() {
  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  if (advertising != nullptr) {
    advertising->start();
  }
}

void VisionVestServerCallbacks::onConnect(NimBLEServer *pServer, NimBLEConnInfo &connInfo) {
  (void)pServer;
  (void)connInfo;
  gBleConnected = true;
}

void VisionVestServerCallbacks::onDisconnect(NimBLEServer *pServer, NimBLEConnInfo &connInfo, int reason) {
  (void)pServer;
  (void)connInfo;
  (void)reason;

  gBleConnected = false;
  gCurrentMode = AWARENESS;
  clearActiveCommand();

  portENTER_CRITICAL(&gCommandMux);
  gSessionHasAcceptedSeq = false;
  gLastAcceptedSeq = 0;
  portEXIT_CRITICAL(&gCommandMux);

  restartAdvertising();
}

// ============================================================================
// 5. JSON parser and validator
// ============================================================================

void setRejectReason(char *reason, size_t reasonSize, const char *message) {
  if (reasonSize == 0) {
    return;
  }
  snprintf(reason, reasonSize, "%s", message);
}

void setRejectReasonField(char *reason, size_t reasonSize, const char *prefix, const char *field) {
  if (reasonSize == 0) {
    return;
  }
  snprintf(reason, reasonSize, "%s%s", prefix, field);
}

bool parseModeString(const char *value, Mode &mode) {
  if (strcmp(value, "manual") == 0) {
    mode = MANUAL;
    return true;
  }
  if (strcmp(value, "awareness") == 0) {
    mode = AWARENESS;
    return true;
  }
  if (strcmp(value, "object_nav") == 0) {
    mode = OBJECT_NAV;
    return true;
  }
  if (strcmp(value, "find_search") == 0) {
    mode = FIND_SEARCH;
    return true;
  }
  if (strcmp(value, "gps_nav") == 0) {
    mode = GPS_NAV;
    return true;
  }
  return false;
}

bool parseDirectionString(const char *value, Direction &direction) {
  if (strcmp(value, "left") == 0) {
    direction = DIR_LEFT;
    return true;
  }
  if (strcmp(value, "front") == 0) {
    direction = DIR_FRONT;
    return true;
  }
  if (strcmp(value, "right") == 0) {
    direction = DIR_RIGHT;
    return true;
  }
  if (strcmp(value, "back") == 0) {
    direction = DIR_BACK;
    return true;
  }
  if (strcmp(value, "front-left") == 0 || strcmp(value, "front_left") == 0) {
    direction = DIR_FRONT_LEFT;
    return true;
  }
  if (strcmp(value, "front-right") == 0 || strcmp(value, "front_right") == 0) {
    direction = DIR_FRONT_RIGHT;
    return true;
  }
  if (strcmp(value, "back-left") == 0 || strcmp(value, "back_left") == 0) {
    direction = DIR_BACK_LEFT;
    return true;
  }
  if (strcmp(value, "back-right") == 0 || strcmp(value, "back_right") == 0) {
    direction = DIR_BACK_RIGHT;
    return true;
  }
  if (strcmp(value, "none") == 0) {
    direction = DIR_NONE;
    return true;
  }
  return false;
}

bool parsePatternString(const char *value, Pattern &pattern) {
  if (strcmp(value, "steady") == 0) {
    pattern = PATTERN_STEADY;
    return true;
  }
  if (strcmp(value, "slow_pulse") == 0) {
    pattern = PATTERN_SLOW_PULSE;
    return true;
  }
  if (strcmp(value, "fast_pulse") == 0) {
    pattern = PATTERN_FAST_PULSE;
    return true;
  }
  if (strcmp(value, "none") == 0) {
    pattern = PATTERN_NONE;
    return true;
  }
  return false;
}

bool getRequiredStringField(JsonDocument &doc, const char *field, const char *&value, char *reason, size_t reasonSize) {
  if (!doc.containsKey(field)) {
    setRejectReasonField(reason, reasonSize, "missing field: ", field);
    return false;
  }

  JsonVariant variant = doc[field];
  if (!variant.is<const char *>()) {
    setRejectReasonField(reason, reasonSize, "wrong type: ", field);
    return false;
  }

  value = variant.as<const char *>();
  return true;
}

bool getRequiredIntField(JsonDocument &doc, const char *field, long minValue, long maxValue, long &value, char *reason,
                         size_t reasonSize) {
  if (!doc.containsKey(field)) {
    setRejectReasonField(reason, reasonSize, "missing field: ", field);
    return false;
  }

  JsonVariant variant = doc[field];
  if (!variant.is<long>()) {
    setRejectReasonField(reason, reasonSize, "wrong type: ", field);
    return false;
  }

  long parsedValue = variant.as<long>();
  if (parsedValue < minValue || parsedValue > maxValue) {
    setRejectReasonField(reason, reasonSize, "out of range: ", field);
    return false;
  }

  value = parsedValue;
  return true;
}

bool getRequiredFloatField(JsonDocument &doc, const char *field, float minValue, float maxValue, float &value, char *reason,
                           size_t reasonSize) {
  if (!doc.containsKey(field)) {
    setRejectReasonField(reason, reasonSize, "missing field: ", field);
    return false;
  }

  JsonVariant variant = doc[field];
  if (!variant.is<float>() && !variant.is<double>() && !variant.is<long>()) {
    setRejectReasonField(reason, reasonSize, "wrong type: ", field);
    return false;
  }

  float parsedValue = variant.as<float>();
  if (parsedValue < minValue || parsedValue > maxValue) {
    setRejectReasonField(reason, reasonSize, "out of range: ", field);
    return false;
  }

  value = parsedValue;
  return true;
}

bool getDistanceField(JsonDocument &doc, bool &hasDistance, float &distanceMeters, char *reason, size_t reasonSize) {
  if (!doc.containsKey("distance")) {
    setRejectReason(reason, reasonSize, "missing field: distance");
    return false;
  }

  JsonVariant variant = doc["distance"];
  if (variant.isNull()) {
    hasDistance = false;
    distanceMeters = 0.0f;
    return true;
  }

  if (!variant.is<float>() && !variant.is<double>() && !variant.is<long>()) {
    setRejectReason(reason, reasonSize, "wrong type: distance");
    return false;
  }

  float parsedDistance = variant.as<float>();
  if (parsedDistance < 0.0f) {
    setRejectReason(reason, reasonSize, "out of range: distance");
    return false;
  }

  hasDistance = true;
  distanceMeters = parsedDistance;
  return true;
}

bool parseAndValidateCommandPayload(const uint8_t *payload, size_t length, VestCommand &commandOut, bool hasLastSeq,
                                    uint32_t lastSeq, char *reason, size_t reasonSize) {
  StaticJsonDocument<JSON_DOC_CAPACITY> doc;
  DeserializationError error = deserializeJson(doc, payload, length);
  if (error) {
    setRejectReason(reason, reasonSize, "malformed JSON");
    return false;
  }

  const char *modeStr = nullptr;
  const char *directionStr = nullptr;
  const char *patternStr = nullptr;
  long intensity = 0;
  long priority = 0;
  long ttlMs = 0;
  long seqValue = 0;
  float confidence = 0.0f;

  if (!getRequiredStringField(doc, "mode", modeStr, reason, reasonSize)) {
    return false;
  }
  if (!parseModeString(modeStr, commandOut.mode)) {
    setRejectReason(reason, reasonSize, "unknown mode");
    return false;
  }

  if (!getRequiredStringField(doc, "direction", directionStr, reason, reasonSize)) {
    return false;
  }
  if (!parseDirectionString(directionStr, commandOut.direction)) {
    setRejectReason(reason, reasonSize, "unknown direction");
    return false;
  }

  if (!getRequiredIntField(doc, "intensity", 0, 255, intensity, reason, reasonSize)) {
    return false;
  }
  commandOut.intensity = static_cast<uint8_t>(intensity);

  if (!getRequiredStringField(doc, "pattern", patternStr, reason, reasonSize)) {
    return false;
  }
  if (!parsePatternString(patternStr, commandOut.pattern)) {
    setRejectReason(reason, reasonSize, "unknown pattern");
    return false;
  }

  if (!getRequiredIntField(doc, "priority", 0, 3, priority, reason, reasonSize)) {
    return false;
  }
  commandOut.priority = static_cast<uint8_t>(priority);

  if (!getRequiredIntField(doc, "ttlMs", 1, 1000, ttlMs, reason, reasonSize)) {
    return false;
  }
  commandOut.ttlMs = static_cast<uint16_t>(ttlMs);

  if (!getRequiredFloatField(doc, "confidence", 0.0f, 1.0f, confidence, reason, reasonSize)) {
    return false;
  }
  commandOut.confidence = confidence;

  if (!getDistanceField(doc, commandOut.hasDistance, commandOut.distanceMeters, reason, reasonSize)) {
    return false;
  }

  if (!getRequiredIntField(doc, "seq", 0, 2147483647L, seqValue, reason, reasonSize)) {
    return false;
  }
  commandOut.seq = static_cast<uint32_t>(seqValue);

  if (hasLastSeq && commandOut.seq == lastSeq) {
    setRejectReason(reason, reasonSize, "duplicate seq");
    return false;
  }

  commandOut.receivedAtMs = 0;
  commandOut.expiresAtMs = 0;
  return true;
}

void logRejectedCommand(const char *reason) {
  Serial.print("REJECT: ");
  Serial.println(reason);
}

void stagePendingCommand(const VestCommand &command) {
  portENTER_CRITICAL(&gCommandMux);
  gPendingCommand.command = command;
  gPendingCommand.hasCommand = true;
  gSessionHasAcceptedSeq = true;
  gLastAcceptedSeq = command.seq;
  newCommandAvailable = true;
  portEXIT_CRITICAL(&gCommandMux);
}

void VisionVestCommandCallbacks::onWrite(NimBLECharacteristic *pCharacteristic, NimBLEConnInfo &connInfo) {
  (void)connInfo;

  std::string value = pCharacteristic->getValue();
  if (value.empty()) {
    logRejectedCommand("malformed JSON");
    return;
  }

  VestCommand parsedCommand = {};
  char rejectReason[REJECTION_REASON_SIZE] = {0};
  bool hasLastSeq = false;
  uint32_t lastSeq = 0;

  portENTER_CRITICAL(&gCommandMux);
  hasLastSeq = gSessionHasAcceptedSeq;
  lastSeq = gLastAcceptedSeq;
  portEXIT_CRITICAL(&gCommandMux);

  if (!parseAndValidateCommandPayload(reinterpret_cast<const uint8_t *>(value.data()), value.size(), parsedCommand, hasLastSeq, lastSeq,
                                      rejectReason, sizeof(rejectReason))) {
    logRejectedCommand(rejectReason);
    return;
  }

  stagePendingCommand(parsedCommand);
}

// ============================================================================
// 6. Command state manager
// ============================================================================

bool hasReachedTime(uint32_t now, uint32_t deadline) {
  return static_cast<int32_t>(now - deadline) >= 0;
}

void clearActiveCommand() {
  gActiveCommand = {};
  gHasActiveCommand = false;
}

void consumePendingCommand(uint32_t now) {
  VestCommand newCommand = {};
  bool hasPendingCommand = false;

  portENTER_CRITICAL(&gCommandMux);
  if (newCommandAvailable && gPendingCommand.hasCommand) {
    newCommand = gPendingCommand.command;
    gPendingCommand.hasCommand = false;
    newCommandAvailable = false;
    hasPendingCommand = true;
  }
  portEXIT_CRITICAL(&gCommandMux);

  if (!hasPendingCommand) {
    return;
  }

  newCommand.receivedAtMs = now;
  newCommand.expiresAtMs = now + newCommand.ttlMs;
  gCurrentMode = newCommand.mode;
  gActiveCommand = newCommand;
  gHasActiveCommand = true;
}

void expireCommandIfNeeded(uint32_t now) {
  if (!gHasActiveCommand) {
    return;
  }

  if (hasReachedTime(now, gActiveCommand.expiresAtMs)) {
    clearActiveCommand();
  }
}

uint32_t getActiveCommandRemainingMs(uint32_t now) {
  if (!gHasActiveCommand) {
    return 0;
  }

  if (hasReachedTime(now, gActiveCommand.expiresAtMs)) {
    return 0;
  }

  return gActiveCommand.expiresAtMs - now;
}

// ============================================================================
// 7. Ultrasonic sensor reader
// ============================================================================

float pulseWidthUsToDistanceCm(uint32_t pulseWidthUs) {
  return static_cast<float>(pulseWidthUs) / 58.0f;
}

void updateUltrasonicAverage(UltrasonicSensorState &sensor, float distanceCm) {
  sensor.samples[sensor.nextSampleIndex] = distanceCm;
  sensor.nextSampleIndex = (sensor.nextSampleIndex + 1) % ULTRASONIC_MOVING_AVERAGE_WINDOW;

  if (sensor.sampleCount < ULTRASONIC_MOVING_AVERAGE_WINDOW) {
    sensor.sampleCount++;
  }

  float sum = 0.0f;
  for (uint8_t i = 0; i < sensor.sampleCount; ++i) {
    sum += sensor.samples[i];
  }

  sensor.averagedCm = sum / static_cast<float>(sensor.sampleCount);
  sensor.hasValidAverage = true;
  sensor.invalidReadStreak = 0;
}

void clearUltrasonicAverage(UltrasonicSensorState &sensor) {
  sensor.sampleCount = 0;
  sensor.nextSampleIndex = 0;
  sensor.hasValidAverage = false;
  sensor.averagedCm = 0.0f;
  for (uint8_t i = 0; i < ULTRASONIC_MOVING_AVERAGE_WINDOW; ++i) {
    sensor.samples[i] = 0.0f;
  }
}

void finalizeUltrasonicMeasurement(UltrasonicSensorState &sensor, bool hasValidReading, float distanceCm) {
  if (hasValidReading && distanceCm > 0.0f && distanceCm <= ULTRASONIC_MAX_VALID_CM) {
    updateUltrasonicAverage(sensor, distanceCm);
  } else {
    if (sensor.invalidReadStreak < 255) {
      sensor.invalidReadStreak++;
    }

    // Clear stale hazard data after several bad reads so one noisy close hit
    // cannot latch the sensor in danger forever.
    if (sensor.invalidReadStreak >= ULTRASONIC_INVALID_CLEAR_COUNT) {
      clearUltrasonicAverage(sensor);
    }
  }

  sensor.state = US_IDLE;
  sensor.stateStartedUs = 0;
  sensor.measurementStartedUs = 0;
  sensor.echoRiseUs = 0;
  sensor.pendingDistanceCm = 0.0f;
  gActiveUltrasonicIndex = -1;
}

void startUltrasonicMeasurement(UltrasonicSensorState &sensor, uint32_t nowUs) {
  digitalWrite(sensor.trigPin, LOW);
  sensor.state = US_TRIGGER_LOW;
  sensor.stateStartedUs = nowUs;
  sensor.measurementStartedUs = nowUs;
  sensor.echoRiseUs = 0;
  sensor.pendingDistanceCm = 0.0f;
}

void updateActiveUltrasonicSensor(uint32_t nowUs) {
  if (gActiveUltrasonicIndex < 0 || gActiveUltrasonicIndex >= ULTRASONIC_SENSOR_COUNT) {
    return;
  }

  UltrasonicSensorState &sensor = gUltrasonicSensors[gActiveUltrasonicIndex];

  switch (sensor.state) {
    case US_TRIGGER_LOW:
      if (static_cast<uint32_t>(nowUs - sensor.stateStartedUs) >= ULTRASONIC_TRIGGER_LOW_US) {
        digitalWrite(sensor.trigPin, HIGH);
        sensor.state = US_TRIGGER_HIGH;
        sensor.stateStartedUs = nowUs;
      }
      break;

    case US_TRIGGER_HIGH:
      if (static_cast<uint32_t>(nowUs - sensor.stateStartedUs) >= ULTRASONIC_TRIGGER_HIGH_US) {
        digitalWrite(sensor.trigPin, LOW);
        sensor.state = US_WAIT_FOR_ECHO_RISE;
        sensor.stateStartedUs = nowUs;
        sensor.measurementStartedUs = nowUs;
      }
      break;

    case US_WAIT_FOR_ECHO_RISE:
      if (digitalRead(sensor.echoPin) == HIGH) {
        sensor.echoRiseUs = nowUs;
        sensor.state = US_WAIT_FOR_ECHO_FALL;
        sensor.stateStartedUs = nowUs;
      } else if (static_cast<uint32_t>(nowUs - sensor.measurementStartedUs) >= ULTRASONIC_ECHO_TIMEOUT_US) {
        sensor.state = US_TIMEOUT;
      }
      break;

    case US_WAIT_FOR_ECHO_FALL:
      if (digitalRead(sensor.echoPin) == LOW) {
        sensor.pendingDistanceCm = pulseWidthUsToDistanceCm(nowUs - sensor.echoRiseUs);
        sensor.state = US_COMPLETE;
      } else if (static_cast<uint32_t>(nowUs - sensor.echoRiseUs) >= ULTRASONIC_ECHO_TIMEOUT_US) {
        sensor.state = US_TIMEOUT;
      }
      break;

    case US_COMPLETE:
      finalizeUltrasonicMeasurement(sensor, true, sensor.pendingDistanceCm);
      break;

    case US_TIMEOUT:
      finalizeUltrasonicMeasurement(sensor, false, 0.0f);
      break;

    case US_IDLE:
    default:
      break;
  }
}

void updateUltrasonics(uint32_t nowMs) {
  updateActiveUltrasonicSensor(micros());

  if (gActiveUltrasonicIndex >= 0) {
    return;
  }

  if (nowMs != 0 && !hasReachedTime(nowMs, gLastUltrasonicStartMs + ULTRASONIC_START_INTERVAL_MS)) {
    return;
  }

  UltrasonicSensorState &sensor = gUltrasonicSensors[gNextUltrasonicIndex];
  startUltrasonicMeasurement(sensor, micros());
  gActiveUltrasonicIndex = gNextUltrasonicIndex;
  gNextUltrasonicIndex = (gNextUltrasonicIndex + 1) % ULTRASONIC_SENSOR_COUNT;
  gLastUltrasonicStartMs = nowMs;
}

HazardLevel classifyHazard(bool hasDistance, float distanceCm) {
  if (!hasDistance) {
    return SAFE;
  }
  if (distanceCm <= DANGER_THRESHOLD_CM) {
    return DANGER;
  }
  if (distanceCm <= CAUTION_THRESHOLD_CM) {
    return CAUTION;
  }
  return SAFE;
}

HazardState getHazardState() {
  HazardState state = {};

  state.backCm = gUltrasonicSensors[0].hasValidAverage ? gUltrasonicSensors[0].averagedCm : 0.0f;
  state.leftCm = gUltrasonicSensors[1].hasValidAverage ? gUltrasonicSensors[1].averagedCm : 0.0f;
  state.rightCm = gUltrasonicSensors[2].hasValidAverage ? gUltrasonicSensors[2].averagedCm : 0.0f;

  state.back = classifyHazard(gUltrasonicSensors[0].hasValidAverage, state.backCm);
  state.left = classifyHazard(gUltrasonicSensors[1].hasValidAverage, state.leftCm);
  state.right = classifyHazard(gUltrasonicSensors[2].hasValidAverage, state.rightCm);

  return state;
}

// ============================================================================
// 8. Arbitration engine
// ============================================================================

static const uint8_t MOTOR_MASK_NONE = 0x00;
static const uint8_t MOTOR_MASK_BACK = 0x01;
static const uint8_t MOTOR_MASK_FRONT = 0x02;
static const uint8_t MOTOR_MASK_LEFT = 0x04;
static const uint8_t MOTOR_MASK_RIGHT = 0x08;

uint8_t motorMaskForDirection(Direction direction) {
  switch (direction) {
    case DIR_BACK:
      return MOTOR_MASK_BACK;
    case DIR_FRONT:
      return MOTOR_MASK_FRONT;
    case DIR_LEFT:
      return MOTOR_MASK_LEFT;
    case DIR_RIGHT:
      return MOTOR_MASK_RIGHT;
    case DIR_FRONT_LEFT:
      return MOTOR_MASK_FRONT | MOTOR_MASK_LEFT;
    case DIR_FRONT_RIGHT:
      return MOTOR_MASK_FRONT | MOTOR_MASK_RIGHT;
    case DIR_BACK_LEFT:
      return MOTOR_MASK_BACK | MOTOR_MASK_LEFT;
    case DIR_BACK_RIGHT:
      return MOTOR_MASK_BACK | MOTOR_MASK_RIGHT;
    case DIR_NONE:
    default:
      return MOTOR_MASK_NONE;
  }
}

Direction singleDirectionForMotorMask(uint8_t motorMask) {
  switch (motorMask) {
    case MOTOR_MASK_BACK:
      return DIR_BACK;
    case MOTOR_MASK_FRONT:
      return DIR_FRONT;
    case MOTOR_MASK_LEFT:
      return DIR_LEFT;
    case MOTOR_MASK_RIGHT:
      return DIR_RIGHT;
    case MOTOR_MASK_FRONT | MOTOR_MASK_LEFT:
      return DIR_FRONT_LEFT;
    case MOTOR_MASK_FRONT | MOTOR_MASK_RIGHT:
      return DIR_FRONT_RIGHT;
    case MOTOR_MASK_BACK | MOTOR_MASK_LEFT:
      return DIR_BACK_LEFT;
    case MOTOR_MASK_BACK | MOTOR_MASK_RIGHT:
      return DIR_BACK_RIGHT;
    case MOTOR_MASK_NONE:
    default:
      return DIR_NONE;
  }
}

uint8_t ultrasonicMotorMaskForLevel(const HazardState &hazardState, HazardLevel level) {
  uint8_t motorMask = MOTOR_MASK_NONE;
  if (hazardState.back == level) {
    motorMask |= MOTOR_MASK_BACK;
  }
  if (hazardState.left == level) {
    motorMask |= MOTOR_MASK_LEFT;
  }
  if (hazardState.right == level) {
    motorMask |= MOTOR_MASK_RIGHT;
  }
  return motorMask;
}

HapticOutput makeIdleOutput() {
  HapticOutput output = {DIR_NONE, 0, PATTERN_NONE, 0, "idle", MOTOR_MASK_NONE};
  return output;
}

bool hasEffectivePhoneOutput() {
  return gHasActiveCommand && gActiveCommand.direction != DIR_NONE && gActiveCommand.pattern != PATTERN_NONE &&
         gActiveCommand.intensity > 0;
}

bool isUltrasonicAwarenessActive() {
  return gCurrentMode == AWARENESS;
}

HazardState getEffectiveHazardStateForAwareness(const HazardState &rawHazardState) {
  if (isUltrasonicAwarenessActive()) {
    return rawHazardState;
  }

  HazardState disabledHazards = {SAFE, SAFE, SAFE, rawHazardState.backCm, rawHazardState.leftCm, rawHazardState.rightCm};
  return disabledHazards;
}

HapticOutput arbitrate(const HazardState &hazardState) {
  uint8_t dangerMask = ultrasonicMotorMaskForLevel(hazardState, DANGER);
  if (dangerMask != MOTOR_MASK_NONE) {
    return {singleDirectionForMotorMask(dangerMask), 255, PATTERN_FAST_PULSE, 3, "ultrasonic_danger", dangerMask};
  }

  uint8_t cautionMask = ultrasonicMotorMaskForLevel(hazardState, CAUTION);
  if (cautionMask != MOTOR_MASK_NONE) {
    return {singleDirectionForMotorMask(cautionMask), 180, PATTERN_SLOW_PULSE, 2, "ultrasonic_caution", cautionMask};
  }

  if (hasEffectivePhoneOutput()) {
    return {gActiveCommand.direction, gActiveCommand.intensity, gActiveCommand.pattern, gActiveCommand.priority, "iphone",
            motorMaskForDirection(gActiveCommand.direction)};
  }

  return makeIdleOutput();
}

// ============================================================================
// 9. Haptic motor driver
// ============================================================================

void writeMotorDirectionPinsLow() {
  digitalWrite(BACK_IN1_PIN, LOW);
  digitalWrite(BACK_IN2_PIN, LOW);
  digitalWrite(FRONT_IN3_PIN, LOW);
  digitalWrite(FRONT_IN4_PIN, LOW);
  digitalWrite(LEFT_IN1_PIN, LOW);
  digitalWrite(LEFT_IN2_PIN, LOW);
  digitalWrite(RIGHT_IN3_PIN, LOW);
  digitalWrite(RIGHT_IN4_PIN, LOW);
}

void allMotorsOff() {
  ledcWriteChannel(MOTOR_PWM_CHANNEL_BACK, 0);
  ledcWriteChannel(MOTOR_PWM_CHANNEL_FRONT, 0);
  ledcWriteChannel(MOTOR_PWM_CHANNEL_LEFT, 0);
  ledcWriteChannel(MOTOR_PWM_CHANNEL_RIGHT, 0);
  writeMotorDirectionPinsLow();
  gCurrentMotorMask = MOTOR_MASK_NONE;
  gCurrentMotorDuty = 0;
}

void enableCardinalMotor(Direction direction, uint8_t intensity) {
  switch (direction) {
    case DIR_BACK:
      digitalWrite(BACK_IN1_PIN, HIGH);
      digitalWrite(BACK_IN2_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_BACK, intensity);
      break;
    case DIR_FRONT:
      digitalWrite(FRONT_IN3_PIN, HIGH);
      digitalWrite(FRONT_IN4_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_FRONT, intensity);
      break;
    case DIR_LEFT:
      digitalWrite(LEFT_IN1_PIN, HIGH);
      digitalWrite(LEFT_IN2_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_LEFT, intensity);
      break;
    case DIR_RIGHT:
      digitalWrite(RIGHT_IN3_PIN, HIGH);
      digitalWrite(RIGHT_IN4_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_RIGHT, intensity);
      break;
    case DIR_FRONT_LEFT:
    case DIR_FRONT_RIGHT:
    case DIR_BACK_LEFT:
    case DIR_BACK_RIGHT:
    case DIR_NONE:
    default:
      break;
  }
}

void driveMotorsForMask(uint8_t motorMask, uint8_t intensity) {
  if (motorMask == MOTOR_MASK_NONE || intensity == 0) {
    allMotorsOff();
    return;
  }

  allMotorsOff();

  if ((motorMask & MOTOR_MASK_BACK) != 0) {
    enableCardinalMotor(DIR_BACK, intensity);
  }
  if ((motorMask & MOTOR_MASK_FRONT) != 0) {
    enableCardinalMotor(DIR_FRONT, intensity);
  }
  if ((motorMask & MOTOR_MASK_LEFT) != 0) {
    enableCardinalMotor(DIR_LEFT, intensity);
  }
  if ((motorMask & MOTOR_MASK_RIGHT) != 0) {
    enableCardinalMotor(DIR_RIGHT, intensity);
  }

  gCurrentMotorMask = motorMask;
  gCurrentMotorDuty = intensity;
}

bool hapticOutputEquals(const HapticOutput &a, const HapticOutput &b) {
  return a.direction == b.direction && a.intensity == b.intensity && a.pattern == b.pattern && a.priority == b.priority &&
         a.motorMask == b.motorMask;
}

bool shouldPatternBeOn(const HapticOutput &output, uint32_t now) {
  switch (output.pattern) {
    case PATTERN_STEADY:
      return true;

    case PATTERN_SLOW_PULSE: {
      uint32_t elapsed = now - gPatternPhaseStartedMs;
      uint32_t cycle = SLOW_PULSE_ON_MS + SLOW_PULSE_OFF_MS;
      return (elapsed % cycle) < SLOW_PULSE_ON_MS;
    }

    case PATTERN_FAST_PULSE: {
      uint32_t elapsed = now - gPatternPhaseStartedMs;
      uint32_t cycle = FAST_PULSE_ON_MS + FAST_PULSE_OFF_MS;
      return (elapsed % cycle) < FAST_PULSE_ON_MS;
    }

    case PATTERN_NONE:
    default:
      return false;
  }
}

void applyHapticOutput(const HapticOutput &output, uint32_t now) {
  if (!hapticOutputEquals(output, gLastAppliedOutput)) {
    gPatternPhaseStartedMs = now;
    gLastAppliedOutput = output;
  }

  if (output.motorMask == MOTOR_MASK_NONE || output.pattern == PATTERN_NONE || output.intensity == 0) {
    allMotorsOff();
    return;
  }

  if (shouldPatternBeOn(output, now)) {
    driveMotorsForMask(output.motorMask, output.intensity);
  } else {
    allMotorsOff();
  }
}

// ============================================================================
// 10. NeoPixel status indicator
// ============================================================================

void setNeoPixelColor(uint8_t red, uint8_t green, uint8_t blue) {
  gNeoPixel.setPixelColor(0, gNeoPixel.Color(red, green, blue));
  gNeoPixel.show();
}

void updateNeoPixel(const HazardState &hazardState, bool bleConnected) {
  if (hazardState.back == DANGER || hazardState.left == DANGER || hazardState.right == DANGER) {
    setNeoPixelColor(COLOR_RED_R, COLOR_RED_G, COLOR_RED_B);
    return;
  }

  if (hazardState.back == CAUTION || hazardState.left == CAUTION || hazardState.right == CAUTION) {
    setNeoPixelColor(COLOR_YELLOW_R, COLOR_YELLOW_G, COLOR_YELLOW_B);
    return;
  }

  if (bleConnected) {
    setNeoPixelColor(COLOR_GREEN_R, COLOR_GREEN_G, COLOR_GREEN_B);
    return;
  }

  setNeoPixelColor(COLOR_BLUE_R, COLOR_BLUE_G, COLOR_BLUE_B);
}

// ============================================================================
// 11. Debug logger
// ============================================================================

const char *modeToString(Mode mode) {
  switch (mode) {
    case MANUAL:
      return "manual";
    case AWARENESS:
      return "awareness";
    case OBJECT_NAV:
      return "object_nav";
    case FIND_SEARCH:
      return "find_search";
    case GPS_NAV:
      return "gps_nav";
    default:
      return "unknown";
  }
}

const char *directionToString(Direction direction) {
  switch (direction) {
    case DIR_LEFT:
      return "left";
    case DIR_FRONT:
      return "front";
    case DIR_RIGHT:
      return "right";
    case DIR_BACK:
      return "back";
    case DIR_FRONT_LEFT:
      return "front-left";
    case DIR_FRONT_RIGHT:
      return "front-right";
    case DIR_BACK_LEFT:
      return "back-left";
    case DIR_BACK_RIGHT:
      return "back-right";
    case DIR_NONE:
      return "none";
    default:
      return "unknown";
  }
}

const char *patternToString(Pattern pattern) {
  switch (pattern) {
    case PATTERN_STEADY:
      return "steady";
    case PATTERN_SLOW_PULSE:
      return "slow_pulse";
    case PATTERN_FAST_PULSE:
      return "fast_pulse";
    case PATTERN_NONE:
      return "none";
    default:
      return "unknown";
  }
}

const char *hazardLevelToString(HazardLevel hazardLevel) {
  switch (hazardLevel) {
    case SAFE:
      return "SAFE";
    case CAUTION:
      return "CAUTION";
    case DANGER:
      return "DANGER";
    default:
      return "SAFE";
  }
}

void printMotorMaskLabel(uint8_t motorMask) {
  if (motorMask == MOTOR_MASK_NONE) {
    Serial.print("none");
    return;
  }

  bool printedOne = false;

  if ((motorMask & MOTOR_MASK_BACK) != 0) {
    Serial.print("back");
    printedOne = true;
  }
  if ((motorMask & MOTOR_MASK_FRONT) != 0) {
    if (printedOne) {
      Serial.print("+");
    }
    Serial.print("front");
    printedOne = true;
  }
  if ((motorMask & MOTOR_MASK_LEFT) != 0) {
    if (printedOne) {
      Serial.print("+");
    }
    Serial.print("left");
    printedOne = true;
  }
  if ((motorMask & MOTOR_MASK_RIGHT) != 0) {
    if (printedOne) {
      Serial.print("+");
    }
    Serial.print("right");
  }
}

void printDistanceField(bool hasDistance, float distanceCm) {
  if (!hasDistance) {
    Serial.print("n/a");
    return;
  }

  Serial.print(static_cast<int>(distanceCm + 0.5f));
  Serial.print("cm");
}

void printDebugLog(uint32_t now) {
  if (!hasReachedTime(now, gLastLogMs + LOG_INTERVAL_MS)) {
    return;
  }
  gLastLogMs = now;

  Serial.print("BLE: ");
  Serial.print(gBleConnected ? "connected" : "advertising");
  Serial.print(" | mode=");
  Serial.print(modeToString(gCurrentMode));
  Serial.print(" | seq=");
  if (gHasActiveCommand) {
    Serial.print(gActiveCommand.seq);
    Serial.print(" | cmd:");
    Serial.print(" dir=");
    Serial.print(directionToString(gActiveCommand.direction));
    Serial.print(" intensity=");
    Serial.print(gActiveCommand.intensity);
    Serial.print(" ttl=");
    Serial.print(gActiveCommand.ttlMs);
    Serial.print("ms remaining=");
    Serial.print(getActiveCommandRemainingMs(now));
    Serial.println("ms");
  } else {
    Serial.println("none | cmd: none");
  }

  Serial.print("US: back=");
  printDistanceField(gUltrasonicSensors[0].hasValidAverage, gCurrentHazardState.backCm);
  Serial.print(" ");
  Serial.print(hazardLevelToString(gCurrentHazardState.back));
  Serial.print(" | left=");
  printDistanceField(gUltrasonicSensors[1].hasValidAverage, gCurrentHazardState.leftCm);
  Serial.print(" ");
  Serial.print(hazardLevelToString(gCurrentHazardState.left));
  Serial.print(" | right=");
  printDistanceField(gUltrasonicSensors[2].hasValidAverage, gCurrentHazardState.rightCm);
  Serial.print(" ");
  Serial.println(hazardLevelToString(gCurrentHazardState.right));

  Serial.print("OUTPUT: source=");
  Serial.print(gCurrentOutput.source);
  Serial.print(" dir=");
  printMotorMaskLabel(gCurrentOutput.motorMask);
  Serial.print(" intensity=");
  Serial.print(gCurrentOutput.intensity);
  Serial.print(" pattern=");
  Serial.println(patternToString(gCurrentOutput.pattern));
}

// ============================================================================
// 12. setup() and loop()
// ============================================================================

void initNeoPixel() {
  gNeoPixel.begin();
  gNeoPixel.clear();
  gNeoPixel.show();
}

void initMotorPins() {
  pinMode(BACK_IN1_PIN, OUTPUT);
  pinMode(BACK_IN2_PIN, OUTPUT);
  pinMode(FRONT_IN3_PIN, OUTPUT);
  pinMode(FRONT_IN4_PIN, OUTPUT);
  pinMode(LEFT_IN1_PIN, OUTPUT);
  pinMode(LEFT_IN2_PIN, OUTPUT);
  pinMode(RIGHT_IN3_PIN, OUTPUT);
  pinMode(RIGHT_IN4_PIN, OUTPUT);
  writeMotorDirectionPinsLow();
}

void initLEDC() {
  if (!ledcAttachChannel(BACK_ENA_PIN, LEDC_FREQUENCY_HZ, LEDC_RESOLUTION_BITS, MOTOR_PWM_CHANNEL_BACK)) {
    Serial.println("WARN: failed to attach BACK PWM");
  }
  if (!ledcAttachChannel(FRONT_ENB_PIN, LEDC_FREQUENCY_HZ, LEDC_RESOLUTION_BITS, MOTOR_PWM_CHANNEL_FRONT)) {
    Serial.println("WARN: failed to attach FRONT PWM");
  }
  if (!ledcAttachChannel(LEFT_ENA_PIN, LEDC_FREQUENCY_HZ, LEDC_RESOLUTION_BITS, MOTOR_PWM_CHANNEL_LEFT)) {
    Serial.println("WARN: failed to attach LEFT PWM");
  }
  if (!ledcAttachChannel(RIGHT_ENB_PIN, LEDC_FREQUENCY_HZ, LEDC_RESOLUTION_BITS, MOTOR_PWM_CHANNEL_RIGHT)) {
    Serial.println("WARN: failed to attach RIGHT PWM");
  }
  allMotorsOff();
}

void initUltrasonics() {
  for (uint8_t i = 0; i < ULTRASONIC_SENSOR_COUNT; ++i) {
    pinMode(gUltrasonicSensors[i].trigPin, OUTPUT);
    pinMode(gUltrasonicSensors[i].echoPin, INPUT);
    digitalWrite(gUltrasonicSensors[i].trigPin, LOW);
    gUltrasonicSensors[i].sampleCount = 0;
    gUltrasonicSensors[i].nextSampleIndex = 0;
    gUltrasonicSensors[i].hasValidAverage = false;
    gUltrasonicSensors[i].averagedCm = 0.0f;
    gUltrasonicSensors[i].state = US_IDLE;
    gUltrasonicSensors[i].stateStartedUs = 0;
    gUltrasonicSensors[i].measurementStartedUs = 0;
    gUltrasonicSensors[i].echoRiseUs = 0;
    gUltrasonicSensors[i].pendingDistanceCm = 0.0f;
    gUltrasonicSensors[i].invalidReadStreak = 0;
  }
  gActiveUltrasonicIndex = -1;
  gNextUltrasonicIndex = 0;
  gLastUltrasonicStartMs = 0;
}

void initBLE() {
  NimBLEDevice::init(BLE_DEVICE_NAME);

  gBleServer = NimBLEDevice::createServer();
  if (gBleServer == nullptr) {
    Serial.println("WARN: failed to create BLE server");
    return;
  }
  gBleServer->setCallbacks(&gServerCallbacks);

  NimBLEService *service = gBleServer->createService(BLE_SERVICE_UUID);
  if (service == nullptr) {
    Serial.println("WARN: failed to create BLE service");
    return;
  }
  gCommandCharacteristic = service->createCharacteristic(BLE_COMMAND_CHAR_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR,
                                                         BLE_COMMAND_MAX_LEN);
  if (gCommandCharacteristic == nullptr) {
    Serial.println("WARN: failed to create BLE characteristic");
    return;
  }
  gCommandCharacteristic->setCallbacks(&gCommandCallbacks);
  service->start();

  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  if (advertising == nullptr) {
    Serial.println("WARN: failed to get BLE advertising");
    return;
  }
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setName(BLE_DEVICE_NAME);
  advertising->enableScanResponse(true);
  advertising->start();
}

void setup() {
  Serial.begin(SERIAL_BAUD_RATE);
  initNeoPixel();
  initMotorPins();
  initLEDC();
  initUltrasonics();
  initBLE();
  gCurrentMode = AWARENESS;
  clearActiveCommand();
  gCurrentHazardState = getHazardState();
  gCurrentOutput = makeIdleOutput();
  gLastAppliedOutput = makeIdleOutput();
  gPatternPhaseStartedMs = millis();
  updateNeoPixel(gCurrentHazardState, gBleConnected);
}

void loop() {
  uint32_t now = millis();
  updateUltrasonics(now);
  consumePendingCommand(now);
  expireCommandIfNeeded(now);
  gCurrentHazardState = getHazardState();
  HazardState effectiveHazardState = getEffectiveHazardStateForAwareness(gCurrentHazardState);
  gCurrentOutput = arbitrate(effectiveHazardState);
  applyHapticOutput(gCurrentOutput, now);
  updateNeoPixel(effectiveHazardState, gBleConnected);
  printDebugLog(now);
}
