import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

// =======================================================================
// UUIDs CỦA BLE PROVISIONING
// =======================================================================
final Guid PROV_SERVICE_UUID = Guid("0000FF01-0000-1000-8000-00805F9B34FB");
final Guid SSID_CHAR_UUID = Guid("0000FF02-0000-1000-8000-00805F9B34FB");
final Guid PASSWORD_CHAR_UUID = Guid("0000FF03-0000-1000-8000-00805F9B34FB");
final Guid CONNECT_CHAR_UUID = Guid("0000FF04-0000-1000-8000-00805F9B34FB");
final Guid STATUS_CHAR_UUID = Guid("0000FF05-0000-1000-8000-00805F9B34FB");

const String TARGET_DEVICE_NAME = "ESP32_Clock";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setLogLevel(LogLevel.verbose, color: true);
  runApp(const ProvisioningApp());
}

class ProvisioningApp extends StatelessWidget {
  const ProvisioningApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DigitalClock',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const DashboardScreen(),
    );
  }
}

// =======================================================================
// 🔥 MÀN HÌNH DASHBOARD (TRANG CHỦ ĐỘC LẬP CỦA APP)
// =======================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedIndex = 0;

  // --- Biến cho kết nối ESP32 ---
  String? _currentEspIp;
  int _failCount = 0;
  Timer? _pingTimer;

  // --- Các biến cho Đồng hồ ---
  Timer? _clockTimer;
  String _currentTime = "";
  TimeOfDay? _selectedAlarm;

  // --- Các biến cho Chế độ Bấm giờ ---
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _stopwatchDisplayTimer;

  // --- Các biến cho Chế độ Đếm lùi ---
  Timer? _countdownTimer;
  int _countdownTotalSeconds = 30 * 60;
  int _countdownRemainingSeconds = 30 * 60;
  bool _isCountdownRunning = false;

  @override
  void initState() {
    super.initState();
    _updateTime();

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateTime();
    });

    _pingTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _checkEspConnection();
    });

    _stopwatchDisplayTimer = Timer.periodic(const Duration(milliseconds: 30), (
      timer,
    ) {
      if (_stopwatch.isRunning && _selectedIndex == 1) {
        setState(() {});
      }
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_isCountdownRunning && _countdownRemainingSeconds > 0) {
        setState(() {
          _countdownRemainingSeconds--;
        });
        if (_countdownRemainingSeconds == 0) {
          _isCountdownRunning = false;
          _showAlarmComplete();
        }
      }
    });
  }

  void _updateTime() {
    if (mounted) {
      final now = DateTime.now();
      setState(() {
        _currentTime =
            "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _openProvisioning() async {
    final returnedIp = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ProvisioningScreen()),
    );

    if (returnedIp != null && returnedIp is String) {
      setState(() {
        _currentEspIp = returnedIp;
        _failCount = 0;
      });

      // 🔥 THAY ĐỔI: Bắn thông báo nổi (SnackBar) thay vì hiện chữ chết trên màn hình
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "✅ Đã kết nối và đồng bộ với ESP32 thành công!",
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3), // Biến mất sau 3 giây
          ),
        );
      }

      _checkEspConnection();
    }
  }

  Future<void> _checkEspConnection() async {
    if (_currentEspIp == null) return;

    final url = Uri.parse("http://$_currentEspIp/set_alarm");
    try {
      await http.get(url).timeout(const Duration(seconds: 2));
      if (mounted && _failCount >= 3) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "✅ Đã tự động kết nối lại với ESP32!",
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
      if (mounted) setState(() => _failCount = 0);
    } catch (e) {
      if (mounted) setState(() => _failCount++);
    }
  }

  Future<void> _sendAlarmToESP32(TimeOfDay time) async {
    if (_currentEspIp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Báo thức đã lưu trên App. Hãy kết nối ESP32 để đồng bộ!",
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_failCount >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "❌ Thiết bị ngoại tuyến! Báo thức chỉ lưu trên điện thoại.",
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final url = Uri.parse(
      "http://$_currentEspIp/set_alarm?hour=${time.hour}&minute=${time.minute}",
    );
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "✅ Đã đồng bộ báo thức xuống ESP32!",
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "❌ Lỗi gửi báo thức: $e",
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showAlarmComplete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          "⏰ HẾT GIỜ!",
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          "Thời gian đếm lùi của bạn đã kết thúc.",
          style: TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK", style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }

  Future<void> _showTimerPicker() async {
    int currentH = _countdownTotalSeconds ~/ 3600;
    int currentM = (_countdownTotalSeconds % 3600) ~/ 60;
    int currentS = _countdownTotalSeconds % 60;

    final TextEditingController hCtrl = TextEditingController(
      text: currentH.toString(),
    );
    final TextEditingController mCtrl = TextEditingController(
      text: currentM.toString(),
    );
    final TextEditingController sCtrl = TextEditingController(
      text: currentS.toString(),
    );

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Cài đặt đếm lùi", textAlign: TextAlign.center),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildTimeInputField(hCtrl, "Giờ"),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 5),
                child: Text(
                  ":",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
              _buildTimeInputField(mCtrl, "Phút"),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 5),
                child: Text(
                  ":",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
              _buildTimeInputField(sCtrl, "Giây"),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Hủy", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                int h = int.tryParse(hCtrl.text) ?? 0;
                int m = int.tryParse(mCtrl.text) ?? 0;
                int s = int.tryParse(sCtrl.text) ?? 0;

                setState(() {
                  _countdownTotalSeconds = h * 3600 + m * 60 + s;
                  _countdownRemainingSeconds = _countdownTotalSeconds;
                  _isCountdownRunning = false;
                });
                Navigator.pop(context);
              },
              child: const Text("Lưu"),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTimeInputField(TextEditingController controller, String label) {
    return SizedBox(
      width: 55,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 12),
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _pingTimer?.cancel();
    _stopwatchDisplayTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  Widget _buildClockTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            color: const Color(0xFF1E1E1E),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  const Text(
                    "THỜI GIAN HIỆN TẠI",
                    style: TextStyle(
                      color: Colors.blueAccent,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Text(
                    _currentTime,
                    style: TextStyle(
                      color: (_currentEspIp != null && _failCount >= 3)
                          ? Colors.grey
                          : Colors.white,
                      fontSize: 56,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 30),
          ElevatedButton.icon(
            onPressed: () async {
              final TimeOfDay? time = await showTimePicker(
                context: context,
                initialTime: _selectedAlarm ?? TimeOfDay.now(),
              );
              if (time != null) {
                setState(() => _selectedAlarm = time);
                _sendAlarmToESP32(time);
              }
            },
            icon: const Icon(Icons.alarm_add, size: 28),
            label: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _selectedAlarm == null
                    ? "Cài đặt báo thức"
                    : "Báo thức: ${_selectedAlarm!.format(context)} (Đổi)",
                style: const TextStyle(fontSize: 18),
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStopwatchTab() {
    final int ms = _stopwatch.elapsedMilliseconds;
    final int hundreds = (ms ~/ 10) % 100;
    final int seconds = (ms ~/ 1000) % 60;
    final int minutes = ms ~/ (1000 * 60);

    final displayTime =
        "${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${hundreds.toString().padLeft(2, '0')}";

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Card(
            elevation: 6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            color: const Color(0xFF1E1E1E),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 20),
              child: Center(
                child: Text(
                  displayTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 60,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FloatingActionButton(
                heroTag: "reset_sw",
                backgroundColor: Colors.grey[800],
                onPressed: () {
                  setState(() {
                    _stopwatch.reset();
                    _stopwatch.stop();
                  });
                },
                child: const Icon(Icons.refresh, color: Colors.white),
              ),
              FloatingActionButton(
                heroTag: "play_sw",
                backgroundColor: _stopwatch.isRunning
                    ? Colors.redAccent
                    : Colors.green,
                onPressed: () {
                  setState(() {
                    if (_stopwatch.isRunning) {
                      _stopwatch.stop();
                    } else {
                      _stopwatch.start();
                    }
                  });
                },
                child: Icon(
                  _stopwatch.isRunning ? Icons.pause : Icons.play_arrow,
                  size: 30,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimerTab() {
    final int h = _countdownRemainingSeconds ~/ 3600;
    final int m = (_countdownRemainingSeconds % 3600) ~/ 60;
    final int s = _countdownRemainingSeconds % 60;
    final displayTime =
        "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Card(
            elevation: 6,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            color: const Color(0xFF1E1E1E),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 50, horizontal: 20),
              child: Center(
                child: Text(
                  displayTime,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 60,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 30),
          ElevatedButton.icon(
            onPressed: _isCountdownRunning ? null : _showTimerPicker,
            icon: const Icon(Icons.edit),
            label: const Text("Chỉnh thời gian"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
          ),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              FloatingActionButton(
                heroTag: "reset_timer",
                backgroundColor: Colors.grey[800],
                onPressed: () {
                  setState(() {
                    _isCountdownRunning = false;
                    _countdownRemainingSeconds = _countdownTotalSeconds;
                  });
                },
                child: const Icon(Icons.refresh, color: Colors.white),
              ),
              FloatingActionButton(
                heroTag: "play_timer",
                backgroundColor: _isCountdownRunning
                    ? Colors.redAccent
                    : Colors.green,
                onPressed: () {
                  if (_countdownRemainingSeconds == 0) return;
                  setState(() {
                    _isCountdownRunning = !_isCountdownRunning;
                  });
                },
                child: Icon(
                  _isCountdownRunning ? Icons.pause : Icons.play_arrow,
                  size: 30,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Digital Clock"),
        backgroundColor: Colors.blueAccent,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_bluetooth),
            tooltip: 'Quản lý ESP32',
            onPressed: _openProvisioning,
          ),
        ],
      ),
      body: Column(
        children: [
          // TRẠNG THÁI 1: CHƯA KẾT NỐI ESP32 (Chạy độc lập)
          if (_currentEspIp == null)
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                border: Border.all(color: Colors.blue.shade300, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    "App đang chạy độc lập",
                    style: TextStyle(
                      color: Colors.blue,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Tính năng Đồng bộ Báo thức cần kết nối với mạch ESP32.",
                    style: TextStyle(color: Colors.blue, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _openProvisioning,
                    icon: const Icon(Icons.link),
                    label: const Text("Kết nối ESP32"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            )
          // TRẠNG THÁI 2: ĐÃ KẾT NỐI NHƯNG BỊ MẤT MẠNG
          else if (_failCount >= 3)
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red[50],
                border: Border.all(color: Colors.red.shade300, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    "⚠️ Mất kết nối với ESP32",
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Mạch đang sập nguồn hoặc đổi mạng. App đang tự động tìm lại...",
                    style: TextStyle(color: Colors.red, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _openProvisioning,
                    icon: const Icon(Icons.bluetooth),
                    label: const Text("Cấu hình lại mạng qua BLE"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

          // 🔥 ĐÃ XÓA TRẠNG THÁI 3 Ở ĐÂY, GIAO DIỆN SẼ LUÔN SẠCH KHI KẾT NỐI BÌNH THƯỜNG
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                _buildClockTab(),
                _buildStopwatchTab(),
                _buildTimerTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        selectedItemColor: Colors.blueAccent,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.access_time),
            label: "Đồng hồ",
          ),
          BottomNavigationBarItem(icon: Icon(Icons.timer), label: "Bấm giờ"),
          BottomNavigationBarItem(
            icon: Icon(Icons.hourglass_bottom),
            label: "Đếm lùi",
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// MÀN HÌNH QUÉT BLE VÀ CẤP WI-FI
// =======================================================================
class ProvisioningScreen extends StatefulWidget {
  const ProvisioningScreen({super.key});

  @override
  State<ProvisioningScreen> createState() => _ProvisioningScreenState();
}

class _ProvisioningScreenState extends State<ProvisioningScreen> {
  BluetoothDevice? targetDevice;
  bool isScanning = false;
  String connectionStatus = "Chưa quét";
  List<ScanResult> _scanResults = [];

  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _statusSub;

  String? _espIp;
  bool _wifiProvSuccess = false;

  @override
  void initState() {
    super.initState();
    checkPermissionsAndInitialize();
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> checkPermissionsAndInitialize() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    if (!(await FlutterBluePlus.isSupported)) {
      setState(() => connectionStatus = "Thiết bị không hỗ trợ Bluetooth.");
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      setState(
        () =>
            connectionStatus = "Vui lòng bật Bluetooth (và Location nếu cần).",
      );
      return;
    }

    setState(() => connectionStatus = "Sẵn sàng quét.");
  }

  void startScan() async {
    if (await FlutterBluePlus.isScanning.first) {
      await FlutterBluePlus.stopScan();
    }

    setState(() {
      isScanning = true;
      targetDevice = null;
      _scanResults = [];
      connectionStatus = "Đang quét...";
    });

    StreamSubscription<List<ScanResult>>? subscription;

    try {
      subscription = FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          final seen = <String>{};
          _scanResults = results.where((r) {
            final name = r.device.platformName.isNotEmpty
                ? r.device.platformName
                : r.advertisementData.advName;
            if (name.isEmpty) return false;
            return seen.add(r.device.remoteId.str);
          }).toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
        });
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      await subscription.cancel();

      setState(() {
        connectionStatus = _scanResults.isEmpty
            ? "Không tìm thấy thiết bị nào."
            : "Tìm thấy ${_scanResults.length} thiết bị. Chọn để kết nối.";
      });
    } catch (e) {
      setState(() => connectionStatus = "Lỗi quét: $e");
      await FlutterBluePlus.stopScan();
      await subscription?.cancel();
    } finally {
      setState(() => isScanning = false);
    }
  }

  void selectDevice(BluetoothDevice device, String name) {
    setState(() {
      targetDevice = device;
      connectionStatus = "Đã chọn: $name. Nhấn Kết nối BLE.";
    });
  }

  Future<void> connectBleOnly() async {
    if (targetDevice == null) return;

    setState(
      () => connectionStatus = "Đang kết nối BLE tới $TARGET_DEVICE_NAME ...",
    );

    try {
      await _connSub?.cancel();
      _connSub = null;
      _wifiProvSuccess = false;

      await targetDevice!.connect(timeout: const Duration(seconds: 15));

      _connSub = targetDevice!.connectionState.listen((s) {
        setState(() => _connectionState = s);
        if (s == BluetoothConnectionState.disconnected) {
          if (!_wifiProvSuccess) {
            _statusSub?.cancel();
            setState(() {
              connectionStatus =
                  "ESP32 đã ngắt kết nối. Nhấn Quét để kết nối lại.";
              targetDevice = null;
              _espIp = null;
            });
          }
        }
      });

      setState(
        () => connectionStatus = "Đã kết nối BLE. Sẵn sàng gửi cấu hình.",
      );
    } catch (e) {
      setState(() => connectionStatus = "Lỗi kết nối BLE: $e");
      try {
        await targetDevice?.disconnect();
      } catch (_) {}
    }
  }

  void connectAndProvision(String ssid, String password) async {
    if (targetDevice == null ||
        _connectionState != BluetoothConnectionState.connected) {
      setState(
        () => connectionStatus = "Chưa kết nối BLE. Nhấn 'Kết nối BLE' trước.",
      );
      return;
    }

    setState(() => connectionStatus = "Đang khám phá services...");

    try {
      List<BluetoothService> services = await targetDevice!.discoverServices();

      BluetoothService provService = services.firstWhere(
        (s) => s.uuid == PROV_SERVICE_UUID,
        orElse: () =>
            throw Exception("Không tìm thấy Provisioning Service (FF01)"),
      );

      BluetoothCharacteristic ssidChar = provService.characteristics.firstWhere(
        (c) => c.uuid == SSID_CHAR_UUID,
        orElse: () =>
            throw Exception("Không tìm thấy SSID Characteristic (FF02)"),
      );

      BluetoothCharacteristic passChar = provService.characteristics.firstWhere(
        (c) => c.uuid == PASSWORD_CHAR_UUID,
        orElse: () =>
            throw Exception("Không tìm thấy Password Characteristic (FF03)"),
      );

      BluetoothCharacteristic connectChar = provService.characteristics
          .firstWhere(
            (c) => c.uuid == CONNECT_CHAR_UUID,
            orElse: () =>
                throw Exception("Không tìm thấy Connect Characteristic (FF04)"),
          );

      BluetoothCharacteristic statusChar = provService.characteristics
          .firstWhere(
            (c) => c.uuid == STATUS_CHAR_UUID,
            orElse: () =>
                throw Exception("Không tìm thấy Status Characteristic (FF05)"),
          );

      setState(() => connectionStatus = "Đang gửi cấu hình...");

      await ssidChar.write(utf8.encode(ssid), allowLongWrite: true);
      await passChar.write(utf8.encode(password), allowLongWrite: true);
      await connectChar.write(Uint8List.fromList([1]));

      setState(() => connectionStatus = "Đã gửi. ESP32 đang kết nối Wi-Fi...");

      await statusChar.setNotifyValue(true);

      _statusSub?.cancel();
      _statusSub = statusChar.onValueReceived.listen((value) {
        final statusText = utf8.decode(value);
        String uiText;
        String? espIp;

        if (statusText.startsWith("connected:")) {
          espIp = statusText.substring("connected:".length);
          uiText = "Wi-Fi OK! IP: $espIp ✅";
          SharedPreferences.getInstance().then((prefs) {
            prefs.setString('saved_ssid', ssid);
            prefs.setString('saved_pass', password);
          });

          _wifiProvSuccess = true;
          targetDevice?.disconnect();

          if (mounted) {
            Navigator.pop(context, espIp);
          }
        } else if (statusText == "connecting") {
          uiText = "Đang kết nối Wi-Fi...";
        } else if (statusText == "failed") {
          uiText = "Wi-Fi thất bại ❌ Kiểm tra lại SSID/Pass.";
        } else {
          uiText = "Trạng thái: $statusText";
        }

        if (mounted) {
          setState(() {
            connectionStatus = uiText;
            _espIp = espIp;
          });
        }
      });

      targetDevice!.cancelWhenDisconnected(_statusSub!);
    } catch (e) {
      setState(() => connectionStatus = "Lỗi Provisioning: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isConnected =
        _connectionState == BluetoothConnectionState.connected;

    return Scaffold(
      appBar: AppBar(title: const Text('Quản lý thiết bị ESP32')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: isConnected ? Colors.green[50] : Colors.blue[50],
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connectionStatus,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'BLE: ${_connectionState.name}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            ElevatedButton.icon(
              onPressed: isScanning ? null : startScan,
              icon: isScanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(isScanning ? "Đang quét..." : "Quét thiết bị BLE"),
            ),

            if (_scanResults.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                "Thiết bị tìm thấy:",
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(height: 6),
              ..._scanResults.map((r) {
                final name = r.device.platformName.isNotEmpty
                    ? r.device.platformName
                    : r.advertisementData.advName;
                final isSelected = targetDevice?.remoteId == r.device.remoteId;
                final isTarget = name == TARGET_DEVICE_NAME;
                return Card(
                  color: isSelected
                      ? Colors.blue[100]
                      : isTarget
                      ? Colors.green[50]
                      : null,
                  child: ListTile(
                    leading: Icon(
                      Icons.bluetooth,
                      color: isTarget ? Colors.green : Colors.blue,
                    ),
                    title: Text(
                      name,
                      style: TextStyle(
                        fontWeight: isTarget
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      '${r.device.remoteId.str}  •  ${r.rssi} dBm',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: isTarget
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : null,
                    onTap: () => selectDevice(r.device, name),
                  ),
                );
              }),
            ],

            const SizedBox(height: 12),

            if (targetDevice != null) ...[
              ElevatedButton.icon(
                onPressed: isConnected ? null : connectBleOnly,
                icon: const Icon(Icons.link),
                label: const Text("Kết nối BLE"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: isConnected
                    ? () async {
                        _statusSub?.cancel();
                        await targetDevice!.disconnect();
                        setState(() {
                          connectionStatus = "Đã ngắt kết nối BLE.";
                          _espIp = null;
                          targetDevice = null;
                        });
                      }
                    : null,
                icon: const Icon(Icons.link_off),
                label: const Text("Ngắt kết nối"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              ),
            ],

            if (isConnected && _espIp == null)
              Padding(
                padding: const EdgeInsets.only(top: 20.0),
                child: ProvisioningForm(onSubmit: connectAndProvision),
              ),
          ],
        ),
      ),
    );
  }
}

class ProvisioningForm extends StatefulWidget {
  final void Function(String, String) onSubmit;
  const ProvisioningForm({super.key, required this.onSubmit});

  @override
  State<ProvisioningForm> createState() => _ProvisioningFormState();
}

class _ProvisioningFormState extends State<ProvisioningForm> {
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedSsid = prefs.getString('saved_ssid') ?? '';
    final savedPass = prefs.getString('saved_pass') ?? '';
    if (savedSsid.isNotEmpty) {
      setState(() {
        ssidController.text = savedSsid;
        passController.text = savedPass;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          "Cấu hình Wi-Fi:",
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        const Text(
          TARGET_DEVICE_NAME,
          style: TextStyle(color: Colors.blueAccent, fontSize: 16),
        ),
        const SizedBox(height: 15),
        TextField(
          controller: ssidController,
          decoration: const InputDecoration(
            labelText: 'SSID (Tên Wi-Fi)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.wifi),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: passController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock),
          ),
        ),
        const SizedBox(height: 30),
        SizedBox(
          height: 50,
          child: ElevatedButton(
            onPressed: () {
              if (ssidController.text.isEmpty || passController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Vui lòng nhập SSID và Password."),
                  ),
                );
                return;
              }
              widget.onSubmit(ssidController.text, passController.text);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text(
              "Gửi cấu hình Wi-Fi",
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }
}
