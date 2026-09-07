import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const HorizonCoolerApp());
}

class HorizonCoolerApp extends StatelessWidget {
  const HorizonCoolerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Horizon Cooler Control',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.blueAccent,
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        useMaterial3: true,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? txChar;
  BluetoothCharacteristic? rxChar;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  
  bool isScanning = false;
  bool isConnected = false;
  
  // UUID Layanan Standar untuk Komunikasi Serial
  final String serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"; // RX/TX Service
  final String charRxUUID  = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // RX Characteristic (Menerima perintah)
  final String charTxUUID  = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // TX Characteristic (Mengirim status)

  String temperature = "--.-";
  String voltage = "--V";
  bool isRgbOn = false;
  bool isAiModeOn = false;
  double brightness = 255;
  String currentVersion = "V?";
  String firebaseStatus = "Menghubungkan ke Cloud...";

  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initFirebaseMonitoring();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  void _initFirebaseMonitoring() {
    _dbRef.child("telemetry").onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data != null && mounted) {
        setState(() => firebaseStatus = "Sinkronisasi Cloud Aktif ✅");
      }
    }, onError: (error) {
      if (mounted) setState(() => firebaseStatus = "Gagal Koneksi Cloud ❌");
    });
  }

  void startScan() async {
    if (isScanning) return;
    setState(() => isScanning = true);
    
    // Reset status koneksi sebelum scan
    if (targetDevice != null) disconnectDevice();
    
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 7));
    
    scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.platformName == "Horizon Cooler" || r.device.platformName == "HORIZON COOLER") {
          FlutterBluePlus.stopScan();
          connectToDevice(r.device);
          break;
        }
      }
    });

    await Future.delayed(const Duration(seconds: 7));
    if (mounted) setState(() => isScanning = false);
  }

  void connectToDevice(BluetoothDevice device) async {
    targetDevice = device;
    
    connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        setState(() => isConnected = true);
        discoverServices(device);
      } else if (state == BluetoothConnectionState.disconnected) {
        if (mounted) {
          setState(() {
            isConnected = false;
            txChar = null;
            rxChar = null;
            temperature = "--.-";
            voltage = "--V";
          });
        }
      }
    });
    
    try {
       await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
       debugPrint("Connection Error: $e");
    }
  }

  void discoverServices(BluetoothDevice device) async {
    try {
      List<BluetoothService> services = await device.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() == serviceUUID.toUpperCase()) {
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.uuid.toString().toUpperCase() == charRxUUID.toUpperCase()) {
                rxChar = char;
            }
            if (char.uuid.toString().toUpperCase() == charTxUUID.toUpperCase()) {
              txChar = char;
              await txChar!.setNotifyValue(true);
              txChar!.lastValueStream.listen((val) {
                 if (val.isNotEmpty) {
                    parseIncomingData(utf8.decode(val));
                 }
              });
            }
          }
        }
      }
      
      // Minta alat untuk mengirimkan data terbarunya saat pertama kali konek
      sendCommand("SYNC"); 
    } catch (e) {
      debugPrint("Service Discovery Error: $e");
    }
  }

  void disconnectDevice() {
    targetDevice?.disconnect();
    scanSubscription?.cancel();
    connectionSubscription?.cancel();
  }

  void parseIncomingData(String data) {
    if (data.startsWith("TMP:")) {
      setState(() => temperature = data.substring(4).trim());
      _dbRef.child("telemetry/temperature").set(temperature);
    } else if (data.startsWith("VOL:")) {
      setState(() => voltage = data.substring(4).trim());
      _dbRef.child("telemetry/voltage").set(voltage);
    } else if (data.startsWith("RGB:")) {
      setState(() => isRgbOn = data.substring(4).trim() == "1");
    } else if (data.startsWith("AI:")) {
      setState(() => isAiModeOn = data.substring(4).trim() == "1");
    } else if (data.startsWith("BRV:")) {
      setState(() => brightness = double.tryParse(data.substring(4).trim()) ?? 255);
    } else if (data.startsWith("VER:")) {
      setState(() => currentVersion = data.substring(4).trim());
    }
  }

  void sendCommand(String cmd) async {
    if (rxChar != null && isConnected) {
      try {
        await rxChar!.write(utf8.encode(cmd), withoutResponse: true);
      } catch (e) {
        debugPrint("Send Command Error: $e");
      }
    } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Bluetooth Tidak Terhubung!")),
        );
    }
  }

  void triggerCloudOTASequence(String ssid, String pass) async {
    if (!isConnected) return;
    
    // Tautan Firmware Tetap
    String rawGithubUrl = "https://raw.githubusercontent.com/TenzoNkz/Horizon-Cooler-Firmware/refs/heads/main/horizoncooler.bin";

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Memulai Proses Injeksi OTA...")),
    );

    sendCommand("OTAENTER");
    await Future.delayed(const Duration(milliseconds: 500));
    sendCommand("SSID:$ssid");
    await Future.delayed(const Duration(milliseconds: 500));
    sendCommand("PASS:$pass");
    await Future.delayed(const Duration(milliseconds: 500));
    sendCommand("URL:$rawGithubUrl");
    await Future.delayed(const Duration(milliseconds: 500));
    sendCommand("CLOUDOTA");
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("🚀 Perintah Cloud OTA Telah Dikirim ke Alat!")),
    );
  }

  void showOtaDialog() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    TextEditingController ssidCtrl = TextEditingController(text: prefs.getString("saved_ssid") ?? "");
    TextEditingController passCtrl = TextEditingController(text: prefs.getString("saved_pass") ?? "");

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text("⚠️ Peringatan Pembaruan", style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Alat (ESP32) membutuhkan akses WiFi internet untuk mengunduh firmware.", style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 15),
              TextField(
                controller: ssidCtrl, 
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "Nama WiFi (SSID)", 
                  labelStyle: const TextStyle(color: Colors.blueAccent),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.grey[700]!)),
                  focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.blueAccent)),
                )
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passCtrl, 
                style: const TextStyle(color: Colors.white),
                obscureText: true,
                decoration: InputDecoration(
                  labelText: "Sandi WiFi", 
                  labelStyle: const TextStyle(color: Colors.blueAccent),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.grey[700]!)),
                  focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.blueAccent)),
                )
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text("Batal", style: TextStyle(color: Colors.grey))
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () {
                prefs.setString("saved_ssid", ssidCtrl.text);
                prefs.setString("saved_pass", passCtrl.text);
                Navigator.pop(context);
                triggerCloudOTASequence(ssidCtrl.text, passCtrl.text);
              },
              child: const Text("Injeksi Firmware", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("HORIZON COOLER", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        centerTitle: true,
        backgroundColor: Colors.black,
        elevation: 10,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: isScanning 
              ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)))
              : IconButton(
                  icon: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, 
                             color: isConnected ? Colors.blueAccent : Colors.redAccent, size: 28),
                  onPressed: isConnected ? disconnectDevice : startScan,
                ),
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Firebase
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF151515), 
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orangeAccent.withOpacity(0.5), width: 1)
              ),
              child: Text(firebaseStatus, textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)),
            ),
            
            const SizedBox(height: 20),
            
            // Monitor Utama
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E1E1E), Color(0xFF2A2A2A)],
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10, offset: const Offset(0, 5))],
                border: Border.all(color: isConnected ? Colors.blueAccent.withOpacity(0.5) : Colors.grey.withOpacity(0.2), width: 2),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("SUHU AKTUAL", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1)),
                      const SizedBox(height: 5),
                      Text("$temperature°C", style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: Colors.white)),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text("TEGANGAN", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1)),
                      const SizedBox(height: 5),
                      Text(voltage, style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: Colors.cyanAccent)),
                    ],
                  )
                ],
              ),
            ),
            
            const SizedBox(height: 25),
            
            // Tombol Fungsi Utama
            Row(
              children: [
                Expanded(child: _actionBtn("MODE AI", Icons.smart_toy, isAiModeOn ? Colors.deepPurpleAccent : const Color(0xFF252525), "MODEAI")),
                const SizedBox(width: 15),
                Expanded(child: _actionBtn("SAKLAR RGB", Icons.lightbulb, isRgbOn ? Colors.green : const Color(0xFF252525), "RGBTOGGLE")),
              ],
            ),
            
            const SizedBox(height: 15),
            
            // Kontrol Mode RGB
            Row(
              children: [
                Expanded(child: _actionBtn("MODE SBLM", Icons.arrow_back_ios_new, const Color(0xFF252525), "RGBPREV")),
                const SizedBox(width: 15),
                Expanded(child: _actionBtn("MODE LNJT", Icons.arrow_forward_ios, const Color(0xFF252525), "RGBNEXT")),
              ],
            ),
            
            const SizedBox(height: 30),
            
            // Pengaturan Tegangan
            const Padding(
              padding: EdgeInsets.only(left: 8.0, bottom: 12.0),
              child: Text("PEMILIHAN TEGANGAN MANUAL", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _voltBtn("5V", Colors.redAccent),
                _voltBtn("9V", Colors.greenAccent),
                _voltBtn("12V", Colors.blueAccent),
              ],
            ),
            
            const SizedBox(height: 30),
            
            // Kecerahan RGB
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("KECERAHAN RGB", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  Text("${(brightness / 255 * 100).toInt()}%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: Colors.blueAccent, inactiveTrackColor: Colors.grey[800],
                thumbColor: Colors.white, overlayColor: Colors.blueAccent.withOpacity(0.2),
              ),
              child: Slider(
                value: brightness, min: 1, max: 255,
                onChangeEnd: (val) => sendCommand("BR:${val.toInt()}"),
                onChanged: (val) {
                  setState(() => brightness = val);
                },
              ),
            ),
            
            const SizedBox(height: 30),
            
            // Bagian OTA
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: const Color(0xFF151515),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3))
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.memory, color: Colors.grey, size: 16),
                      const SizedBox(width: 8),
                      Text("Firmware Sistem: $currentVersion", style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red[800], 
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 5,
                      ),
                      onPressed: isConnected ? showOtaDialog : null,
                      icon: const Icon(Icons.cloud_download, color: Colors.white),
                      label: const Text("FLASH CLOUD OTA FIRMWARE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _actionBtn(String label, IconData icon, Color bg, String cmd) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: bg, 
        padding: const EdgeInsets.symmetric(vertical: 18),
        elevation: 3,
      ),
      onPressed: () => sendCommand(cmd),
      icon: Icon(icon, color: Colors.white, size: 20), 
      label: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }

  Widget _voltBtn(String volt, Color c) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5.0),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A1A1A), 
            side: BorderSide(color: c, width: 2),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: () => sendCommand(volt),
          child: Text(volt, style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 18)),
        ),
      ),
    );
  }
}
