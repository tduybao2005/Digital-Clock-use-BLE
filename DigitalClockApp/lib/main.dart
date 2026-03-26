import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      title: 'ESP32 BLE + Fingerprint',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ProvisioningScreen(),
    );
  }
}

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
  bool _wifiProvSuccess = false;  // tránh _connSub reset state khi disconnect chủ ý

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
          // Chỉ hiện thiết bị có tên, loại trùng lặp
          final seen = <String>{};
          _scanResults = results
              .where((r) {
                final name = r.device.platformName.isNotEmpty
                    ? r.device.platformName
                    : r.advertisementData.advName;
                if (name.isEmpty) return false;
                return seen.add(r.device.remoteId.str);
              })
              .toList()
            ..sort((a, b) => b.rssi.compareTo(a.rssi));
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
      // Cancel sub cũ trước khi kết nối lại
      await _connSub?.cancel();
      _connSub = null;
      _wifiProvSuccess = false;  // reset flag khi kết nối mới

      await targetDevice!.connect(timeout: const Duration(seconds: 15));

      // Lắng nghe trạng thái kết nối, bao gồm cả khi ESP32 bị ngắt đột ngột
      _connSub = targetDevice!.connectionState.listen((s) {
        setState(() => _connectionState = s);
        if (s == BluetoothConnectionState.disconnected) {
          // Chỉ reset nếu KHÔNG phải do provisioning thành công
          if (!_wifiProvSuccess) {
            _statusSub?.cancel();
            setState(() {
              connectionStatus = "ESP32 đã ngắt kết nối. Nhấn Quét để kết nối lại.";
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
          // Đặt flag trước khi disconnect để _connSub không reset state
          _wifiProvSuccess = true;
          targetDevice?.disconnect();
        } else if (statusText == "connecting") {
          uiText = "Đang kết nối Wi-Fi...";
        } else if (statusText == "failed") {
          // Không disconnect → form vẫn hiện để nhập lại
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

  // =======================================================================
  // (Fingerprint removed)
  // =======================================================================



  // =======================================================================
  // BUILD UI
  // =======================================================================
  @override
  Widget build(BuildContext context) {
    final bool isConnected =
        _connectionState == BluetoothConnectionState.connected;

    return Scaffold(
      appBar: AppBar(title: const Text('ESP32 BLE Provisioning')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card
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

            // Nút Scan
            ElevatedButton.icon(
              onPressed: isScanning ? null : startScan,
              icon: isScanning
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(isScanning ? "Đang quét..." : "Quét thiết bị BLE"),
            ),

            // Danh sách thiết bị tìm được
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
                        fontWeight: isTarget ? FontWeight.bold : FontWeight.normal,
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

            // Nút Connect / Disconnect
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

            // Form Provisioning
            if (isConnected && _espIp == null)
              Padding(
                padding: const EdgeInsets.only(top: 20.0),
                child: ProvisioningForm(onSubmit: connectAndProvision),
              ),

            // Hiển thị IP sau khi provisioning thành công
            if (_espIp != null) ...[
              const SizedBox(height: 20),
              Card(
                elevation: 4,
                color: Colors.green[50],
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi, color: Colors.green),
                      const SizedBox(width: 8),
                      Text(
                        "ESP32 IP: $_espIp",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =======================================================================
// Form Wi-Fi
// =======================================================================
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
