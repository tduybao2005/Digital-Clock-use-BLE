#include "BleProvisioning.h"
#include <WiFi.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLESecurity.h>

// =======================================================================
// 1. UUIDs CHUẨN HÓA CHO PROVISIONING
// =======================================================================
static const char* PROV_SERVICE_UUID   = "0000FF01-0000-1000-8000-00805F9B34FB";
static const char* SSID_CHAR_UUID      = "0000FF02-0000-1000-8000-00805F9B34FB";
static const char* PASSWORD_CHAR_UUID  = "0000FF03-0000-1000-8000-00805F9B34FB";
static const char* CONNECT_CHAR_UUID   = "0000FF04-0000-1000-8000-00805F9B34FB";
// Characteristic mới báo trạng thái Wi-Fi
static const char* STATUS_CHAR_UUID    = "0000FF05-0000-1000-8000-00805F9B34FB";

// =======================================================================
// 2. BIẾN TOÀN CỤC
// =======================================================================
String ssid_from_client = "";
String pass_from_client = "";

bool wifi_provisioned = false;
bool connected_to_client = false;

BLEServer   *pServer   = nullptr;
BLEService  *pService  = nullptr;
BLECharacteristic *statusChar = nullptr;  // FF05

// =======================================================================
// 3. SECURITY CALLBACKS (TỐI GIẢN)
// =======================================================================
class MySecurityCallbacks : public BLESecurityCallbacks {
public:
  uint32_t onPassKeyRequest() {
    Serial.println("[SEC] PassKeyRequest -> return 0");
    return 0;
  }

  void onPassKeyNotify(uint32_t pass_key) {
    Serial.printf("[SEC] PassKeyNotify: %u\n", pass_key);
  }

  bool onSecurityRequest() {
    Serial.println("[SEC] SecurityRequest");
    return true; // chấp nhận yêu cầu security từ client
  }

  bool onConfirmPIN(uint32_t pin) {
    Serial.printf("[SEC] ConfirmPIN: %u\n", pin);
    return true;
  }
};

// =======================================================================
// 4. CALLBACK CHARACTERISTIC
// =======================================================================
class MyProvisioningCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    Serial.println("[BLE] onWrite CALLED");

    String uuid = pCharacteristic->getUUID().toString();
    String value = pCharacteristic->getValue();

    Serial.print("[BLE] UUID = ");
    Serial.println(uuid);
    Serial.print("[BLE] Raw value length = ");
    Serial.println(value.length());

    String uuidLower = uuid;
    uuidLower.toLowerCase();

    if (uuidLower == String("0000ff02-0000-1000-8000-00805f9b34fb")) {
      ssid_from_client = value;
      Serial.print("[BLE] Received SSID: ");
      Serial.println(ssid_from_client);

    } else if (uuidLower == String("0000ff03-0000-1000-8000-00805f9b34fb")) {
      pass_from_client = value;
      Serial.print("[BLE] Received Password length: ");
      Serial.println(pass_from_client.length());

    } else if (uuidLower == String("0000ff04-0000-1000-8000-00805f9b34fb")) {
      Serial.println("[BLE] Received CONNECT command. Will try WiFi...");
      wifi_provisioned = true;

    } else {
      Serial.println("[BLE] onWrite for unknown characteristic");
    }
  }
};

// =======================================================================
// 5. CALLBACK SERVER (CONNECT / DISCONNECT)
// =======================================================================
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *pServer) {
    connected_to_client = true;
    Serial.println("[BLE] Client connected");
  }

  void onDisconnect(BLEServer *pServer) {
    connected_to_client = false;
    Serial.println("[BLE] Client disconnected, restart advertising");
    BLEDevice::startAdvertising();
  }
};

// =======================================================================
// HÀM TRIM CHUỖI (BỎ KHOẢNG TRẮNG ĐẦU / CUỐI)
// =======================================================================
String trimString(const String &s) {
  int start = 0;
  int end = s.length() - 1;
  while (start <= end && isspace((unsigned char)s[start])) start++;
  while (end >= start && isspace((unsigned char)s[end])) end--;
  if (start > end) return "";
  return s.substring(start, end + 1);
}

