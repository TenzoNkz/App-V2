import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

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
  final int currentAppVersion = 1; 

  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? txChar;
  BluetoothCharacteristic? rxChar;
  
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<List<int>>? dataSubscription;
  
  bool isConnected = false;

  final String serviceUUID = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"; 
  final String charRxUUID  = "b2c3d4e5-f6a7-4b5c-8d9e-1f2a3b4c5d6e"; 
  final String charTxUUID  = "c3d4e5f6-a7b8-4c5d-8e9f-2a3b4c5d6e7f";

  String hotsideTemp = "--"; 
  String voltage = "--";
  bool isRgbOn = false;
  bool isAiModeOn = false;
  double brightness = 255;
  String currentVersion = "V?";
  
  bool isCloudSyncing = false;
  late final DatabaseReference _dbRef;
  final String firebaseDbUrl = "https://horizon-cooler-a4723-default-rtdb.asia-southeast1.firebasedatabase.app";

  int selectedMenuIndex = 0; 
  double phoneBatteryTemp = 32.5; 
  Timer? _phoneTempMockTimer;
  int aiModeType = 0; 
  int rgbModeNumber = 1;

  int limitHot = 45;
  int limitBat5v = 25;
  int limitBat9v = 30;
  int limitBat12v = 35;

  String _bleBuffer = "";
  
  double downloadProgress = 0.0;
  bool isDownloadingUpdate = false;

  @override
  void initState() {
    super.initState();
    _dbRef = FirebaseDatabase.instanceFor(app: Firebase.app(), databaseURL: firebaseDbUrl).ref();
    _requestPermissions();
    _initFirebaseMonitoring();
    _startBatteryTempMock();
    _checkForAppUpdates();
  }

  @override
  void dispose() {
    connectionSubscription?.cancel();
    dataSubscription?.cancel();
    targetDevice?.disconnect();
    _phoneTempMockTimer?.cancel();
    super.dispose();
  }

  void _checkForAppUpdates() {
    _dbRef.child("app_update").onValue.listen((event) {
      if (event.snapshot.value != null && mounted) {
        try {
          final data = Map<String, dynamic>.from(event.snapshot.value as Map);
          int serverVersion = data['version_code'] ?? 1;
          String apkUrl = data['apk_url'] ?? "";

          if (serverVersion > currentAppVersion && apkUrl.isNotEmpty && !isDownloadingUpdate) {
            _showUpdateDialog(apkUrl, serverVersion);
          }
        } catch (e) { debugPrint("Update Check Error: $e"); }
      }
    });
  }

  void _showUpdateDialog(String url, int newVer) {
    showDialog(
      context: context,
      barrierDismissible: false, 
      builder: (context) {
        return StatefulBuilder(builder: (context, setStateDialog) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E202B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text("System Update Available", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("New Horizon Cooler UI is ready. Updating is required for optimal performance.", style: TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 20),
                if (isDownloadingUpdate) ...[
                  LinearProgressIndicator(value: downloadProgress, backgroundColor: Colors.grey.shade800, color: Colors.blueAccent),
                  const SizedBox(height: 10),
                  Text("Downloading: ${(downloadProgress * 100).toStringAsFixed(0)}%", style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                ]
              ],
            ),
            actions: [
              if (!isDownloadingUpdate)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                  onPressed: () {
                    setStateDialog(() => isDownloadingUpdate = true);
                    _downloadAndInstallAPK(url, setStateDialog);
                  },
                  child: const Text("Download & Install", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                )
            ],
          );
        });
      }
    );
  }

  Future<void> _downloadAndInstallAPK(String url, Function setStateDialog) async {
    try {
      if (Platform.isAndroid) await Permission.requestInstallPackages.request();

      Directory? tempDir = await getExternalStorageDirectory();
      String savePath = "${tempDir!.path}/horizon_update.apk";

      Dio dio = Dio();
      await dio.download(
        url, 
        savePath, 
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setStateDialog(() {
              downloadProgress = received / total;
            });
          }
        }
      );

      setStateDialog(() => isDownloadingUpdate = false);
      Navigator.pop(context); 
      OpenFilex.open(savePath); 
      
    } catch (e) {
      setStateDialog(() => isDownloadingUpdate = false);
      _showSnackBar("Update Failed: $e", color: Colors.redAccent);
    }
  }

  void _startBatteryTempMock() {
    _phoneTempMockTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted && isConnected) {
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
                    const Text("Select Device", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
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
                    if (results.isEmpty) return const Center(child: Text("Scanning for Horizon Cooler...", style: TextStyle(color: Colors.grey)));
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
    _showSnackBar("Connecting...", color: Colors.blueGrey);
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
           _showSnackBar("Connected! Synchronizing...", color: Colors.green);
           if (Platform.isAndroid) { try { await device.requestMtu(512); } catch(e){} }
           discoverServices(device);
         } else if (state == BluetoothConnectionState.disconnected) {
           if (mounted) {
             setState(() { 
               isConnected = false; txChar = null; rxChar = null; 
               hotsideTemp = "--"; voltage = "--"; isAiModeOn = false; 
               _bleBuffer = ""; 
             });
           }
           _showSnackBar("Connection Lost ❌", color: Colors.redAccent);
         }
       });
       await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
       _showSnackBar("Failed to connect!", color: Colors.redAccent);
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
         _showSnackBar("Synchronized! System Ready! 🚀", color: Colors.blueAccent);
      } else {
         _showSnackBar("UUID Mismatch!", color: Colors.redAccent);
         await device.disconnect(); 
      }
    } catch (e) { debugPrint("Discovery Error"); }
  }

  void disconnectDevice() async => await targetDevice?.disconnect();

  void parseIncomingData(String rawData) {
    if (!mounted) return;
    try {
      _bleBuffer += rawData;
      while (_bleBuffer.contains('\n')) {
        int index = _bleBuffer.indexOf('\n');
        String line = _bleBuffer.substring(0, index).trim();
        _bleBuffer = _bleBuffer.substring(index + 1);

        if (line.isEmpty || !line.contains(":")) continue;

        List<String> parts = line.split(':');
        if (parts.length >= 2) {
          String key = parts[0].trim();
          String value = parts[1].trim();

          setState(() {
            if (key == "TMP") {
              hotsideTemp = value.replaceAll(RegExp(r'\.0*'), '');
              if (isCloudSyncing) _dbRef.child("telemetry/hotside_temp").set(hotsideTemp);
            } else if (key == "VOL") {
              voltage = value;
              if (isCloudSyncing) _dbRef.child("telemetry/voltage").set(voltage);
            } else if (key == "RGB") {
              isRgbOn = (value == "1");
            } else if (key == "AI") {
              isAiModeOn = (value == "1");
            } else if (key == "BRV") {
              brightness = double.tryParse(value) ?? 255;
            } else if (key == "VER") {
              currentVersion = value;
            }
          });
        }
      }
    } catch (e) { debugPrint("Parsing Error"); }
  }

  void sendCommand(String cmd) async {
    if (rxChar != null && isConnected) {
      try { 
        await rxChar!.write(utf8.encode("$cmd\n"), withoutResponse: true); 
      } catch (e) {}
    } else {
      _showSnackBar("Bluetooth Not Synchronized!", color: Colors.orangeAccent);
    }
  }

  void resetTempSettings() {
    setState(() {
      limitHot = 45;
      limitBat5v = 25;
      limitBat9v = 30;
      limitBat12v = 35;
    });
    _showSnackBar("Settings Reset to Default", color: Colors.green);
  }

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
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 10, top: 10, bottom: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTopData(isConnected ? phoneBatteryTemp.toStringAsFixed(1) : "--", "°C", "Battery Temperature", color: Colors.orangeAccent),
                      const SizedBox(height: 20),
                      _buildTopData(isConnected ? hotsideTemp : "--", "°C", "Hotside Temperature", color: Colors.cyanAccent),
                      const SizedBox(height: 20),
                      _buildTopData(isConnected ? voltage.replaceAll('V','') : "--", "V", "Voltage Indicator", color: Colors.blueAccent),
                      const SizedBox(height: 20),
                      _buildTopData(isConnected ? (isAiModeOn ? "ON" : "OFF") : "--", "", "AI Mode", color: isAiModeOn ? Colors.greenAccent : Colors.grey),
                    ],
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Transform.translate(
                    offset: const Offset(-25, -10), 
                    child: Transform.scale(
                      scale: 1.35, 
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
                  
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
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

  Widget _buildTopData(String value, String unit, String label, {Color color = Colors.white}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.w900)),
            if (unit.isNotEmpty && value != "--") 
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
            style: TextStyle(color: isSelected ? Colors.white : Colors.black54, fontWeight: FontWeight.bold, fontSize: 12)
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
            boxShadow: isActive ? [const BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 5))] : [],
          ),
          child: Center(
            child: Text(v, style: TextStyle(color: isActive ? Colors.white : Colors.black87, fontSize: 22, fontWeight: FontWeight.w900)),
          ),
        ),
      ),
    );
  }

  Widget _buildAiMenu() {
    return Column(
      children: [
        ListTile(
          title: const Text("Master AI Switch", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          subtitle: const Text("Turn AI control ON or OFF"),
          trailing: Switch(
            value: isAiModeOn,
            activeColor: Colors.blueAccent,
            onChanged: (val) {
              setState(() => isAiModeOn = val);
              sendCommand("5V");
              if (val) {
                Future.delayed(const Duration(milliseconds: 300), () => sendCommand("AION"));
              } else {
                Future.delayed(const Duration(milliseconds: 300), () => sendCommand("AIOFF"));
              }
            },
          ),
        ),
        const Divider(),
        _aiOptionTile(0, "Overheat Protection", "Protect cooler hotside from overheating."),
        _aiOptionTile(1, "Overheat + Battery Protection", "Smart voltage scaling based on phone temp."),
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

  Widget _buildRgbMenu() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
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
        Row(
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
        )
      ],
    );
  }

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
          child: Text("Battery Temperature Limits", style: TextStyle(fontWeight: FontWeight.w900, color: Colors.black54)),
        ),
        _tempAdjusterTile("5V Limit (Drop if <)", limitBat5v, (v) => setState(()=> limitBat5v = v), "°C"),
        _tempAdjusterTile("9V Limit (Normal)", limitBat9v, (v) => setState(()=> limitBat9v = v), "°C"),
        _tempAdjusterTile("12V Limit (Boost if >)", limitBat12v, (v) => setState(()=> limitBat12v = v), "°C"),
        
        const SizedBox(height: 20),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent.withOpacity(0.1), foregroundColor: Colors.red, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 12)),
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
