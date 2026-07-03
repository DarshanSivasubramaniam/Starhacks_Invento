#include <Arduino.h>
#include <Adafruit_NeoPixel.h>

static const uint8_t NEOPIXEL_PIN = 38;
static const uint8_t NEOPIXEL_COUNT = 1;
static const uint32_t COLOR_INTERVAL_MS = 500;
static const uint32_t SERIAL_BAUD_RATE = 115200;

Adafruit_NeoPixel gNeoPixel(NEOPIXEL_COUNT, NEOPIXEL_PIN, NEO_GRB + NEO_KHZ800);

uint32_t gLastStepMs = 0;
uint8_t gColorStep = 0;

void showColor(uint8_t red, uint8_t green, uint8_t blue, const char *name) {
  gNeoPixel.setPixelColor(0, gNeoPixel.Color(red, green, blue));
  gNeoPixel.show();
  Serial.print("NeoPixel: ");
  Serial.println(name);
}

void setup() {
  Serial.begin(SERIAL_BAUD_RATE);
  gNeoPixel.begin();
  gNeoPixel.clear();
  gNeoPixel.show();
}

void loop() {
  uint32_t now = millis();
  if ((now - gLastStepMs) < COLOR_INTERVAL_MS) {
    return;
  }

  gLastStepMs = now;

  switch (gColorStep) {
    case 0:
      showColor(255, 0, 0, "red");
      break;
    case 1:
      showColor(0, 255, 0, "green");
      break;
    case 2:
      showColor(0, 0, 255, "blue");
      break;
    default:
      showColor(0, 0, 0, "off");
      break;
  }

  gColorStep = (gColorStep + 1) % 4;
}
