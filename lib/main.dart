import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  runApp(const HorizonCoolerApp());
}

/// Backwards-compatible alias for projects/tests that still use the default Flutter template name.
typedef MyApp = HorizonCoolerApp;

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
  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? txChar;
  BluetoothCharacteristic? rxChar;
  
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<List<int>>? dataSubscription;
  StreamSubscription<DatabaseEvent>? _firebaseConnectionSubscription;

  bool _connectionEverEstablished = false;
  Future<void> _commandWriteQueue = Future<void>.value();
  bool _syncFrameReceived = false;
  bool _isInitialSync = false;
  bool _isBatteryReadBusy = false;
  int _lastSentBatteryProtectionLevel = -1;
  
  bool isConnected = false;

  final String serviceUUID = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"; 
  final String charRxUUID  = "b2c3d4e5-f6a7-4b5c-8d9e-1f2a3b4c5d6e"; 
  final String charTxUUID  = "c3d4e5f6-a7b8-4c5d-8e9f-2a3b4c5d6e7f";

  String hotsideTemp = "--"; 
  String voltage = "5V";
  bool isRgbOn = true;
  bool isAiModeOn = false;
  double brightness = 255;
  String currentVersion = "V?";
  int rgbModeIndex = 0;
  
  bool isCloudSyncing = false;
  DatabaseReference? _dbRef;
  final String firebaseDbUrl = "https://horizon-cooler-a4723-default-rtdb.asia-southeast1.firebasedatabase.app";

  int selectedMenuIndex = 0; 
  double phoneBatteryTemp = -1.0;
  bool phoneBatteryTempAvailable = false; 
  Timer? _batteryTempTimer;
  int aiModeType = 0;

  int limitHot = 45;
  int limitBat5v = 25;
  int limitBat12v = 35;

  int get limitBat9vMin => limitBat5v + 1;
  int get limitBat9vMax => limitBat12v - 1;

  String _incomingBuffer = "";
  static const platformChannel = MethodChannel('horizon_cooler/battery_temp');

  @override
  void initState() {
    super.initState();
    _initFirebaseSafe();
    _requestPermissions();
    _fetchBatteryTemperature();
    _startRealtimeBatteryTempReader();
  }

  @override
  void dispose() {
    connectionSubscription?.cancel();
    dataSubscription?.cancel();
    targetDevice?.disconnect();
    _batteryTempTimer?.cancel();
    _firebaseConnectionSubscription?.cancel();
    super.dispose();
  }

  void _initFirebaseSafe() {
    try {
      _dbRef = FirebaseDatabase.instanceFor(
        app: Firebase.app(), 
        databaseURL: firebaseDbUrl
      ).ref();
      _initFirebaseMonitoring();
    } catch (e) {
      debugPrint("Firebase Database Unavailable: $e");
    }
  }

  Future<void> _fetchBatteryTemperature() async {
    if (_isBatteryReadBusy) {
      return;
    }

    _isBatteryReadBusy = true;

    try {
      final result = await platformChannel.invokeMethod<dynamic>(
        'getBatteryTemperature',
      );

      final nativeTemp = result is num ? result.toDouble() : -1.0;
      final valid = nativeTemp >= 0.0 && nativeTemp <= 100.0;

      if (!mounted) {
        return;
      }

      if (valid) {
        final batteryTempChanged =
            !phoneBatteryTempAvailable ||
            (nativeTemp - phoneBatteryTemp).abs() >= 0.1;

        if (batteryTempChanged) {
          setState(() {
            phoneBatteryTemp = nativeTemp;
            phoneBatteryTempAvailable = true;
          });
        }

        if (isConnected && isAiModeOn && aiModeType == 1) {
          final level = _batteryProtectionLevel(nativeTemp);
          if (level != _lastSentBatteryProtectionLevel) {
            final sent = await sendCommand(
              'PHONE:BT=${nativeTemp.toStringAsFixed(1)}',
              showError: false,
            );
            if (sent) {
              _lastSentBatteryProtectionLevel = level;
            }
          }
        }

        if (isCloudSyncing && _dbRef != null) {
          await _dbRef!.child('telemetry/battery_temp').set(
            nativeTemp.toStringAsFixed(1),
          );
          await _dbRef!.child('telemetry/battery_temp_available').set(true);
        }
      } else {
        if (phoneBatteryTempAvailable) {
          setState(() {
            phoneBatteryTempAvailable = false;
          });
        }

        if (isConnected &&
            isAiModeOn &&
            aiModeType == 1 &&
            _lastSentBatteryProtectionLevel != 0) {
          final sent = await sendCommand(
            'PHONE:BT=-10.0',
            showError: false,
          );
          if (sent) {
            _lastSentBatteryProtectionLevel = 0;
          }
        }

        if (isCloudSyncing && _dbRef != null) {
          await _dbRef!.child('telemetry/battery_temp').set(null);
          await _dbRef!.child('telemetry/battery_temp_available').set(false);
        }
      }
    } catch (e) {
      debugPrint('Direct battery fetch error: $e');

      if (mounted && phoneBatteryTempAvailable) {
        setState(() {
          phoneBatteryTempAvailable = false;
        });
      }
    } finally {
      _isBatteryReadBusy = false;
    }
  }

  int _batteryProtectionLevel(double temperature) {
    if (temperature < limitBat5v) {
      return 0;
    }

    if (temperature >= limitBat12v) {
      return 2;
    }

    return 1;
  }

  void _startRealtimeBatteryTempReader() {
    _batteryTempTimer?.cancel();
    _batteryTempTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        _fetchBatteryTemperature();
      },
    );
  }

  Future<void> _requestPermissions({
    bool showResult = false,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      final scanStatus = await Permission.bluetoothScan.request();
      final connectStatus = await Permission.bluetoothConnect.request();
      final locationStatus =
          await Permission.locationWhenInUse.request();

      BluetoothAdapterState adapterState =
          await FlutterBluePlus.adapterState.first;

      if (adapterState == BluetoothAdapterState.off) {
        try {
          await FlutterBluePlus.turnOn();
          adapterState =
              await FlutterBluePlus.adapterState.first;
        } catch (e) {
          debugPrint('Bluetooth turn-on error: $e');
        }
      }

      if (showResult && mounted) {
        final bluetoothReady =
            (scanStatus.isGranted && connectStatus.isGranted) &&
            adapterState == BluetoothAdapterState.on;
        final locationReady = locationStatus.isGranted;

        _showSnackBar(
          'Bluetooth ${bluetoothReady ? "ON" : "perlu izin"} • '
          'Location ${locationReady ? "ON" : "perlu izin"}',
          color: bluetoothReady && locationReady
              ? Colors.green
              : Colors.orangeAccent,
        );
      }
    } catch (e) {
      debugPrint('Bluetooth/Location permission error: $e');
    }
  }

  Future<void> _enableBluetoothFromPopup() async {
    if (!Platform.isAndroid) {
      return;
    }

    await _requestPermissions(showResult: true);
  }

  Future<void> _enableLocationFromPopup() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await Permission.locationWhenInUse.request();
      final result = await platformChannel.invokeMethod<bool>(
        'openLocationSettings',
      );

      if (result != true && mounted) {
        _showSnackBar(
          'Unable to open Location Settings',
          color: Colors.redAccent,
        );
      }
    } catch (e) {
      debugPrint('Location settings error: $e');
    }
  }

  Future<bool> _isBluetoothReady() async {
    try {
      final adapterState =
          await FlutterBluePlus.adapterState.first;

      if (adapterState != BluetoothAdapterState.on) {
        return false;
      }

      if (!Platform.isAndroid) {
        return true;
      }

      final scanStatus = await Permission.bluetoothScan.status;
      final connectStatus = await Permission.bluetoothConnect.status;

      return scanStatus.isGranted && connectStatus.isGranted;
    } catch (e) {
      debugPrint('Bluetooth status check error: $e');
      return false;
    }
  }

  Future<bool> _isLocationGranted() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final permission =
        await Permission.locationWhenInUse.status;

    if (!permission.isGranted) {
      return false;
    }

    try {
      final enabled = await platformChannel.invokeMethod<bool>(
        'isLocationServiceEnabled',
      );
      return enabled == true;
    } catch (_) {
      return false;
    }
  }

  void _initFirebaseMonitoring() {
    if (_dbRef == null) return;
    _firebaseConnectionSubscription?.cancel();
    _firebaseConnectionSubscription = _dbRef!.child('.info/connected').onValue.listen((event) {
      if (!mounted) return;
      final value = event.snapshot.value;
      setState(() {
        isCloudSyncing = value is bool && value;
      });
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
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void showBluetoothMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF15161E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(25),
        ),
      ),
      builder: (context) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.65,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 15, 10, 15),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E202B),
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(25),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Bluetooth & Location',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white70,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FutureBuilder<bool>(
                            future: _isBluetoothReady(),
                            builder: (context, snapshot) {
                              final ready = snapshot.data == true;
                              return OutlinedButton.icon(
                                onPressed: _enableBluetoothFromPopup,
                                icon: Icon(
                                  ready
                                      ? Icons.bluetooth_connected
                                      : Icons.bluetooth_disabled,
                                  color: ready
                                      ? Colors.greenAccent
                                      : Colors.orangeAccent,
                                ),
                                label: Text(
                                  ready
                                      ? 'Bluetooth ON'
                                      : 'Enable Bluetooth',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FutureBuilder<bool>(
                            future: _isLocationGranted(),
                            builder: (context, snapshot) {
                              final ready = snapshot.data == true;
                              return OutlinedButton.icon(
                                onPressed: _enableLocationFromPopup,
                                icon: Icon(
                                  ready
                                      ? Icons.location_on
                                      : Icons.location_off,
                                  color: ready
                                      ? Colors.greenAccent
                                      : Colors.orangeAccent,
                                ),
                                label: Text(
                                  ready
                                      ? 'Location ON'
                                      : 'Enable Location',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Select Device',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        StreamBuilder<bool>(
                          stream: FlutterBluePlus.isScanning,
                          initialData: false,
                          builder: (c, snapshot) {
                            if (snapshot.data == true) {
                              return const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.blueAccent,
                                  strokeWidth: 2,
                                ),
                              );
                            }
                            return IconButton(
                              icon: const Icon(
                                Icons.refresh,
                                color: Colors.blueAccent,
                              ),
                              onPressed: _startSafeScan,
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<List<ScanResult>>(
                  stream: FlutterBluePlus.scanResults,
                  initialData: const [],
                  builder: (c, snapshot) {
                    final results = snapshot.data ?? [];
                    final horizonDevices = results.where((r) {
                      final devName = r.device.platformName.isNotEmpty
                          ? r.device.platformName
                          : r.advertisementData.advName;
                      return devName.trim().isNotEmpty &&
                          devName.toUpperCase().contains('HORIZON');
                    }).toList();

                    if (horizonDevices.isEmpty) {
                      return const Center(
                        child: Text(
                          'Scanning for Horizon Cooler...',
                          style: TextStyle(color: Colors.grey),
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: horizonDevices.length,
                      itemBuilder: (context, index) {
                        final r = horizonDevices[index];
                        final devName = r.device.platformName.isNotEmpty
                            ? r.device.platformName
                            : r.advertisementData.advName;

                        return ListTile(
                          leading: const Icon(
                            Icons.bluetooth,
                            color: Colors.blueAccent,
                          ),
                          title: Text(
                            devName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            r.device.remoteId.toString(),
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            connectToDevice(r.device);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ).whenComplete(
      () => FlutterBluePlus.stopScan(),
    );

    _startSafeScan();
  }

  void _startSafeScan() async {
    await _requestPermissions();
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      debugPrint('BLE scan start error: $e');
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    _showSnackBar('Connecting...', color: Colors.blueGrey);
    try {
      await FlutterBluePlus.stopScan();
      await connectionSubscription?.cancel();
      await dataSubscription?.cancel();

      if (targetDevice != null && targetDevice != device) {
        try {
          await targetDevice!.disconnect();
        } catch (e) {
          debugPrint('Previous BLE device disconnect error: $e');
        }
      }

      targetDevice = device;
      txChar = null;
      rxChar = null;
      _connectionEverEstablished = false;
      _incomingBuffer = '';
      _lastSentBatteryProtectionLevel = -1;

      connectionSubscription = device.connectionState.listen((state) async {
        if (state == BluetoothConnectionState.connected) {
          _connectionEverEstablished = true;
          if (mounted) {
            setState(() {
              isConnected = false;
              _syncFrameReceived = false;
              _isInitialSync = true;
            });
          }
          // Give the Android BLE stack and ESP32 a brief settle time after
          // the connection callback before service discovery/MTU negotiation.
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (Platform.isAndroid) {
            try {
              await device.requestMtu(512);
            } catch (e) {
              debugPrint('MTU request error: $e');
            }
          }
          await discoverServices(device);
        } else if (state == BluetoothConnectionState.disconnected) {
          await dataSubscription?.cancel();
          dataSubscription = null;
          if (mounted) {
            setState(() {
              isConnected = false;
              txChar = null;
              rxChar = null;
              hotsideTemp = '--';
              voltage = '--';
              isAiModeOn = false;
              currentVersion = 'V?';
              _incomingBuffer = '';
              _syncFrameReceived = false;
              _isInitialSync = false;
              _lastSentBatteryProtectionLevel = -1;
            });
          }
          if (_connectionEverEstablished) {
            _showSnackBar('Connection Lost', color: Colors.redAccent);
          }
        }
      });

      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
      _connectionEverEstablished = false;
      if (mounted) {
        setState(() {
          isConnected = false;
          txChar = null;
          rxChar = null;
        });
      }
      _showSnackBar('Failed to connect!', color: Colors.redAccent);
      try {
        await device.disconnect();
      } catch (e) {
        debugPrint('BLE disconnect after connection failure: $e');
      }
    }
  }

  Future<void> discoverServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? discoveredTx;
      BluetoothCharacteristic? discoveredRx;

      for (final service in services) {
        if (service.uuid.toString().toLowerCase() != serviceUUID.toLowerCase()) continue;
        for (final characteristic in service.characteristics) {
          final id = characteristic.uuid.toString().toLowerCase();
          if (id == charTxUUID.toLowerCase()) {
            discoveredTx = characteristic;
          } else if (id == charRxUUID.toLowerCase()) {
            discoveredRx = characteristic;
          }
        }
      }

      if (discoveredTx == null || discoveredRx == null) {
        _showSnackBar('UUID Mismatch!', color: Colors.redAccent);
        try {
          await device.disconnect();
        } catch (e) {
          debugPrint('BLE disconnect after UUID mismatch: $e');
        }
        return;
      }

      txChar = discoveredTx;
      rxChar = discoveredRx;

      final tx = txChar!;
      if (tx.properties.notify || tx.properties.indicate) {
        await tx.setNotifyValue(true);
      } else {
        _showSnackBar('TX characteristic cannot notify!', color: Colors.redAccent);
        await device.disconnect();
        return;
      }

      await dataSubscription?.cancel();
      dataSubscription = tx.lastValueStream.listen((value) {
        if (value.isNotEmpty) {
          parseIncomingData(utf8.decode(value, allowMalformed: true));
        }
      });

      // Register the notification listener first, then request the initial
      // state. The firmware can answer SYNC very quickly after the write.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      _syncFrameReceived = false;
      _isInitialSync = true;

      for (int attempt = 0; attempt < 3 && mounted && !_syncFrameReceived; attempt++) {
        await sendCommand('SYNC', showError: false);

        final syncDeadline = DateTime.now().add(
          const Duration(seconds: 1),
        );

        while (mounted &&
            !_syncFrameReceived &&
            DateTime.now().isBefore(syncDeadline)) {
          await Future<void>.delayed(
            const Duration(milliseconds: 50),
          );
        }

        if (!_syncFrameReceived && attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }

      if (!_syncFrameReceived) {
        _showSnackBar(
          'Device Sync Failed — keeping connection for retry',
          color: Colors.redAccent,
        );
        _isInitialSync = false;
        return;
      }

      final configParts = <String>[
        'AI=${isAiModeOn ? 1 : 0}',
        'AIM=$aiModeType',
        'LHT=$limitHot',
        'LB5=$limitBat5v',
        'LB12=$limitBat12v',
      ];
      if (phoneBatteryTempAvailable && aiModeType == 1) {
        configParts.add(
          'BT=${phoneBatteryTemp.toStringAsFixed(1)}',
        );
      }
      await sendCommand(
        'CFG:${configParts.join(';')}',
        showError: false,
      );
      _lastSentBatteryProtectionLevel =
          phoneBatteryTempAvailable
              ? _batteryProtectionLevel(phoneBatteryTemp)
              : 0;

      if (mounted) {
        setState(() {
          isConnected = true;
          _isInitialSync = false;
        });
      }
    } catch (e) {
      debugPrint('Discovery Error: $e');
      _showSnackBar('Bluetooth service setup failed', color: Colors.redAccent);
    }
  }

  Future<void> disconnectDevice() async {
    try {
      await targetDevice?.disconnect();
    } catch (e) {
      debugPrint('BLE disconnect error: $e');
    }
  }

  void parseIncomingData(String incoming) {
    try {
      _incomingBuffer += incoming;

      if (_incomingBuffer.length > 8192) {
        final marker = _incomingBuffer.lastIndexOf('<SYNC_START>');
        _incomingBuffer = marker >= 0
            ? _incomingBuffer.substring(marker)
            : '';
      }

      if (_incomingBuffer.contains('<SYNC_START>') &&
          _incomingBuffer.contains('<SYNC_END>')) {
        final start = _incomingBuffer.indexOf('<SYNC_START>');
        final end = _incomingBuffer.indexOf('<SYNC_END>');

        if (start < end) {
          final payload = _incomingBuffer.substring(
            start + '<SYNC_START>'.length,
            end,
          );

          _incomingBuffer = _incomingBuffer.substring(
            end + '<SYNC_END>'.length,
          );

          for (final line in payload.split('\n')) {
            _updateField(line.trim());
          }

          _syncFrameReceived = true;

          if (mounted && !_isInitialSync && isConnected) {
            setState(() {});
          }

          return;
        }
      }

      if (!_incomingBuffer.contains('<SYNC_START>')) {
        bool changed = false;

        while (_incomingBuffer.contains('\n')) {
          final nl = _incomingBuffer.indexOf('\n');
          final line = _incomingBuffer
              .substring(0, nl)
              .trim();

          _incomingBuffer = _incomingBuffer.substring(nl + 1);

          if (line.isNotEmpty) {
            changed = _updateField(line) || changed;
          }
        }

        if (changed && mounted && isConnected) {
          setState(() {});
        }
      }
    } catch (e) {
      debugPrint('Parse stream error: $e');
    }
  }

  bool _updateField(String line) {
    if (!line.contains(":")) return false;
    final separator = line.indexOf(':');
    if (separator <= 0) return false;

    final key = line.substring(0, separator).trim();
    final value = line.substring(separator + 1).trim();

    if (key == 'STATE' || key == 'RGBSTATE' || key == 'TEMPSET') {
      var changed = false;
      for (final part in value.split(';')) {
        final p = part.trim();
        final eq = p.indexOf('=');
        if (eq <= 0) continue;
        final subKey = p.substring(0, eq).trim();
        final subValue = p.substring(eq + 1).trim();
        if (_updateField('$subKey:$subValue')) {
          changed = true;
        }
      }
      return changed;
    }

    if (key == "TMP") {
      final parsedTemp = double.tryParse(value);
      hotsideTemp = parsedTemp != null && parsedTemp >= 998.0
          ? "--"
          : value.replaceAll(RegExp(r'\.0+$'), '');
      if (isCloudSyncing && _dbRef != null) {
        _dbRef!.child("telemetry/hotside_temp").set(hotsideTemp);
      }
    } else if (key == "VOL") {
      voltage = value;
      if (isCloudSyncing && _dbRef != null) _dbRef!.child("telemetry/voltage").set(voltage);
    } else if (key == "RGB") {
      isRgbOn = (value == "1");
    } else if (key == "AI") {
      isAiModeOn = (value == "1");
    } else if (key == "AIM") {
      final mode = int.tryParse(value);
      if (mode != null && (mode == 0 || mode == 1)) {
        aiModeType = mode;
      }
    } else if (key == "BRV") {
      brightness = double.tryParse(value) ?? 255;
    } else if (key == "VER") {
      currentVersion = value;
    } else if (key == "MD") {
      rgbModeIndex = (int.tryParse(value) ?? 0);
    } else if (key == "LIM") {
      final parts = value.split(',');
      if (parts.length == 4) {
        final hot = int.tryParse(parts[0]);
        final b5 = int.tryParse(parts[1]);
        final b12 = int.tryParse(parts[3]);
        if (hot != null && b5 != null && b12 != null) {
          limitHot = hot;
          limitBat5v = b5;
          limitBat12v = b12;
          _normalizeBatteryLimits();
        }
      }
    } else if (key == "LHT") {
      limitHot = int.tryParse(value) ?? 45;
    } else if (key == "LB5") {
      limitBat5v = int.tryParse(value) ?? 25;
      _normalizeBatteryLimits();
    } else if (key == "LB9") {
      // Firmware reports the locked 9V operating range as MIN-MAX.
      // The editable thresholds remain LB5 and LB12.
    } else if (key == "LB12") {
      limitBat12v = int.tryParse(value) ?? 35;
      _normalizeBatteryLimits();
    } else {
      return false;
    }
    return true;
  }

  void _normalizeBatteryLimits({int? changed}) {
    limitBat5v = limitBat5v.clamp(10, 59).toInt();
    limitBat12v = limitBat12v.clamp(11, 60).toInt();

    // Keep at least one integer temperature inside the locked 9V band.
    if (limitBat12v < limitBat5v + 2) {
      if (changed == 5) {
        limitBat12v = (limitBat5v + 2).clamp(12, 60).toInt();
      } else {
        limitBat5v = (limitBat12v - 2).clamp(10, 58).toInt();
      }
    }
  }

  Future<void> _sendBatteryLimitSettings() async {
    if (!isConnected) {
      return;
    }

    _normalizeBatteryLimits();

    final tempParts = <String>[
      'LHT=$limitHot',
      'LB5=$limitBat5v',
      'LB12=$limitBat12v',
    ];
    if (isAiModeOn && aiModeType == 1 && phoneBatteryTempAvailable) {
      tempParts.add('BT=${phoneBatteryTemp.toStringAsFixed(1)}');
    }
    await sendCommand(
      'TEMPSET:${tempParts.join(';')}',
      showError: false,
    );

    if (isCloudSyncing && _dbRef != null) {
      await _dbRef!.child('settings/limit_hot').set(limitHot);
      await _dbRef!.child('settings/limit_bat_5v').set(limitBat5v);
      await _dbRef!.child('settings/limit_bat_9v_min').set(limitBat9vMin);
      await _dbRef!.child('settings/limit_bat_9v_max').set(limitBat9vMax);
      await _dbRef!.child('settings/limit_bat_12v').set(limitBat12v);
    }
  }

  Future<bool> sendCommand(String cmd, {bool showError = true}) {
    final completer = Completer<bool>();
    _commandWriteQueue = _commandWriteQueue.then((_) async {
      // During the initial handshake, isConnected intentionally remains false
      // until the framed SYNC response is received. The initial SYNC command
      // must therefore be allowed before isConnected becomes true.
      final canWriteDuringInitialSync = _isInitialSync && _connectionEverEstablished;
      if (rxChar == null || (!isConnected && !canWriteDuringInitialSync)) {
        if (showError && mounted) {
          _showSnackBar('Bluetooth Not Synchronized!', color: Colors.orangeAccent);
        }
        completer.complete(false);
        return;
      }

      try {
        final payload = utf8.encode('$cmd\n');
        final supportsNoResponse = rxChar!.properties.writeWithoutResponse;
        await rxChar!.write(payload, withoutResponse: supportsNoResponse);
        completer.complete(true);
      } catch (e) {
        debugPrint('BLE write failed ($cmd): $e');
        completer.complete(false);
      }
    }).catchError((error) {
      if (!completer.isCompleted) completer.complete(false);
    });
    return completer.future;
  }

  Future<void> _waitForVersionSync() async {
    if (currentVersion != 'V?') return;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (mounted && currentVersion == 'V?' && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _openFirmwareUpdateMenu() async {
    if (!isConnected) {
      _showSnackBar('Connect to Horizon Cooler first!', color: Colors.orangeAccent);
      return;
    }
    await sendCommand('SYNC');
    await _waitForVersionSync();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) {
        return FirmwareUpdateDialog(
          currentVersion: currentVersion,
          dbRef: _dbRef,
          onUpdateTriggered: (ssid, pass, url) {
            _showSnackBar("Firmware Update Initiated!", color: Colors.purpleAccent);
            _triggerCloudOTASequence(ssid, pass, url);
          },
        );
      },
    );
  }

  void _triggerCloudOTASequence(String ssid, String pass, String fwUrl) async {
    if (!isConnected) return;
    if (!await sendCommand('OTAENTER')) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!await sendCommand('SSID:$ssid')) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!await sendCommand('PASS:$pass')) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!await sendCommand('URL:$fwUrl')) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await sendCommand('CLOUDOTA');
  }

  void resetTempSettings() {
    setState(() {
      limitHot = 45;
      limitBat5v = 25;
      limitBat12v = 35;
      _normalizeBatteryLimits();
    });

    if (isConnected) {
      _sendBatteryLimitSettings();
    }

    _showSnackBar(
      "Settings Reset to Default",
      color: Colors.green,
    );
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
        actions: [ 
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white), 
            onPressed: _openFirmwareUpdateMenu, 
          ), 
        ],
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
                      _buildTopData(
                        isConnected && phoneBatteryTempAvailable
                            ? phoneBatteryTemp.toStringAsFixed(1)
                            : "--",
                        "°C",
                        "Battery Temperature",
                        color: Colors.orangeAccent,
                      ),
                      const SizedBox(height: 20),
                      _buildTopData(
                        isConnected ? hotsideTemp : "--",
                        "°C",
                        "Hotside Temperature",
                        color: Colors.cyanAccent,
                      ),
                      const SizedBox(height: 20),
                      _buildTopData(
                        isConnected ? voltage.replaceAll('V', '') : "--",
                        "V",
                        "Voltage Indicator",
                        color: Colors.blueAccent,
                      ),
                      const SizedBox(height: 20),
                      _buildTopData(
                        isConnected ? (isAiModeOn ? "ON" : "OFF") : "--",
                        "",
                        "Adaptive Mode",
                        color: isAiModeOn
                            ? Colors.greenAccent
                            : Colors.grey,
                      ),
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
                      Expanded(child: _buildTabMenu("Adaptive Mode", 1)),
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
            style: TextStyle(color: isSelected ? Colors.white : Colors.black54, fontWeight: FontWeight.bold, fontSize: 12),
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
          const Text(
            "Voltage Locked by Adaptive Mode",
            style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
          ),
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
      opacity: !isConnected || isAiModeOn ? 0.4 : 1.0,
      child: InkWell(
        onTap: !isConnected || isAiModeOn ? null : () {
          setState(() => voltage = v);
          sendCommand(v);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: isActive ? Colors.black : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isActive ? Colors.black : Colors.grey.shade300, width: 2),
            boxShadow: isActive ? [const BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 5))] : [],
          ),
          child: Center(
            child: Text(
              v,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.black87,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAiMenu() {
    return Column(
      children: [
        ListTile(
          title: const Text("Master Adaptive Switch", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          subtitle: const Text("Turn adaptive control ON or OFF"),
          trailing: Switch(
            value: isConnected && isAiModeOn,
            activeColor: Colors.blueAccent,
            onChanged: isConnected ? (val) async {
              setState(() => isAiModeOn = val);
              if (!val) {
                }
              final adaptParts = <String>[
                'ON=${val ? 1 : 0}',
                'MODE=$aiModeType',
              ];
              if (val && aiModeType == 1 && phoneBatteryTempAvailable) {
                adaptParts.add('BT=${phoneBatteryTemp.toStringAsFixed(1)}');
              }
              final sent = await sendCommand(
                'ADAPT:${adaptParts.join(';')}',
                showError: false,
              );
              if (sent && val && aiModeType == 1 && phoneBatteryTempAvailable) {
                _lastSentBatteryProtectionLevel =
                    _batteryProtectionLevel(phoneBatteryTemp);
              }
            } : null,
          ),
        ),
        const Divider(),
        _aiOptionTile(0, "Temperature Protection", "Protect the cooler from overheating."),
        _aiOptionTile(1, "Temperature + Battery Protection", "Adjust voltage automatically from phone battery temperature."),
      ],
    );
  }

  Widget _aiOptionTile(int index, String title, String sub) {
    bool isSelected = aiModeType == index;
    return InkWell(
      onTap: isConnected ? () async {
        setState(() => aiModeType = index);
        final adaptParts = <String>[
          'ON=${isAiModeOn ? 1 : 0}',
          'MODE=$index',
        ];
        if (isAiModeOn && index == 1 && phoneBatteryTempAvailable) {
          adaptParts.add('BT=${phoneBatteryTemp.toStringAsFixed(1)}');
        }
        final sent = await sendCommand(
          'ADAPT:${adaptParts.join(';')}',
          showError: false,
        );
        if (sent && isAiModeOn && index == 1 && phoneBatteryTempAvailable) {
          _lastSentBatteryProtectionLevel =
              _batteryProtectionLevel(phoneBatteryTemp);
        }
      } : null,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.withOpacity(0.1) : Colors.white,
          border: Border.all(color: isSelected ? Colors.blueAccent : Colors.grey.shade300, width: 2),
          borderRadius: BorderRadius.circular(15),
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
            ),
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
          onTap: !isConnected ? null : () {
            setState(() => isRgbOn = !isRgbOn);
            sendCommand("RGBTOGGLE", showError: false);
          },
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
              onPressed: isConnected ? () {
                sendCommand("RGBPREV", showError: false);
              } : null,
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
              decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(15)),
              child: Text("Mode $rgbModeIndex", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, color: Colors.black87),
              onPressed: isConnected ? () {
                sendCommand("RGBNEXT", showError: false);
              } : null,
            ),
          ],
        ),
        const SizedBox(height: 25),
        Row(
          children: [
            const Icon(Icons.brightness_low, color: Colors.grey),
            Expanded(
              child: Slider(
                value: brightness, 
                min: 1, 
                max: 255, 
                activeColor: Colors.black, 
                inactiveColor: Colors.grey.shade300,
                onChangeEnd: isConnected
                    ? (val) => sendCommand("BR:${val.toInt()}", showError: false)
                    : null,
                onChanged: isConnected
                    ? (val) => setState(() => brightness = val)
                    : null,
              ),
            ),
            Text(
              isConnected
                  ? "${(brightness / 255 * 100).toInt()}%"
                  : "--",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        )
      ],
    );
  }

  Widget _buildTempSettingMenu() {
    final batteryRangeText =
        '$limitBat5v°C → $limitBat9vMin–$limitBat9vMax°C → $limitBat12v°C';

    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        const SizedBox(height: 6),
        const Text(
          'Hotside Protection',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: Colors.black54,
          ),
        ),
        _tempAdjusterTile(
          'Hotside Overheat Limit',
          limitHot,
          (v) {
            if (!isConnected) {
              return;
            }

            final next = v.clamp(35, 80).toInt();
            if (next == limitHot) {
              return;
            }

            setState(() {
              limitHot = next;
            });

            sendCommand(
              'LHT:$next',
              showError: false,
            );
          },
          '°C',
          35,
          80,
        ),
        const SizedBox(height: 10),
        const Divider(),
        const SizedBox(height: 8),
        const Text(
          'Battery Temperature → Voltage',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.grey.shade300,
            ),
          ),
          child: Column(
            children: [
              _batteryLimitRow(
                title: '5V',
                subtitle: 'Below',
                value: limitBat5v,
                enabled: isConnected,
                onMinus: () {
                  if (!isConnected) return;
                  final next = (limitBat5v - 1).clamp(10, 59).toInt();
                  setState(() {
                    limitBat5v = next;
                    _normalizeBatteryLimits(changed: 5);
                  });
                  _sendBatteryLimitSettings();
                },
                onPlus: () {
                  if (!isConnected) return;
                  final next = (limitBat5v + 1).clamp(10, 59).toInt();
                  if (next >= limitBat12v - 1) return;
                  setState(() {
                    limitBat5v = next;
                    _normalizeBatteryLimits(changed: 5);
                  });
                  _sendBatteryLimitSettings();
                },
              ),
              const Divider(height: 18),
              _batteryLimitRangeRow(
                title: '9V',
                subtitle: 'Automatic range • LOCKED',
                low: limitBat9vMin,
                high: limitBat9vMax,
              ),
              const Divider(height: 18),
              _batteryLimitRow(
                title: '12V',
                subtitle: 'At / Above',
                value: limitBat12v,
                enabled: isConnected,
                onMinus: () {
                  if (!isConnected) return;
                  final next = (limitBat12v - 1).clamp(11, 60).toInt();
                  if (next <= limitBat5v + 1) return;
                  setState(() {
                    limitBat12v = next;
                    _normalizeBatteryLimits(changed: 12);
                  });
                  _sendBatteryLimitSettings();
                },
                onPlus: () {
                  if (!isConnected) return;
                  final next = (limitBat12v + 1).clamp(11, 60).toInt();
                  setState(() {
                    limitBat12v = next;
                    _normalizeBatteryLimits(changed: 12);
                  });
                  _sendBatteryLimitSettings();
                },
              ),
              const SizedBox(height: 10),
              Text(
                '9V range is locked between the 5V and 12V thresholds • Current: $batteryRangeText',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent.withOpacity(0.1),
            foregroundColor: Colors.red,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          onPressed: isConnected
              ? resetTempSettings
              : null,
          icon: const Icon(Icons.restore),
          label: const Text(
            'Reset to Default Settings',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _batteryLimitRangeRow({
    required String title,
    required String subtitle,
    required int low,
    required int high,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$low–$high°C',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 96),
      ],
    );
  }

  Widget _batteryLimitRow({
    required String title,
    required String subtitle,
    required int value,
    required bool enabled,
    VoidCallback? onMinus,
    VoidCallback? onPlus,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: enabled
                  ? Colors.blueAccent
                  : Colors.grey,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value°C',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: enabled ? onMinus : null,
          icon: const Icon(
            Icons.remove_circle_outline,
          ),
        ),
        IconButton(
          onPressed: enabled ? onPlus : null,
          icon: const Icon(
            Icons.add_circle_outline,
          ),
        ),
      ],
    );
  }

  Widget _tempAdjusterTile(
    String label,
    int value,
    void Function(int) onChanged,
    String unit,
    [int? minValue, int? maxValue]
  ) {
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
                onPressed: minValue != null && value <= minValue
                    ? null
                    : () => onChanged(value - 1),
              ),
              SizedBox(
                width: 45,
                child: Center(
                  child: Text(
                    "$value$unit",
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                      color: Colors.blueAccent,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, color: Colors.black54),
                onPressed: maxValue != null && value >= maxValue
                    ? null
                    : () => onChanged(value + 1),
              ),
            ],
          )
        ],
      ),
    );
  }
}