// =======================================================================
// 6. bleProvInit: thay cho setup() phần BLE + Wi-Fi provisioning
// =======================================================================
void bleProvInit() {
  // Serial.begin sẽ đặt trong fingerprint.ino
  Serial.println();
  Serial.println("===== ESP32-C6 BLE WiFi Provisioning (SECURED, NO WRITE_ENCRYPTED) =====");

  BLEDevice::init("FP_Sensor_Front_01");

  BLESecurity *pSecurity = new BLESecurity();
  BLEDevice::setSecurityCallbacks(new MySecurityCallbacks());

  pSecurity->setAuthenticationMode(ESP_LE_AUTH_REQ_SC_BOND);
  pSecurity->setCapability(ESP_IO_CAP_NONE);
  pSecurity->setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  pService = pServer->createService(BLEUUID(PROV_SERVICE_UUID));

  MyProvisioningCallbacks *charCallbacks = new MyProvisioningCallbacks();

  BLECharacteristic *ssidChar = pService->createCharacteristic(
      BLEUUID(SSID_CHAR_UUID),
      BLECharacteristic::PROPERTY_WRITE);
  ssidChar->setAccessPermissions(ESP_GATT_PERM_WRITE);
  ssidChar->setCallbacks(charCallbacks);

  BLECharacteristic *passChar = pService->createCharacteristic(
      BLEUUID(PASSWORD_CHAR_UUID),
      BLECharacteristic::PROPERTY_WRITE);
  passChar->setAccessPermissions(ESP_GATT_PERM_WRITE);
  passChar->setCallbacks(charCallbacks);

  BLECharacteristic *connectChar = pService->createCharacteristic(
      BLEUUID(CONNECT_CHAR_UUID),
      BLECharacteristic::PROPERTY_WRITE);
  connectChar->setAccessPermissions(ESP_GATT_PERM_WRITE);
  connectChar->setCallbacks(charCallbacks);

  statusChar = pService->createCharacteristic(
      BLEUUID(STATUS_CHAR_UUID),
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  statusChar->setAccessPermissions(ESP_GATT_PERM_READ);
  statusChar->setValue("idle");

  pService->start();

  BLEAdvertising *pAdvertising = pServer->getAdvertising();
  pAdvertising->addServiceUUID(BLEUUID(PROV_SERVICE_UUID));
  pAdvertising->setScanResponse(true);

  BLEDevice::startAdvertising();

  Serial.println("[BLE] Advertising started (SECURED, NO WRITE_ENCRYPTED). Open phone app to scan & pair.");
  Serial.println("FW VERSION: 2025-12-15-SECURE-FF01-NOENC");
}

// =======================================================================
// 7. bleProvLoop: thay cho loop() phần BLE + Wi-Fi provisioning
// =======================================================================
void bleProvLoop() {
  if (wifi_provisioned) {
    wifi_provisioned = false;

    String ssid_trimmed = trimString(ssid_from_client);
    String pass_trimmed = trimString(pass_from_client);

    Serial.print("[WiFi] Connecting to: ");
    Serial.println(ssid_trimmed);
    Serial.print("[WiFi] Password length: ");
    Serial.println(pass_trimmed.length());

    if (statusChar != nullptr) {
      statusChar->setValue("connecting");
      statusChar->notify();
    }

    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid_trimmed.c_str(), pass_trimmed.c_str());

    int attempts = 0;
    const int maxAttempts = 60;
    while (WiFi.status() != WL_CONNECTED && attempts < maxAttempts) {
      delay(500);
      Serial.print(".");
      attempts++;
    }

    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("\n[WiFi] Connected!");
      Serial.print("[WiFi] IP: ");
      Serial.println(WiFi.localIP());

      if (statusChar != nullptr) {
        String msg = "connected:" + WiFi.localIP().toString();
        statusChar->setValue(msg.c_str());
        statusChar->notify();
      }
    } else {
      Serial.println("\n[WiFi] Connection FAILED. Keep advertising for retry.");

      if (statusChar != nullptr) {
        statusChar->setValue("failed");
        statusChar->notify();
      }

      BLEDevice::startAdvertising();
    }
  }

  // nếu muốn, có thể bỏ delay(200) để loop ngoài tự điều tiết
}

