#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>

#include "BleProvisioning.h"
#include "FingerprintSensor.h"

// ================= WEB SERVER =================
WebServer server(80);

// ================= FP STATE =================
enum FPState {
  FP_IDLE,
  FP_SCANNING,
  FP_DONE
};

volatile FPState fpState = FP_IDLE;
volatile bool fpImageReady = false;
String fpLastError = "";  // Not volatile - String doesn't work well with volatile

// ================= SETUP =================
void setup() {
  Serial.begin(115200);
  delay(300);

  Serial.println("\n=== ESP32-C6 AS608 FINGERPRINT SERVER ===");

  // BLE dùng để nhận WiFi SSID / PASS
  bleProvInit();

  // Fingerprint
  fpInit();

  // Register server handler callback - cho phép fpLoop() xử lý HTTP requests
  fpSetServerHandler([]() {
    server.handleClient();
  });

  // HTTP API
  server.on("/fpcontrol", handleFpControl);
  server.on("/fpstatus", handleFpStatus);
  server.on("/fpimage", handleFpImage);
  server.on("/fpsensortest", handleFpSensorTest);  // Diagnostic endpoint
  server.on("/fpimageinfo", handleFpImageInfo);    // Check image size

  Serial.println("[SYS] Setup done");
}

// ================= LOOP =================
void loop() {
  // BLE provisioning loop
  bleProvLoop();

  // Start web server sau khi có WiFi
  static bool webStarted = false;
  if (WiFi.isConnected() && !webStarted) {
    server.begin();
    webStarted = true;
    Serial.println("[WEB] HTTP server started");
  }

  // ================= HTTP SERVER HANDLING =================
  // IMPORTANT: Gọi server.handleClient() TRƯỚC mọi thứ
  // để app có thể gửi /fpcontrol?cmd=start request
  // và poll /fpstatus trong khi sensor scanning
  if (webStarted) {
    server.handleClient();
  }

  // ================= SINGLE SHOT SCAN =================
  // fpLoop() sẽ gọi server.handleClient() via callback
  // để app có thể poll /fpstatus trong khi sensor đang scan
  if (fpState == FP_SCANNING) {
    Serial.println("[FP] Scan session started");

    bool ok = fpLoop();   // GenImg + Image2Tz + Download (gọi serverHandler() định kỳ)

    if (ok) {
      fpImageReady = true;
      fpLastError = "";
      Serial.println("[FP] Fingerprint image ready");
    } else {
      fpImageReady = false;
      fpLastError = "Scan failed - check sensor and finger placement";
      Serial.println("[FP] Scan failed or no finger");
    }

    fpState = FP_DONE;   // kết thúc phiên
  }
}

// ================= HTTP HANDLERS =================

// ---- START SCAN ----
void handleFpControl() {
  if (!server.hasArg("cmd")) {
    server.send(400, "text/plain", "Missing cmd");
    return;
  }

  if (server.arg("cmd") == "start") { 
    if (fpState == FP_IDLE) {
      fpState = FP_SCANNING;
      fpImageReady = false;

      Serial.println("[WEB] FP START command");
      server.send(200, "text/plain", "FP scan started");
    } else {
      server.send(409, "text/plain", "FP busy");
    }
  } else if (server.arg("cmd") == "reset") {
    fpState = FP_IDLE;
    fpImageReady = false;
    Serial.println("[WEB] FP RESET command");
    server.send(200, "text/plain", "FP reset");
  } else {
    server.send(400, "text/plain", "Invalid cmd");
  }
}

// ---- GET STATUS ----
void handleFpStatus() {
  String stateStr;
  if (fpState == FP_IDLE) {
    stateStr = "IDLE";
  } else if (fpState == FP_SCANNING) {
    stateStr = "SCANNING";
  } else {
    stateStr = fpImageReady ? "DONE" : "FAILED";
  }

  String response = "{\"state\":\"" + stateStr + "\"";
  
  // Add error message if failed
  if (fpState == FP_DONE && !fpImageReady && fpLastError.length() > 0) {
    response += ",\"error\":\"" + fpLastError + "\"";
  }
  
  response += "}";
  server.send(200, "application/json", response);
}

// ---- GET IMAGE ----
void handleFpImage() {
  if (!fpImageReady) {
    server.send(404, "text/plain", "Image not ready");
    return;
  }

  uint8_t* img = fpGetImageData();
  uint16_t size = fpGetImageSize();

  server.sendHeader("Content-Type", "application/octet-stream");
  server.sendHeader("Content-Length", String(size));
  server.send(200);

  WiFiClient client = server.client();
  client.write(img, size);

  Serial.printf("[WEB] Image sent (%d bytes)\n", size);

  // Reset state cho lần quét tiếp theo
  fpImageReady = false;
  fpState = FP_IDLE;
}

// ---- CHECK IMAGE INFO ----
void handleFpImageInfo() {
  uint16_t size = fpGetImageSize();
  
  String response = "{";
  response += "\"imageReady\":" + String(fpImageReady ? "true" : "false") + ",";
  response += "\"imageSize\":" + String(size) + ",";
  response += "\"state\":\"" + String(fpState == FP_IDLE ? "FP_IDLE" : (fpState == FP_SCANNING ? "FP_SCANNING" : "FP_DONE")) + "\",";
  
  if (size > 0) {
    response += "\"status\":\"Image data available\",";
    response += "\"expectedSize\":73728,";
    response += "\"complete\":" + String(size == 73728 ? "true" : "false");
  } else {
    response += "\"status\":\"No image data\"";
  }
  
  response += "}";
  server.send(200, "application/json", response);
}

// ---- SENSOR DIAGNOSTIC TEST ----
void handleFpSensorTest() {
  // Test AS608 kết nối
  Adafruit_Fingerprint* sensor = getFingerprintSensor();
  
  String response = "{";
  
  // Test 1: Verify password
  if (sensor->verifyPassword()) {
    response += "\"connected\":true,";
    response += "\"templateCount\":" + String(sensor->templateCount) + ",";
  } else {
    response += "\"connected\":false,";
    server.send(200, "application/json", response + "}");
    return;
  }
  
  // Test 2: Try to get image (no finger needed, just test)
  Serial.println("[TEST] Testing getImage()...");
  uint32_t t1 = millis();
  uint8_t p = sensor->getImage();
  uint32_t dur = millis() - t1;
  
  response += "\"getImage\":{";
  response += "\"returnCode\":\"0x" + String(p, HEX) + "\",";
  response += "\"duration_ms\":" + String(dur) + ",";
  
  if (p == 0x00) {
    response += "\"status\":\"Image captured (finger detected)\"";
  } else if (p == 0x02) {
    response += "\"status\":\"No finger detected (timeout)\"";
  } else {
    response += "\"status\":\"Error\"";
  }
  response += "},";
  
  // Test 3: If image captured, try image2Tz
  if (p == 0x00) {
    Serial.println("[TEST] Testing image2Tz()...");
    uint32_t t2 = millis();
    p = sensor->image2Tz(1);
    dur = millis() - t2;
    
    response += "\"image2Tz\":{";
    response += "\"returnCode\":\"0x" + String(p, HEX) + "\",";
    response += "\"duration_ms\":" + String(dur) + ",";
    
    if (p == 0x00) {
      response += "\"status\":\"Template generated successfully\"";
    } else {
      response += "\"status\":\"Template generation failed\"";
    }
    response += "}";
  } else {
    response += "\"image2Tz\":\"skipped (no finger)\"";
  }
  
  response += "}";
  server.send(200, "application/json", response);
}
