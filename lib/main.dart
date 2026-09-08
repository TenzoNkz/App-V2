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
  String hotsideTemp = "--"; 
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
  
  double phoneBatteryTemp = 32.5; 
  Timer? _phoneTempMockTimer;

  int aiModeType = 0; 
  int rgbModeNumber = 1;

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

  void _startBatteryTempMock() {
    _phoneTempMockTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) {
        setState(() {
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
           if (mounted) setState(() { isConnected = false; txChar = null; rxChar = null; hotsideTemp = "--"; voltage = "--"; isAiModeOn = false; });
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

  // ENGINE SINKRONISASI DATA ANTI-ERROR
  void parseIncomingData(String rawData) {
    if (!mounted) return;
    try {
      // Pecah data berdasarkan garis baru (\n) karena BLE sering menumpuk pesan
      List<String> lines = rawData.split(RegExp(r'\r?\n'));
      
      setState(() {
        for (String data in lines) {
          data = data.trim();
          if (data.isEmpty || !data.contains(":")) continue;
          
          String key = data.substring(0, data.indexOf(":"));
          String value = data.substring(data.indexOf(":") + 1).trim();

          switch (key) {
            case "TMP":
              hotsideTemp = value;
              if (isCloudSyncing) _dbRef.child("telemetry/hotside_temp").set(hotsideTemp);
              break;
            case "VOL":
              voltage = value;
              if (isCloudSyncing) _dbRef.child("telemetry/voltage").set(voltage);
              break;
            case "RGB":
              isRgbOn = (value == "1");
              break;
            case "AI":
              isAiModeOn = (value == "1");
              break;
            case "BRV":
              brightness = double.tryParse(value) ?? 255;
              break;
            case "VER":
              currentVersion = value;
              break;
          }
        }
      });
    } catch (e) {
      debugPrint("Gagal Parse String: $e");
    }
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
                      // Indikator Suhu HP (Muncul -- jika tidak terkonek)
                      _buildTopData(isConnected ? phoneBatteryTemp.toStringAsFixed(1) : "--", "°C", "Baterai Temperature", color: Colors.orangeAccent),
                      const SizedBox(height: 20),
                      // Indikator Suhu ESP32
                      _buildTopData(isConnected ? hotsideTemp : "--", "°C", "Hotside Temperature", color: Colors.cyanAccent),
                      const SizedBox(height: 20),
                      // Indikator Voltase
                      _buildTopData(isConnected ? voltage.replaceAll('V','') : "--", "V", "Indicator Voltase", color: Colors.blueAccent),
                      const SizedBox(height: 20),
                      // Indikator AI Mode
                      _buildTopData(isConnected ? (isAiModeOn ? "ON" : "OFF") : "--", "", "AI Mode", color: isAiModeOn ? Colors.greenAccent : Colors.grey),
                    ],
                  ),
                ),
                // GAMBAR PRODUK (Digeser ke Kiri & Diskalakan Aman)
                Expanded(
                  flex: 6,
                  child: Transform.translate(
                    offset: const Offset(-20, -10), // Digeser ke Kiri agar tidak terpotong
                    child: Transform.scale(
                      scale: 1.3, // Proporsional agar gambar lebih besar tapi aman
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
          
          // --- BOTTOM SECTION (White Rounded Menu - FIXED & NOT SCROLLABLE) ---
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
                  // TAB NAVIGASI ATAS (FIXED POSITION)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Expanded(child: _buildTabMenu("Voltage", 0)),
                      Expanded(child: _buildTabMenu("AI Mode", 1)),
                      Expanded(child: _buildTabMenu("RGB Led", 2)),
                      Expanded(child: _buildTabMenu("Temp Set", 3)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Divider(color: Colors.black12, thickness: 1.5),
                  
                  // ISI KONTEN MENU BAWAH (FIXED HEIGHT)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: _buildMenuContent(), // Tanpa animasi agar terasa solid/fixed
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
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Colors.black : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Text(
            title, 
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.black54, 
              fontWeight: FontWeight.bold, 
              fontSize: 12
            )
          ),
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
    return Column(
      children: [
        // Master AI Toggle
        ListTile(
          title: const Text("Master AI Switch", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          subtitle: const Text("Turn AI control ON or OFF"),
          trailing: Switch(
            value: isAiModeOn,
            activeColor: Colors.blueAccent,
            onChanged: (val) {
              if (val) {
                // LOGIKA BARU: Jika diaktifkan, paksa reset ke 5V dulu sebelum Mode AI on
                sendCommand("5V");
                Future.delayed(const Duration(milliseconds: 300), () => sendCommand("MODEAI"));
              } else {
                sendCommand("MODEAI"); // Matikan
              }
            },
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
              boxShadow: isRgbOn ? [const BoxShadow(color: Colors.black26, blurRadius: 15)] : [],
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
    if (isAiModeOn) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.lock_outline, color: Colors.redAccent, size: 50),
          SizedBox(height: 10),
          Text("Settings Locked by AI Mode", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
        ],
      );
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
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
              IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.black54), onPressed: () => onChanged(value - 1)),
              SizedBox(width: 45, child: Center(child: Text("$value$unit", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Colors.blueAccent)))),
              IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.black54), onPressed: () => onChanged(value + 1)),
            ],
          )
        ],
      ),
    );
  }
}
