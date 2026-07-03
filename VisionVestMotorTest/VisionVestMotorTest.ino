#include <Arduino.h>
#include <esp32-hal-ledc.h>

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

static const uint32_t SERIAL_BAUD_RATE = 115200;
static const uint32_t LEDC_FREQUENCY_HZ = 5000;
static const uint8_t LEDC_RESOLUTION_BITS = 8;
static const uint8_t MOTOR_PWM_CHANNEL_BACK = 0;
static const uint8_t MOTOR_PWM_CHANNEL_FRONT = 1;
static const uint8_t MOTOR_PWM_CHANNEL_LEFT = 2;
static const uint8_t MOTOR_PWM_CHANNEL_RIGHT = 3;

static const uint8_t TEST_INTENSITY = 220;
static const uint32_t MOTOR_ON_MS = 1500;
static const uint32_t MOTOR_OFF_MS = 800;

enum TestMotor {
  TEST_BACK,
  TEST_FRONT,
  TEST_LEFT,
  TEST_RIGHT
};

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

void runMotor(TestMotor motor, uint8_t intensity) {
  allMotorsOff();

  switch (motor) {
    case TEST_BACK:
      digitalWrite(BACK_IN1_PIN, HIGH);
      digitalWrite(BACK_IN2_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_BACK, intensity);
      break;
    case TEST_FRONT:
      digitalWrite(FRONT_IN3_PIN, HIGH);
      digitalWrite(FRONT_IN4_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_FRONT, intensity);
      break;
    case TEST_LEFT:
      digitalWrite(LEFT_IN1_PIN, HIGH);
      digitalWrite(LEFT_IN2_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_LEFT, intensity);
      break;
    case TEST_RIGHT:
      digitalWrite(RIGHT_IN3_PIN, HIGH);
      digitalWrite(RIGHT_IN4_PIN, LOW);
      ledcWriteChannel(MOTOR_PWM_CHANNEL_RIGHT, intensity);
      break;
    default:
      break;
  }
}

void testMotor(const char *label, TestMotor motor) {
  Serial.print("TESTING: ");
  Serial.println(label);
  runMotor(motor, TEST_INTENSITY);
  delay(MOTOR_ON_MS);
  allMotorsOff();
  delay(MOTOR_OFF_MS);
}

void setup() {
  Serial.begin(SERIAL_BAUD_RATE);
  initMotorPins();
  initLEDC();

  Serial.println();
  Serial.println("VisionVest motor test starting...");
  Serial.println("Expected order: BACK -> FRONT -> LEFT -> RIGHT");
}

void loop() {
  testMotor("BACK", TEST_BACK);
  testMotor("FRONT", TEST_FRONT);
  testMotor("LEFT", TEST_LEFT);
  testMotor("RIGHT", TEST_RIGHT);

  Serial.println("Cycle complete.");
  delay(1500);
}
