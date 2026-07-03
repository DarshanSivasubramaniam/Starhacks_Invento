#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <NimBLEDevice.h>
#include <string>

static const char *BLE_DEVICE_NAME = "VisionVest";
static const char *BLE_SERVICE_UUID = "7B7E1000-7C6B-4B8F-9E2A-6B5F4F0A1000";
static const char *BLE_COMMAND_CHAR_UUID = "7B7E1001-7C6B-4B8F-9E2A-6B5F4F0A1000";

static const uint8_t NEOPIXEL_PIN = 38;
static const uint8_t NEOPIXEL_COUNT = 1;
static const uint32_t SERIAL_BAUD_RATE = 115200;
static const uint32_t STATUS_LOG_INTERVAL_MS = 1000;
static const uint16_t BLE_COMMAND_MAX_LEN = 256;

Adafruit_NeoPixel gNeoPixel(NEOPIXEL_COUNT, NEOPIXEL_PIN, NEO_GRB + NEO_KHZ800);

NimBLEServer *gBleServer = nullptr;
NimBLECharacteristic *gCommandCharacteristic = nullptr;

volatile bool gBleConnected = false;
volatile bool gSawWrite = false;
volatile uint32_t gWriteCount = 0;

std::string gLastWriteValue;
uint32_t gLastStatusLogMs = 0;
uint32_t gLastWriteSeenMs = 0;

void setPixelColor(uint8_t red, uint8_t green, uint8_t blue) {
  gNeoPixel.setPixelColor(0, gNeoPixel.Color(red, green, blue));
  gNeoPixel.show();
}

void updateStatusPixel(uint32_t now) {
  if (gSawWrite && (now - gLastWriteSeenMs) < 300) {
    setPixelColor(255, 255, 255);
    return;
  }

  if (gBleConnected) {
    setPixelColor(0, 255, 0);
    return;
  }

  setPixelColor(0, 0, 255);
}

class ConnectionCallbacks : public NimBLEServerCallbacks {
 public:
  void onConnect(NimBLEServer *pServer, NimBLEConnInfo &connInfo) override {
    (void)pServer;
    (void)connInfo;
    gBleConnected = true;
    Serial.println("BLE connected");
  }

  void onDisconnect(NimBLEServer *pServer, NimBLEConnInfo &connInfo, int reason) override {
    (void)connInfo;
    Serial.print("BLE disconnected, reason=");
    Serial.println(reason);
    gBleConnected = false;

    NimBLEAdvertising *advertising = pServer->getAdvertising();
    if (advertising != nullptr) {
      advertising->start();
    }
  }
};

class CommandCallbacks : public NimBLECharacteristicCallbacks {
 public:
  void onWrite(NimBLECharacteristic *pCharacteristic, NimBLEConnInfo &connInfo) override {
    (void)connInfo;

    gLastWriteValue = pCharacteristic->getValue();
    gWriteCount++;
    gSawWrite = true;
    gLastWriteSeenMs = millis();

    Serial.print("Write received #");
    Serial.print(gWriteCount);
    Serial.print(": ");
    Serial.println(gLastWriteValue.c_str());
  }
};

ConnectionCallbacks gConnectionCallbacks;
CommandCallbacks gCommandCallbacks;

void initBle() {
  NimBLEDevice::init(BLE_DEVICE_NAME);

  gBleServer = NimBLEDevice::createServer();
  if (gBleServer == nullptr) {
    Serial.println("Failed to create BLE server");
    return;
  }

  gBleServer->setCallbacks(&gConnectionCallbacks);

  NimBLEService *service = gBleServer->createService(BLE_SERVICE_UUID);
  if (service == nullptr) {
    Serial.println("Failed to create BLE service");
    return;
  }

  gCommandCharacteristic = service->createCharacteristic(
      BLE_COMMAND_CHAR_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, BLE_COMMAND_MAX_LEN);
  if (gCommandCharacteristic == nullptr) {
    Serial.println("Failed to create BLE characteristic");
    return;
  }

  gCommandCharacteristic->setCallbacks(&gCommandCallbacks);
  service->start();

  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  if (advertising == nullptr) {
    Serial.println("Failed to get BLE advertising");
    return;
  }

  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setName(BLE_DEVICE_NAME);
  advertising->enableScanResponse(true);
  advertising->start();

  Serial.println("BLE advertising started");
  Serial.print("Device name: ");
  Serial.println(BLE_DEVICE_NAME);
  Serial.print("Service UUID: ");
  Serial.println(BLE_SERVICE_UUID);
  Serial.print("Characteristic UUID: ");
  Serial.println(BLE_COMMAND_CHAR_UUID);
}

void printStatusLog(uint32_t now) {
  if ((now - gLastStatusLogMs) < STATUS_LOG_INTERVAL_MS) {
    return;
  }

  gLastStatusLogMs = now;
  Serial.print("Status: ");
  Serial.print(gBleConnected ? "connected" : "advertising");
  Serial.print(" | writes=");
  Serial.print(gWriteCount);
  Serial.print(" | last_write=");
  if (gLastWriteValue.empty()) {
    Serial.println("none");
  } else {
    Serial.println(gLastWriteValue.c_str());
  }
}

void setup() {
  Serial.begin(SERIAL_BAUD_RATE);

  gNeoPixel.begin();
  gNeoPixel.clear();
  gNeoPixel.show();

  initBle();
  updateStatusPixel(millis());
}

void loop() {
  uint32_t now = millis();

  if (gSawWrite && (now - gLastWriteSeenMs) >= 300) {
    gSawWrite = false;
  }

  updateStatusPixel(now);
  printStatusLog(now);
}
