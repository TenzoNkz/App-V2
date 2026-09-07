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
      title: 'Horizon Cooler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: Colors.blueAccent,
        scaffoldBackgroundColor: const Color(0xFF111113), 
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

  // 🔐 SISTEM 1 KUNCI 1 GEMBOK (Berdasarkan Firmware Horizon Cooler Asli)
  final String serviceUUID = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"; 
  final String charRxUUID  = "b2c3d4e5-f6a7-4b5c-8d9e-1f2a3b4c5d6e"; 
  final String charTxUUID  = "c3d4e5f6-a7b8-4c5d-8e9f-2a3b4c5d6e7f";

  // Data Alat
  String temperature = "--";
  String voltage = "--";
  bool isRgbOn = false;
  bool isAiModeOn = false;
  double brightness = 255;
  String currentVersion = "V?";
  
  // Cloud Status
  String firebaseStatus = "Offline";
  bool isCloudSyncing = false;

  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

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
          firebaseStatus = "Online";
          isCloudSyncing = true;
        });
      }
    }, onError: (error) {
      if (mounted) {
        setState(() {
          firebaseStatus = "Offline";
          isCloudSyncing = false;
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

  // --- BLUETOOTH MENU ---
  void showBluetoothMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF15161E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E202B),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Pilih Perangkat", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    StreamBuilder<bool>(
                      stream: FlutterBluePlus.isScanning,
                      initialData: false,
                      builder: (c, snapshot) {
                        if (snapshot.data == true) {
                          return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 2));
                        }
                        return IconButton(
                          icon: const Icon(Icons.refresh, color: Colors.blueAccent),
                          onPressed: _startSafeScan, 
                        );
                      }
                    )
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<ScanResult>>(
                  stream: FlutterBluePlus.scanResults,
                  initialData: const [],
                  builder: (c, snapshot) {
                    final results = snapshot.data ?? [];
                    if (results.isEmpty) {
                      return const Center(child: Text("Mencari Horizon Cooler...", style: TextStyle(color: Colors.grey)));
                    }
                    return ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final r = results[index];
                        String devName = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
                        if (devName.isEmpty) devName = "Unknown Device";
                        bool isTarget = devName.toUpperCase().contains("HORIZON");

                        return ListTile(
                          leading: Icon(Icons.bluetooth, color: isTarget ? Colors.blueAccent : Colors.grey),
                          title: Text(devName, style: TextStyle(color: isTarget ? Colors.white : Colors.grey[400], fontWeight: FontWeight.bold)),
                          subtitle: Text(r.device.remoteId.toString(), style: const TextStyle(color: Colors.grey, fontSize: 11)),
                          onTap: () {
                            Navigator.pop(context); 
                            connectToDevice(r.device); 
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
    ).whenComplete(() => FlutterBluePlus.stopScan());

    _startSafeScan();
  }

  void _startSafeScan() async {
    if (Platform.isAndroid) {
      await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
    }
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      _showSnackBar("Nyalakan Bluetooth & Lokasi Anda!", color: Colors.orangeAccent);
    }
  }

  // --- KONEKSI ---
  void connectToDevice(BluetoothDevice device) async {
    _showSnackBar("Menyambungkan...", color: Colors.blueGrey);
    
    try {
       await FlutterBluePlus.stopScan();
       
       if (device.isConnected) {
         await device.disconnect();
         await Future.delayed(const Duration(milliseconds: 500));
       }
       
       targetDevice = device;
       connectionSubscription?.cancel();
       
       connectionSubscription = device.connectionState.listen((state) async {
         if (state == BluetoothConnectionState.connected) {
           if (mounted) setState(() => isConnected = true);
           _showSnackBar("Berhasil Terhubung! Mencocokkan Kunci...", color: Colors.green);
           
           if (Platform.isAndroid) {
             try { await device.requestMtu(512); } catch(e){}
           }
           
           discoverServices(device);
           
         } else if (state == BluetoothConnectionState.disconnected) {
           if (mounted) {
             setState(() {
               isConnected = false; txChar = null; rxChar = null;
               temperature = "--"; voltage = "--";
             });
           }
           _showSnackBar("Koneksi Terputus ❌", color: Colors.redAccent);
         }
       });
       
       await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
       
    } catch (e) {
       _showSnackBar("Gagal terkoneksi: Pastikan ESP32 Menyala", color: Colors.redAccent);
       await device.disconnect();
    }
  }

  void discoverServices(BluetoothDevice device) async {
    try {
      await Future.delayed(const Duration(milliseconds: 800));
      List<BluetoothService> services = await device.discoverServices();
      
      bool foundRxTx = false;

      for (BluetoothService service in services) {
        // 🔐 PENCOCOKAN GEMBOK UTAMA (Service UUID)
        if (service.uuid.toString().toLowerCase() == serviceUUID.toLowerCase()) {
          
          for (BluetoothCharacteristic char in service.characteristics) {
            
            // 🔐 KUNCI TX (Menerima Data dari ESP32)
            if (char.uuid.toString().toLowerCase() == charTxUUID.toLowerCase() || char.properties.notify || char.properties.indicate) {
              txChar = char;
              await txChar!.setNotifyValue(true);
              
              dataSubscription?.cancel();
              dataSubscription = txChar!.lastValueStream.listen((val) {
                 if (val.isNotEmpty) parseIncomingData(utf8.decode(val));
              });
              foundRxTx = true;
            }
            
            // 🔐 KUNCI RX (Mengirim Data ke ESP32)
            if (char.uuid.toString().toLowerCase() == charRxUUID.toLowerCase() || char.properties.write || char.properties.writeWithoutResponse) {
              rxChar = char;
              foundRxTx = true;
            }
          }
        }
      }
      
      if (foundRxTx && rxChar != null) {
         await Future.delayed(const Duration(milliseconds: 500));
         sendCommand("SYNC"); 
         _showSnackBar("Kunci Cocok! Siap Digunakan! 🚀", color: Colors.blueAccent);
      } else {
         _showSnackBar("Gembok UUID Tidak Cocok dengan ESP32!", color: Colors.redAccent);
         await device.disconnect(); // Putus paksa jika gembok salah
      }
      
    } catch (e) {
      debugPrint("Discovery Error: $e");
    }
  }

  void disconnectDevice() async {
    await targetDevice?.disconnect();
  }

  void parseIncomingData(String data) {
    if (!mounted) return;
    try {
      if (data.startsWith("TMP:")) {
        setState(() => temperature = data.substring(4).trim().replaceAll(RegExp(r'\.0*'), '')); 
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
    } catch (e) {
      debugPrint("Gagal Parse String: $e");
    }
  }

  void sendCommand(String cmd) async {
    if (rxChar != null && isConnected) {
      try {
        await rxChar!.write(utf8.encode(cmd), withoutResponse: true);
      } catch (e) {
        debugPrint("Send Command Error");
      }
    } else {
      _showSnackBar("Kunci Bluetooth Belum Tersinkronisasi!", color: Colors.orangeAccent);
    }
  }

  // --- OTA LOGIC ---
  void triggerCloudOTASequence(String ssid, String pass) async {
    if (!isConnected) return;
    String rawGithubUrl = "https://raw.githubusercontent.com/TenzoNkz/Horizon-Cooler-Firmware/refs/heads/main/horizoncooler.bin";
    _showSnackBar("Injeksi OTA Dimulai...", color: Colors.purpleAccent);

    sendCommand("OTAENTER"); await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("SSID:$ssid"); await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("PASS:$pass"); await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("URL:$rawGithubUrl"); await Future.delayed(const Duration(milliseconds: 600));
    sendCommand("CLOUDOTA");
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
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text("Lab Features (OTA)", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ssidCtrl, style: const TextStyle(color: Colors.black),
                decoration: const InputDecoration(labelText: "SSID WiFi", prefixIcon: Icon(Icons.wifi))
              ),
              TextField(
                controller: passCtrl, style: const TextStyle(color: Colors.black), obscureText: true,
                decoration: const InputDecoration(labelText: "Password", prefixIcon: Icon(Icons.lock))
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Batal", style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.black),
              onPressed: () {
                prefs.setString("saved_ssid", ssidCtrl.text); prefs.setString("saved_pass", passCtrl.text);
                Navigator.pop(context); triggerCloudOTASequence(ssidCtrl.text, passCtrl.text);
              },
              child: const Text("Update Firmware", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  // --- UI BUILDING (MODERN SHARK STYLE) ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111113),
      appBar: AppBar(
        title: const Text("Horizon Cooler", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth, 
                     color: isConnected ? Colors.blueAccent : Colors.white),
          onPressed: isConnected ? disconnectDevice : showBluetoothMenu,
        ),
        actions: [
          IconButton(icon: const Icon(Icons.menu, color: Colors.white), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          // 1. TOP SECTION (Dark, Telemetry, Image)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTopData(temperature, "°C", "Cold End Temp"),
                      const SizedBox(height: 30),
                      _buildTopData(voltage, "V", "Device Power"),
                      const SizedBox(height: 30),
                      _buildTopData(firebaseStatus, "", "Cloud Status", isStatus: true),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Image.asset(
                    'assets/cooler.png', 
                    fit: BoxFit.contain,
                    height: 220,
                    errorBuilder: (context, error, stackTrace) => 
                      const Center(child: Icon(Icons.image_not_supported, color: Colors.grey, size: 50)),
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 10),

          // 2. SLIDER SECTION (Dark Theme)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Text("RGB", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      activeTrackColor: Colors.white, 
                      inactiveTrackColor: Colors.grey.shade800,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white.withOpacity(0.1),
                      tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
                      activeTickMarkColor: Colors.white,
                      inactiveTickMarkColor: Colors.grey.shade600,
                    ),
                    child: Slider(
                      value: brightness, min: 1, max: 255,
                      divisions: 5, 
                      onChangeEnd: (val) => sendCommand("BR:${val.toInt()}"),
                      onChanged: (val) => setState(() => brightness = val),
                    ),
                  ),
                ),
                Text("${(brightness / 255 * 100).toInt()}%", style: const TextStyle(color: Colors.white, fontSize: 12)),
              ],
            ),
          ),

          const SizedBox(height: 25),

          // 3. BOTTOM SECTION (White Rounded Container)
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.only(top: 25, left: 15, right: 15),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(35)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildWhiteCard("LED Settings", "RGBTOGGLE", icon: Icons.power_settings_new, isActive: isRgbOn)),
                      Expanded(child: _buildWhiteCard("Power Config", "", isVoltageConfig: true)),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _buildWhiteCard("Key Settings", "MODEAI", icon: Icons.auto_awesome, isActive: isAiModeOn)),
                      Expanded(child: _buildWhiteCard("Lab Features", "", isLab: true)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- COMPONENT HELPERS ---
  Widget _buildTopData(String value, String unit, String label, {bool isStatus = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(color: isStatus ? (isCloudSyncing ? Colors.green : Colors.grey) : Colors.white, fontSize: 24, fontWeight: FontWeight.w400)),
            if (unit.isNotEmpty) 
              Padding(
                padding: const EdgeInsets.only(top: 4.0, left: 2),
                child: Text(unit, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      ],
    );
  }

  Widget _buildWhiteCard(String title, String cmd, {IconData? icon, bool isActive = false, bool isVoltageConfig = false, bool isLab = false}) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(15),
      height: 140, 
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 13)),
              Icon(Icons.keyboard_double_arrow_right, color: Colors.grey.shade400, size: 16),
            ],
          ),
          const Spacer(),
          Center(
            child: isVoltageConfig 
              ? _buildVoltageControl() 
              : isLab
                ? _buildLabControl() 
                : _buildToggleControl(icon!, isActive, cmd) 
          ),
          const Spacer(),
          Center(
            child: Text(
              isVoltageConfig ? "Select Voltage" : isLab ? "Update System" : (isActive ? "ON" : "OFF"), 
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11)
            )
          ),
        ],
      ),
    );
  }

  Widget _buildToggleControl(IconData icon, bool isActive, String cmd) {
    return InkWell(
      onTap: () => sendCommand(cmd),
      borderRadius: BorderRadius.circular(15),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isActive ? Colors.black : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isActive ? Colors.black : Colors.grey.shade300),
        ),
        child: Icon(icon, color: isActive ? Colors.white : Colors.black87, size: 28),
      ),
    );
  }

  Widget _buildVoltageControl() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _miniVoltBtn("5V"),
        const SizedBox(width: 4),
        _miniVoltBtn("9V"),
        const SizedBox(width: 4),
        _miniVoltBtn("12V"),
      ],
    );
  }

  Widget _miniVoltBtn(String v) {
    return InkWell(
      onTap: () => sendCommand(v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(v, style: const TextStyle(color: Colors.black87, fontSize: 11, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildLabControl() {
    return InkWell(
      onTap: isConnected ? showOtaDialog : () => _showSnackBar("Sambungkan Bluetooth Dulu!", color: Colors.orangeAccent),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.cloud_download_outlined, color: Colors.black87, size: 28),
      ),
    );
  }
}
