#include <Arduino.h>
#include <WiFi.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <time.h>

#include "BleProvisioning.h"

#define I2C_SDA        20
#define I2C_SCL        19
#define NTP_SERVER     "pool.ntp.org"
#define GMT_OFFSET_SEC (7 * 3600)
#define DAYLIGHT_SEC   0

#define button_mode 4
#define button_toggle 5 
#define button_move 6
#define button_up 7
#define button_start 8
// #define button_down 9 // Tạm comment vì chưa thấy define ở code cũ của bạn

// 🔥 Chân xuất tín hiệu còi/LED báo thức (Bạn có thể đổi tùy sơ đồ dây thực tế)
#define BUZZER_PIN 18 

LiquidCrystal_I2C lcd(0x27, 16, 2);

void lcdRow(int row, const char *s) {
    char buf[17]; snprintf(buf, sizeof(buf), "%-16s", s);
    lcd.setCursor(0, row); lcd.print(buf);
}

// Biến cho Clock & Hệ thống
struct tm timeinfo;
char row0[17], row1[17];
int mode = 0;

// Biến cho Bấm giờ
bool start = false;
unsigned long elapsed = 0, startMs = 0;

// Biến cho Báo thức
int a_h1 = 0, a_h2 = 0; // Giờ: a_h1 a_h2
int a_m1 = 0, a_m2 = 0; // Phút: a_m1 a_m2
int alarmPos = 0;       // Vị trí con trỏ: 0(H1), 1(H2), 2(M1), 3(M2)

void setup() {
    Serial.begin(115200);
    pinMode(button_mode, INPUT_PULLUP);
    pinMode(button_toggle, INPUT_PULLUP);
    pinMode(button_up, INPUT_PULLUP);
    // pinMode(button_down, INPUT_PULLUP);
    pinMode(button_start, INPUT_PULLUP);
    pinMode(button_move, INPUT_PULLUP);

    // Khởi tạo chân Buzzer
    pinMode(BUZZER_PIN, OUTPUT);
    digitalWrite(BUZZER_PIN, LOW);

    Wire.begin(I2C_SDA, I2C_SCL);
    lcd.init(); lcd.backlight();
    lcdRow(0, "  ESP32 Clock   ");
    lcdRow(1, " Wifi disconnect ");

    bleProvInit();
}

void switch_mode(){
    static unsigned long lastbtn = 0;
    if(digitalRead(button_mode) == LOW && millis() - lastbtn > 300){
        lastbtn = millis();
        mode++;
        if(mode > 2){
            mode = 0;
        }
        
        // Reset trạng thái khi chuyển mode
        lcd.noBlink(); // Tắt nhấp nháy nếu đang từ mode báo thức sang
        start = false;
        elapsed = 0;
        startMs = 0;
        lcd.clear();     
    }
}

