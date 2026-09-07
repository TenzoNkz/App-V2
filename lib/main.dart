import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint("Firebase Init Error: $e");
  }
  runApp(const HorizonCoolerApp());
}

class HorizonCoolerApp extends StatelessWidget {
  const HorizonCoolerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Horizon Cooler Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.blueAccent,
        scaffoldBackgroundColor: const Color(0xFF0A0A0C), 
        useMaterial3: true,
        fontFamily: 'Roboto', 
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
  // --- STATE VARIABLES ---
  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? txChar;
  BluetoothCharacteristic? rxChar;
  
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<List<int>>? dataSubscription;
  
  bool isConnected = false;
  
  // UUID Layanan Standar ESP32
  final String serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"; 
  final String charRxUUID  = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; 
  final String charTxUUID  = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; 

  // Data Alat
  String temperature = "--.-";
  String voltage = "--V";
  bool isRgbOn = false;
  bool isAiModeOn = false;
  double brightness = 255;
  String currentVersion = "V?";
  
  // Cloud Status
  String firebaseStatus = "Menghubungkan ke Cloud...";
  Color firebaseStatusColor = Colors.orangeAccent;

  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  // --- LIFECYCLE ---
  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _initFirebaseMonitoring();
  }

  @override
  void dispose() {
    connectionSubscription?.cancel();
    dataSubscription?.cancel();
    targetDevice?.disconnect();
    super.dispose();
  }

  // --- PERMISSIONS & CLOUD ---
  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
    }
  }

  void _initFirebaseMonitoring() {
    _dbRef.child("telemetry").onValue.listen((event) {
      if (mounted && event.snapshot.value != null) {
        setState(() {
          firebaseStatus = "Sinkronisasi Cloud Aktif ✅";
          firebaseStatusColor = Colors.greenAccent;
        });
      }
    }, onError: (error) {
      if (mounted) {
        setState(() {
          firebaseStatus = "Gagal Koneksi Cloud ❌";
          firebaseStatusColor = Colors.redAccent;
        });
      }
    });
  }

  void _showSnackBar(String message, {Color color = Colors.blueAccent}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(10),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // --- BLUETOOTH MENU (BOTTOM SHEET) ---
  void showBluetoothMenu() async {
    // 1. Validasi Izin
    if (Platform.isAndroid) {
      var scanStatus = await Permission.bluetoothScan.status;
      var connectStatus = await Permission.bluetoothConnect.status;
      if (!scanStatus.isGranted || !connectStatus.isGranted) {
        await _requestPermissions();
      }
    }

    // 2. Mulai Memindai
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      _showSnackBar("Gagal mengaktifkan pemindai BLE. Cek Bluetooth Anda.", color: Colors.redAccent);
      return;
    }

    // 3. Tampilkan Visual UI Bottom Sheet
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF15161E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: Column(
            children: [
              // Header Menu
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E202B),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10)],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Pilih Perangkat", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1)),
                    StreamBuilder<bool>(
                      stream: FlutterBluePlus.isScanning,
                      initialData: false,
                      builder: (c, snapshot) {
                        if (snapshot.data == true) {
                          return const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 2.5));
                        }
                        return IconButton(
                          icon: const Icon(Icons.refresh_rounded, color: Colors.blueAccent, size: 28),
                          onPressed: () => FlutterBluePlus.startScan(timeout: const Duration(seconds: 15)),
                        );
                      }
                    )
                  ],
                ),
              ),
              
              // List Perangkat
              Expanded(
                child: StreamBuilder<List<ScanResult>>(
                  stream: FlutterBluePlus.scanResults,
                  initialData: const [],
                  builder: (c, snapshot) {
                    final results = snapshot.data ?? [];
                    if (results.isEmpty) {
                      return const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.bluetooth_searching, color: Colors.grey, size: 50),
                            SizedBox(height: 15),
                            Text("Mencari perangkat Horizon...", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      );
                    }
                    
                    return ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final r = results[index];
                        // Mengambil nama perangkat (Prioritaskan platformName, lalu advName)
                        String devName = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
                        if (devName.isEmpty) devName = "Unknown Device";
                        
                        bool isTarget = devName.toUpperCase().contains("HORIZON");

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 25, vertical: 5),
                          leading: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isTarget ? Colors.blueAccent.withOpacity(0.2) : Colors.white10,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.bluetooth, color: isTarget ? Colors.blueAccent : Colors.grey),
                          ),
                          title: Text(devName, style: TextStyle(color: isTarget ? Colors.white : Colors.grey[400], fontWeight: FontWeight.bold)),
                          subtitle: Text(r.device.remoteId.toString(), style: const TextStyle(color: Colors.grey, fontSize: 11)),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
                            child: Text("${r.rssi} dBm", style: TextStyle(color: r.rssi > -70 ? Colors.greenAccent : Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          onTap: () {
                            FlutterBluePlus.stopScan();
                            Navigator.pop(context); // Tutup BottomSheet
                            connectToDevice(r.device); // Eksekusi Koneksi
                          },
                        );
                      },
                    );
                  },
                )
              ),
            ],
          ),
        );
      }
    ).whenComplete(() {
      FlutterBluePlus.stopScan(); // Pastikan scan berhenti saat menu ditutup
    });
  }

  // --- BLUETOOTH CONNECTION LOGIC ---
  void connectToDevice(BluetoothDevice device) async {
    if (targetDevice != null) disconnectDevice();
    targetDevice = device;
    
    _showSnackBar("Menyambungkan ke ${device.platformName.isNotEmpty ? device.platformName : 'perangkat'}...", color: Colors.blueGrey);

    connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        if (mounted) setState(() => isConnected = true);
        _showSnackBar("Berhasil Terhubung! ✅", color: Colors.green);
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
        _showSnackBar("Koneksi Terputus ❌", color: Colors.redAccent);
      }
    });
    
    try {
       await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
       _showSnackBar("Gagal terkoneksi: Timeout/Ditolak", color: Colors.redAccent);
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
              
              dataSubscription?.cancel();
              dataSubscription = txChar!.lastValueStream.listen((val) {
                 if (val.isNotEmpty) {
                    try {
                      parseIncomingData(utf8.decode(val));
                    } catch (e) {
                      debugPrint("Parsing Error: $e");
                    }
                 }
              });
            }
          }
        }
      }
      sendCommand("SYNC"); 
    } catch (e) {
      debugPrint("Service Discovery Error: $e");
    }
  }

  void disconnectDevice() {
    targetDevice?.disconnect();
  }

  void parseIncomingData(String data) {
    if (!mounted) return;
    
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
        _showSnackBar("Bluetooth Tidak Terhubung!", color: Colors.orangeAccent);
    }
  }

  // --- OTA LOGIC ---
  void triggerCloudOTASequence(String ssid, String pass) async {
    if (!isConnected) return;
    
    String rawGithubUrl = "https://raw.githubusercontent.com/TenzoNkz/Horizon-Cooler-Firmware/refs/heads/main/horizoncooler.bin";
    _showSnackBar("Memulai Proses Injeksi OTA...", color: Colors.purpleAccent);

    sendCommand("OTAENTER");
    await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("SSID:$ssid");
    await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("PASS:$pass");
    await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("URL:$rawGithubUrl");
    await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("CLOUDOTA");
    
    _showSnackBar("🚀 Perintah Cloud OTA Telah Dikirim!", color: Colors.green);
  }

  void showOtaDialog() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    TextEditingController ssidCtrl = TextEditingController(text: prefs.getString("saved_ssid") ?? "");
    TextEditingController passCtrl = TextEditingController(text: prefs.getString("saved_pass") ?? "");

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
              SizedBox(width: 10),
              Text("Peringatan OTA", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("ESP32 membutuhkan akses WiFi internet untuk mengunduh firmware secara mandiri.", 
                style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.5)),
              const SizedBox(height: 20),
              _buildTextField(ssidCtrl, "Nama WiFi (SSID)", Icons.wifi),
              const SizedBox(height: 12),
              _buildTextField(passCtrl, "Sandi WiFi", Icons.lock, isPassword: true),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text("Batal", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
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

  Widget _buildTextField(TextEditingController controller, String label, IconData icon, {bool isPassword = false}) {
    return TextField(
      controller: controller, 
      style: const TextStyle(color: Colors.white),
      obscureText: isPassword,
      decoration: InputDecoration(
        labelText: label, 
        labelStyle: const TextStyle(color: Colors.grey),
        prefixIcon: Icon(icon, color: Colors.blueAccent, size: 20),
        filled: true,
        fillColor: const Color(0xFF2A2A35),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.blueAccent, width: 2)),
      )
    );
  }

  // --- UI BUILDING ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("HORIZON COOLER", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: IconButton(
              // Tombol ini sekarang membuka Menu Bluetooth, atau memutus koneksi
              icon: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth, 
                         color: isConnected ? Colors.blueAccent : Colors.white, size: 28),
              onPressed: isConnected ? disconnectDevice : showBluetoothMenu,
            ),
          )
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: firebaseStatusColor.withOpacity(0.1), 
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: firebaseStatusColor.withOpacity(0.5), width: 1)
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cloud_sync, color: firebaseStatusColor, size: 16),
                    const SizedBox(width: 8),
                    Text(firebaseStatus, style: TextStyle(color: firebaseStatusColor, fontSize: 13, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              
              const SizedBox(height: 25),
              
              Container(
                padding: const EdgeInsets.all(25),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E202B), Color(0xFF15161E)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(color: isConnected ? Colors.blueAccent.withOpacity(0.15) : Colors.black26, blurRadius: 20, offset: const Offset(0, 8))
                  ],
                  border: Border.all(color: isConnected ? Colors.blueAccent.withOpacity(0.4) : Colors.transparent, width: 1.5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildTelemetryData("SUHU AKTUAL", "$temperature°C", Colors.white),
                    Container(width: 1, height: 60, color: Colors.grey.withOpacity(0.2)),
                    _buildTelemetryData("TEGANGAN", voltage, Colors.cyanAccent),
                  ],
                ),
              ),
              
              const SizedBox(height: 30),
              
              Row(
                children: [
                  Expanded(child: _buildAnimatedBtn("MODE AI", Icons.smart_toy, isAiModeOn, Colors.deepPurpleAccent, "MODEAI")),
                  const SizedBox(width: 15),
                  Expanded(child: _buildAnimatedBtn("SAKLAR RGB", Icons.lightbulb, isRgbOn, Colors.greenAccent, "RGBTOGGLE")),
                ],
              ),
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(child: _buildStandardBtn("MODE SBLM", Icons.fast_rewind_rounded, "RGBPREV")),
                  const SizedBox(width: 15),
                  Expanded(child: _buildStandardBtn("MODE LNJT", Icons.fast_forward_rounded, "RGBNEXT")),
                ],
              ),
              
              const SizedBox(height: 35),
              
              const Text("PILIH TEGANGAN MANUAL", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildVoltBtn("5V", Colors.redAccent),
                  _buildVoltBtn("9V", Colors.greenAccent),
                  _buildVoltBtn("12V", Colors.blueAccent),
                ],
              ),
              
              const SizedBox(height: 35),
              
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("KECERAHAN LED", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                  Text("${(brightness / 255 * 100).toInt()}%", style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w900)),
                ],
              ),
              const SizedBox(height: 5),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 6,
                  activeTrackColor: Colors.blueAccent, 
                  inactiveTrackColor: const Color(0xFF2A2A35),
                  thumbColor: Colors.white, 
                  overlayColor: Colors.blueAccent.withOpacity(0.2),
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                ),
                child: Slider(
                  value: brightness, min: 1, max: 255,
                  onChangeEnd: (val) => sendCommand("BR:${val.toInt()}"),
                  onChanged: (val) => setState(() => brightness = val),
                ),
              ),
              
              const SizedBox(height: 35),
              
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF15151A),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.2))
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.memory, color: Colors.grey, size: 18),
                        const SizedBox(width: 8),
                        Text("Firmware Terpasang: $currentVersion", style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 15),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[800], 
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        onPressed: isConnected ? showOtaDialog : null,
                        icon: const Icon(Icons.cloud_download_rounded, size: 22),
                        label: const Text("FLASH CLOUD OTA", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTelemetryData(String label, String value, Color valueColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
        const SizedBox(height: 8),
        Text(value, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: valueColor, letterSpacing: -1)),
      ],
    );
  }

  Widget _buildAnimatedBtn(String label, IconData icon, bool isActive, Color activeColor, String cmd) {
    return GestureDetector(
      onTap: () => sendCommand(cmd),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isActive ? activeColor.withOpacity(0.2) : const Color(0xFF1A1A22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isActive ? activeColor : Colors.transparent, width: 1.5),
          boxShadow: isActive ? [BoxShadow(color: activeColor.withOpacity(0.3), blurRadius: 12)] : [],
        ),
        child: Column(
          children: [
            Icon(icon, color: isActive ? activeColor : Colors.grey, size: 28),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(color: isActive ? activeColor : Colors.grey, fontWeight: FontWeight.w800, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildStandardBtn(String label, IconData icon, String cmd) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF1A1A22), 
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
      ),
      onPressed: () => sendCommand(cmd),
      icon: Icon(icon, size: 18, color: Colors.grey[400]), 
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }

  Widget _buildVoltBtn(String volt, Color c) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6.0),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A1A22), 
            foregroundColor: c,
            side: BorderSide(color: c.withOpacity(0.5), width: 1.5),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          onPressed: () => sendCommand(volt),
          child: Text(volt, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
        ),
      ),
    );
  }
}
