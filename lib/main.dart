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
  // --- BLUETOOTH & CLOUD VARIABLES ---
  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? txChar;
  BluetoothCharacteristic? rxChar;
  
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<List<int>>? dataSubscription;
  
  bool isConnected = false;

  final String serviceUUID = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"; 
  final String charRxUUID  = "b2c3d4e5-f6a7-4b5c-8d9e-1f2a3b4c5d6e"; 
  final String charTxUUID  = "c3d4e5f6-a7b8-4c5d-8e9f-2a3b4c5d6e7f";

  // --- DATA ALAT & STATUS ---
  String hotsideTemp = "--"; // ESP32 Temperature
  String voltage = "--";
  bool isRgbOn = false;
  bool isAiModeOn = false;
  double brightness = 255;
  String currentVersion = "V?";
  
  bool isCloudSyncing = false;
  late final DatabaseReference _dbRef;
  final String firebaseDbUrl = "https://horizon-cooler-a4723-default-rtdb.asia-southeast1.firebasedatabase.app";

  // --- MENU & SETTINGS VARIABLES ---
  int selectedMenuIndex = 0; // 0:Voltage, 1:AI, 2:RGB, 3:Temp Settings
  
  // Realtime HP Battery Temp Mock
  double phoneBatteryTemp = 32.5; 
  Timer? _phoneTempMockTimer;

  // AI Mode Selection
  int aiModeType = 0; // 0: Overheat Protection, 1: Overheat + Baterai Protection
  
  // RGB Settings
  int rgbModeNumber = 1;

  // Temp Settings (Sesuai Default Prompt)
  int limitHot = 45;
  int limitBat5v = 25;
  int limitBat9v = 30;
  int limitBat12v = 35;

  @override
  void initState() {
    super.initState();
    _dbRef = FirebaseDatabase.instanceFor(app: Firebase.app(), databaseURL: firebaseDbUrl).ref();
    _requestPermissions();
    _initFirebaseMonitoring();
    _startBatteryTempMock();
  }

  @override
  void dispose() {
    connectionSubscription?.cancel();
    dataSubscription?.cancel();
    targetDevice?.disconnect();
    _phoneTempMockTimer?.cancel();
    super.dispose();
  }

  // Simulator Suhu Baterai HP agar terlihat bergerak Realtime
  void _startBatteryTempMock() {
    _phoneTempMockTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) {
        setState(() {
          // Bergerak naik turun +- 0.2 derajat secara acak
          phoneBatteryTemp += (DateTime.now().second % 2 == 0 ? 0.2 : -0.2);
        });
      }
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
    }
  }

  void _initFirebaseMonitoring() {
    FirebaseDatabase.instanceFor(app: Firebase.app(), databaseURL: firebaseDbUrl)
      .ref(".info/connected").onValue.listen((event) {
        if (mounted) {
          setState(() {
            isCloudSyncing = event.snapshot.value as bool? ?? false;
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

  // --- BLUETOOTH CORE ---
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
                        return IconButton(icon: const Icon(Icons.refresh, color: Colors.blueAccent), onPressed: _startSafeScan);
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
                    if (results.isEmpty) return const Center(child: Text("Mencari Horizon Cooler...", style: TextStyle(color: Colors.grey)));
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
                          onTap: () { Navigator.pop(context); connectToDevice(r.device); },
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
    if (Platform.isAndroid) await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
    try { await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15)); } catch (e) { }
  }

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
           _showSnackBar("Terhubung! Mencocokkan Kunci...", color: Colors.green);
           if (Platform.isAndroid) { try { await device.requestMtu(512); } catch(e){} }
           discoverServices(device);
         } else if (state == BluetoothConnectionState.disconnected) {
           if (mounted) setState(() { isConnected = false; txChar = null; rxChar = null; hotsideTemp = "--"; voltage = "--"; });
           _showSnackBar("Koneksi Terputus ❌", color: Colors.redAccent);
         }
       });
       await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
       _showSnackBar("Gagal terkoneksi!", color: Colors.redAccent);
       await device.disconnect();
    }
  }

  void discoverServices(BluetoothDevice device) async {
    try {
      await Future.delayed(const Duration(milliseconds: 800));
      List<BluetoothService> services = await device.discoverServices();
      bool foundRxTx = false;

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUUID.toLowerCase()) {
          for (BluetoothCharacteristic char in service.characteristics) {
            if (char.uuid.toString().toLowerCase() == charTxUUID.toLowerCase() || char.properties.notify || char.properties.indicate) {
              txChar = char;
              await txChar!.setNotifyValue(true);
              dataSubscription?.cancel();
              dataSubscription = txChar!.lastValueStream.listen((val) {
                 if (val.isNotEmpty) parseIncomingData(utf8.decode(val));
              });
              foundRxTx = true;
            }
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
         _showSnackBar("Kunci Cocok! Sistem Siap! 🚀", color: Colors.blueAccent);
      } else {
         _showSnackBar("Gembok UUID Salah!", color: Colors.redAccent);
         await device.disconnect(); 
      }
    } catch (e) { debugPrint("Discovery Error"); }
  }

  void disconnectDevice() async => await targetDevice?.disconnect();

  void parseIncomingData(String data) {
    if (!mounted) return;
    try {
      if (data.startsWith("TMP:")) {
        setState(() => hotsideTemp = data.substring(4).trim().replaceAll(RegExp(r'\.0*'), '')); 
        if(isCloudSyncing) _dbRef.child("telemetry/hotside_temp").set(hotsideTemp);
      } else if (data.startsWith("VOL:")) {
        setState(() => voltage = data.substring(4).trim());
        if(isCloudSyncing) _dbRef.child("telemetry/voltage").set(voltage);
      } else if (data.startsWith("RGB:")) {
        setState(() => isRgbOn = data.substring(4).trim() == "1");
      } else if (data.startsWith("AI:")) {
        setState(() => isAiModeOn = data.substring(4).trim() == "1");
      } else if (data.startsWith("BRV:")) {
        setState(() => brightness = double.tryParse(data.substring(4).trim()) ?? 255);
      } else if (data.startsWith("VER:")) {
        setState(() => currentVersion = data.substring(4).trim());
      }
    } catch (e) {}
  }

  void sendCommand(String cmd) async {
    if (rxChar != null && isConnected) {
      try { await rxChar!.write(utf8.encode(cmd), withoutResponse: true); } catch (e) { }
    } else {
      _showSnackBar("Bluetooth Belum Tersinkronisasi!", color: Colors.orangeAccent);
    }
  }

  void resetTempSettings() {
    setState(() {
      limitHot = 45;
      limitBat5v = 25;
      limitBat9v = 30;
      limitBat12v = 35;
    });
    _showSnackBar("Pengaturan Suhu Direset ke Default", color: Colors.green);
  }


  // --- UI COMPONENTS BUILDING ---
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
          icon: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth, color: isConnected ? Colors.blueAccent : Colors.white),
          onPressed: isConnected ? disconnectDevice : showBluetoothMenu,
        ),
        actions: [ IconButton(icon: const Icon(Icons.menu, color: Colors.white), onPressed: () {}), ],
      ),
      body: Column(
        children: [
          // --- TOP SECTION (Telemetry & Image) ---
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 10, top: 10, bottom: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // DATA TELEMETRI
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTopData(phoneBatteryTemp.toStringAsFixed(1), "°C", "Baterai Temperature", color: Colors.orangeAccent),
                      const SizedBox(height: 20),
                      _buildTopData(hotsideTemp, "°C", "Hotside Temperature", color: Colors.cyanAccent),
                      const SizedBox(height: 20),
                      _buildTopData(voltage.replaceAll('V',''), "V", "Indicator Voltase", color: Colors.blueAccent),
                      const SizedBox(height: 20),
                      _buildTopData(isAiModeOn ? "ON" : "OFF", "", "AI Mode", color: isAiModeOn ? Colors.greenAccent : Colors.grey),
                    ],
                  ),
                ),
                // GAMBAR PRODUK (Lebih Full & Besar)
                Expanded(
                  flex: 6,
                  child: Transform.translate(
                    offset: const Offset(15, -10), // Geser sedikit ke kanan agar tidak terlalu padat
                    child: Transform.scale(
                      scale: 1.45, // Memperbesar gambar produk tanpa menabrak batas container
                      child: Image.asset(
                        'assets/cooler.png', 
                        fit: BoxFit.contain,
                        height: 250,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // --- BOTTOM SECTION (White Rounded Menu) ---
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.only(top: 20, left: 10, right: 10),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(35)),
              ),
              child: Column(
                children: [
                  // TAB NAVIGASI ATAS
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildTabMenu("Voltage", 0),
                        _buildTabMenu("AI Mode", 1),
                        _buildTabMenu("RGB Led", 2),
                        _buildTabMenu("Temp Setting", 3),
                      ],
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Divider(color: Colors.black12, thickness: 1.5),
                  
                  // ISI KONTEN MENU BAWAH
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: _buildMenuContent(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- HELPER WIDGETS ---

  Widget _buildTopData(String value, String unit, String label, {Color color = Colors.white}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.w900)),
            if (unit.isNotEmpty) 
              Padding(
                padding: const EdgeInsets.only(top: 4.0, left: 2),
                child: Text(unit, style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildTabMenu(String title, int index) {
    bool isSelected = selectedMenuIndex == index;
    return GestureDetector(
      onTap: () => setState(() => selectedMenuIndex = index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Colors.black : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          title, 
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.black54, 
            fontWeight: FontWeight.bold, 
            fontSize: 13
          )
        ),
      ),
    );
  }

  Widget _buildMenuContent() {
    switch (selectedMenuIndex) {
      case 0: return _buildVoltageMenu();
      case 1: return _buildAiMenu();
      case 2: return _buildRgbMenu();
      case 3: return _buildTempSettingMenu();
      default: return Container();
    }
  }

  // CONTENT 0: VOLTAGE MENU
  Widget _buildVoltageMenu() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isAiModeOn) ...[
          const Icon(Icons.lock_outline, color: Colors.redAccent, size: 50),
          const SizedBox(height: 10),
          const Text("Voltage Locked by AI Mode", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _voltButton("5V"),
            _voltButton("9V"),
            _voltButton("12V"),
          ],
        ),
      ],
    );
  }

  Widget _voltButton(String v) {
    bool isActive = voltage == v;
    return Opacity(
      opacity: isAiModeOn ? 0.4 : 1.0,
      child: InkWell(
        onTap: isAiModeOn ? null : () => sendCommand(v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 80, height: 80,
          decoration: BoxDecoration(
            color: isActive ? Colors.black : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isActive ? Colors.black : Colors.grey.shade300, width: 2),
            boxShadow: isActive ? [BoxShadow(color: Colors.black26, blurRadius: 10, offset: const Offset(0, 5))] : [],
          ),
          child: Center(
            child: Text(v, style: TextStyle(color: isActive ? Colors.white : Colors.black87, fontSize: 22, fontWeight: FontWeight.w900)),
          ),
        ),
      ),
    );
  }

  // CONTENT 1: AI MENU
  Widget _buildAiMenu() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      children: [
        // Master AI Toggle
        ListTile(
          title: const Text("Master AI Switch", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          subtitle: const Text("Turn AI control ON or OFF"),
          trailing: Switch(
            value: isAiModeOn,
            activeColor: Colors.blueAccent,
            onChanged: (val) => sendCommand("MODEAI"),
          ),
        ),
        const Divider(),
        // AI Type Selector
        _aiOptionTile(0, "Overheat Protection", "Melindungi cooler dari overheat (Hotside)."),
        _aiOptionTile(1, "Overheat + Baterai Protection", "Menyesuaikan voltage berdasarkan suhu HP."),
      ],
    );
  }

  Widget _aiOptionTile(int index, String title, String sub) {
    bool isSelected = aiModeType == index;
    return InkWell(
      onTap: () => setState(() => aiModeType = index),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.withOpacity(0.1) : Colors.white,
          border: Border.all(color: isSelected ? Colors.blueAccent : Colors.grey.shade300, width: 2),
          borderRadius: BorderRadius.circular(15)
        ),
        child: Row(
          children: [
            Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, color: isSelected ? Colors.blueAccent : Colors.grey),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(sub, style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  // CONTENT 2: RGB LED MENU
  Widget _buildRgbMenu() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Power Button
        InkWell(
          onTap: () => sendCommand("RGBTOGGLE"),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isRgbOn ? Colors.black : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: isRgbOn ? Colors.black : Colors.grey.shade300, width: 2),
              boxShadow: isRgbOn ? [BoxShadow(color: Colors.black26, blurRadius: 15)] : [],
            ),
            child: Icon(Icons.power_settings_new, color: isRgbOn ? Colors.white : Colors.grey, size: 40),
          ),
        ),
        const SizedBox(height: 25),
        // Prev/Next Controls
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, color: Colors.black87),
              onPressed: () { 
                setState(() { if(rgbModeNumber > 1) rgbModeNumber--; });
                sendCommand("RGBPREV");
              },
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(15)),
              child: Text("Mode $rgbModeNumber", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, color: Colors.black87),
              onPressed: () { 
                setState(() { rgbModeNumber++; });
                sendCommand("RGBNEXT");
              },
            ),
          ],
        ),
        const SizedBox(height: 25),
        // Brightness
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              const Icon(Icons.brightness_low, color: Colors.grey),
              Expanded(
                child: Slider(
                  value: brightness, min: 1, max: 255, activeColor: Colors.black, inactiveColor: Colors.grey.shade300,
                  onChangeEnd: (val) => sendCommand("BR:${val.toInt()}"),
                  onChanged: (val) => setState(() => brightness = val),
                ),
              ),
              Text("${(brightness / 255 * 100).toInt()}%", style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
        )
      ],
    );
  }

  // CONTENT 3: TEMP SETTING MENU
  Widget _buildTempSettingMenu() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      children: [
        _tempAdjusterTile("Coldside / Overheat Limit", limitHot, (v) => setState(()=> limitHot = v), "°C"),
        const Divider(),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: Text("Baterai Temperature Limits", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black54)),
        ),
        _tempAdjusterTile("5V (Drop if Temp <)", limitBat5v, (v) => setState(()=> limitBat5v = v), "°C"),
        _tempAdjusterTile("9V (Normal Temp)", limitBat9v, (v) => setState(()=> limitBat9v = v), "°C"),
        _tempAdjusterTile("12V (Boost if Temp >)", limitBat12v, (v) => setState(()=> limitBat12v = v), "°C"),
        
        const SizedBox(height: 20),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent.withOpacity(0.1),
            foregroundColor: Colors.red,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 12)
          ),
          onPressed: resetTempSettings, 
          icon: const Icon(Icons.restore), 
          label: const Text("Reset to Default Settings", style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _tempAdjusterTile(String label, int value, Function(int) onChanged, String unit) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline, color: Colors.black54),
                onPressed: () => onChanged(value - 1),
              ),
              SizedBox(
                width: 45,
                child: Center(child: Text("$value$unit", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.blueAccent))),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, color: Colors.black54),
                onPressed: () => onChanged(value + 1),
              ),
            ],
          )
        ],
      ),
    );
  }
}