// Chế độ 0: Clock
void showClock()
{
    const char *days[] = {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"};
    snprintf(row0, 17, "    %02d:%02d:%02d    ", timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
    snprintf(row1, 17, "%s %02d/%02d/%04d  ", days[timeinfo.tm_wday], timeinfo.tm_mday, timeinfo.tm_mon + 1, timeinfo.tm_year + 1900);
    lcdRow(0, row0);
    lcdRow(1, row1);
}

// Chế độ 1: Bấm giờ
void bam_gio()
{
    static bool lastState = HIGH;
    static unsigned long lastDebounce = 0;
    bool currentState = digitalRead(button_start);
    
    // Phát hiện cạnh nhấn nút (HIGH -> LOW)
    if(lastState == HIGH && currentState == LOW && millis() - lastDebounce > 50)
    {
        lastDebounce = millis();
        
        if (!start && elapsed == 0) {
            // Bước 1: Màn hình đang 0 -> Bấm để CHẠY
            startMs = millis();
            start = true;
        } 
        else if (start) {
            // Bước 2: Đang chạy -> Bấm để DỪNG và chốt thời gian
            elapsed = millis() - startMs;
            start = false;
        } 
        else if (!start && elapsed > 0) {
            // Bước 3: Đang dừng (đã có kết quả) -> Bấm để RESET về 0
            elapsed = 0;
        }
    }
    lastState = currentState;

    unsigned long total = 0;
    
    // Hiển thị thời gian
    if (start) {
        total = millis() - startMs; // Lấy thời gian thực đang chạy
    } else {
        total = elapsed; // Lấy thời gian đã chốt (nếu vừa reset thì elapsed = 0)
    }

    unsigned long ms = total % 1000;
    unsigned long sec = (total / 1000) % 60;
    unsigned long min = (total / 60000) % 60;
    unsigned long hour = total / 3600000;
    
    snprintf(row0, 17, "  %02lu:%02lu:%02lu:%03lu", hour, min, sec, ms);
    lcdRow(0, row0);
}

// Chế độ 2: Báo thức
void bao_thuc()
{
    static unsigned long lastMove = 0;
    static unsigned long lastUp = 0;
    static unsigned long lastRun = 0; 

    static int lastPos = -1;
    static int last_h1=-1, last_h2=-1, last_m1=-1, last_m2=-1;

    static bool needRender = true;

    // Force render nếu vừa từ mode khác chuyển sang
    if (millis() - lastRun > 100) {
        needRender = true;
    }
    lastRun = millis(); 

    // 1. Move
    if(digitalRead(button_move) == LOW && millis() - lastMove > 250)
    {
        lastMove = millis();
        alarmPos = (alarmPos + 1) % 4;
        needRender = true;
    }

    // 2. Up
    if(digitalRead(button_up) == LOW && millis() - lastUp > 250)
    {
        lastUp = millis();
        switch(alarmPos) {
            case 0: a_h1 = (a_h1 + 1) % 3; break;
            case 1:
                a_h2++;
                if(a_h1 == 2 && a_h2 > 3) a_h2 = 0;
                else if(a_h2 > 9) a_h2 = 0;
                break;
            case 2: a_m1 = (a_m1 + 1) % 6; break;
            case 3: a_m2 = (a_m2 + 1) % 10; break;
        }
        needRender = true;
    }

    // 3. Render
    if(needRender || 
       lastPos != alarmPos || 
       last_h1 != a_h1 || last_h2 != a_h2 ||
       last_m1 != a_m1 || last_m2 != a_m2)
    {
        needRender = false;

        lastPos = alarmPos;
        last_h1 = a_h1; last_h2 = a_h2;
        last_m1 = a_m1; last_m2 = a_m2;

        lcd.setCursor(0,0);
        lcd.print(" Set Alarm Time ");

        char buf[17];
        snprintf(buf, sizeof(buf), "    %d%d:%d%d    ", a_h1, a_h2, a_m1, a_m2);

        lcd.setCursor(0,1);
        lcd.print(buf);

        // Xử lý blink
        int col_map[4] = {4, 5, 7, 8};
        int col = col_map[alarmPos];

        lcd.noBlink(); 
        lcd.setCursor(col, 1);
        lcd.blink();   
    }
}

void loop() {
    bleProvLoop();

    static bool ntpSynced = false;
    static bool ntpFirstTry = true;
    static unsigned long ntpRetry = 0;

    if(WiFi.isConnected() && !ntpSynced && (ntpFirstTry || millis() - ntpRetry > 10000)) {
        ntpFirstTry = false;
        ntpRetry = millis();
        lcdRow(0, "  Wifi connected");
        lcdRow(1, "  Syncing NTP.. ");
        configTime(GMT_OFFSET_SEC, DAYLIGHT_SEC, NTP_SERVER);
        struct tm t; int i = 0;
        while(!getLocalTime(&t) && i++ < 20) delay(500); 
        if(i < 20){
            ntpSynced = true;
            lcd.clear();
            Serial.println("[NTP] Synced!");
        } else{
            lcdRow(1, "  NTP Failed... ");
            Serial.println("[NTP] Failed, retry in 10s");
        }
    }
    
    if(!ntpSynced) return; 

    // 🔥 LUÔN CẬP NHẬT THỜI GIAN THỰC TẾ
    if(!getLocalTime(&timeinfo)) return;

    // 🔥 LOGIC BÁO THỨC CHẠY NGẦM 
    static bool alarm_dismissed = false;
    static int last_alarm_min = -1;

    int alarm_hour = a_h1 * 10 + a_h2;
    int alarm_min = a_m1 * 10 + a_m2;

    // Reset cờ tắt báo thức khi sang phút mới
    if (timeinfo.tm_min != last_alarm_min) {
        alarm_dismissed = false;
        last_alarm_min = timeinfo.tm_min;
    }

    bool is_alarm_time = (timeinfo.tm_hour == alarm_hour && timeinfo.tm_min == alarm_min && timeinfo.tm_sec < 10);

    // Kêu chuông và chờ người dùng nhấn nút tắt
    if (is_alarm_time && !alarm_dismissed) {
        // Nếu nhấn bất kỳ phím nào thì tắt còi ngay lập tức
        if (digitalRead(button_mode) == LOW || digitalRead(button_toggle) == LOW || 
            digitalRead(button_up) == LOW || digitalRead(button_start) == LOW || 
            digitalRead(button_move) == LOW) {
            
            alarm_dismissed = true;
            digitalWrite(BUZZER_PIN, LOW); // Tắt còi
        } else {
            // Hiệu ứng bíp bíp (sáng 500ms, tắt 500ms)
            if (millis() % 1000 < 500) {
                digitalWrite(BUZZER_PIN, HIGH);
            } else {
                digitalWrite(BUZZER_PIN, LOW);
            }
        }
    } else {
        // Chắc chắn còi được tắt ở các thời điểm khác
        digitalWrite(BUZZER_PIN, LOW);
    }

    // Xử lý nút bấm và vẽ màn hình
    switch_mode();
    
    switch (mode)
    {
    case 0:
        showClock();
        break;
    case 1:
        bam_gio();
        break;
    case 2:
        bao_thuc();
        break;
    }
}