class FirmwareUpdateDialog extends StatefulWidget {
  final String currentVersion;
  final DatabaseReference? dbRef;
  final Function(String, String, String) onUpdateTriggered;

  const FirmwareUpdateDialog({
    super.key,
    required this.currentVersion,
    required this.dbRef,
    required this.onUpdateTriggered,
  });

  @override
  State<FirmwareUpdateDialog> createState() => _FirmwareUpdateDialogState();
}

class _FirmwareUpdateDialogState extends State<FirmwareUpdateDialog> {
  bool isChecking = true;
  String latestVersion = "";
  String fwUrl = "";
  bool hasUpdate = false;

  final TextEditingController ssidCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    _checkFirebaseForUpdate();
  }

  @override
  void didUpdateWidget(covariant FirmwareUpdateDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentVersion != widget.currentVersion) {
      _checkFirebaseForUpdate();
    }
  }

  @override
  void dispose() {
    ssidCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        ssidCtrl.text = prefs.getString("saved_ssid") ?? "";
        passCtrl.text = prefs.getString("saved_pass") ?? "";
      });
    }
  }

  int _versionValue(String version) {
    final match = RegExp(r'^V(\d+)(?:\.(\d+))?$').firstMatch(version.trim().toUpperCase());
    if (match == null) return -1;
    final major = int.tryParse(match.group(1)!) ?? 0;
    final minor = int.tryParse(match.group(2) ?? '0') ?? 0;
    return major * 100 + minor;
  }

  Future<void> _checkFirebaseForUpdate() async {
    if (widget.dbRef == null) {
      if (mounted) {
        setState(() {
          isChecking = false;
          latestVersion = widget.currentVersion;
          hasUpdate = false;
        });
      }
      return;
    }

    try {
      final snapshot = await widget.dbRef!.child("firmware_update").get();
      if (snapshot.exists && snapshot.value != null) {
        final raw = snapshot.value;
        if (raw is Map) {
          final data = Map<String, dynamic>.from(raw);
          latestVersion = data['version']?.toString() ?? widget.currentVersion;
          fwUrl = data['url']?.toString() ?? '';
        } else {
          latestVersion = widget.currentVersion;
        }
      } else {
        latestVersion = widget.currentVersion;
      }
    } catch (e) {
      latestVersion = widget.currentVersion;
    }

    if (mounted) {
      setState(() {
        isChecking = false;
        hasUpdate = (widget.currentVersion != 'V?' &&
            _versionValue(latestVersion) > _versionValue(widget.currentVersion) &&
            latestVersion.isNotEmpty &&
            fwUrl.isNotEmpty);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E202B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text("Firmware Settings", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      content: isChecking
          ? const SizedBox(
              height: 100,
              child: Center(child: CircularProgressIndicator(color: Colors.blueAccent)),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Current Firmware: ${widget.currentVersion}", style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Text("Latest Firmware: $latestVersion", style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 20),
                if (!hasUpdate)
                  Center(
                    child: Text(
                      widget.currentVersion == "V?" 
                          ? "Synchronizing Device Version..." 
                          : "System is Up to Date", 
                      style: TextStyle(
                        color: widget.currentVersion == "V?" ? Colors.orangeAccent : Colors.greenAccent, 
                        fontWeight: FontWeight.bold, 
                        fontSize: 15,
                      ),
                    ),
                  )
                else ...[
                  const Text("New Firmware Available!", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 15),
                  TextField(
                    controller: ssidCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: "WiFi SSID",
                      labelStyle: TextStyle(color: Colors.grey),
                      prefixIcon: Icon(Icons.wifi, color: Colors.blueAccent),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                    ),
                  ),
                  TextField(
                    controller: passCtrl,
                    style: const TextStyle(color: Colors.white),
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: "Password",
                      labelStyle: TextStyle(color: Colors.grey),
                      prefixIcon: Icon(Icons.lock, color: Colors.blueAccent),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                    ),
                  ),
                ],
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Close", style: TextStyle(color: Colors.grey)),
        ),
        if (hasUpdate && !isChecking)
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('saved_ssid', ssidCtrl.text.trim());
              await prefs.setString('saved_pass', passCtrl.text);

              if (!context.mounted) return;
              widget.onUpdateTriggered(ssidCtrl.text, passCtrl.text, fwUrl);
              Navigator.pop(context);
            },
            child: const Text("Update Firmware", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
      ],
    );
  }
}
