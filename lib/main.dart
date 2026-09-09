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

  runApp(const HorizonCoolerApp());
}

/// Backwards-compatible alias for projects/tests that still use
/// the default Flutter template name.
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

  StreamSubscription<BluetoothConnectionState>?
      connectionSubscription;
  StreamSubscription<List<int>>? dataSubscription;
  StreamSubscription<DatabaseEvent>?
      _firebaseConnectionSubscription;

  bool _connectionEverEstablished = false;

  Future<void> _commandWriteQueue =
      Future<void>.value();

  double _lastSentPhoneBatteryTemp = -999.0;

  bool isConnected = false;

  final String serviceUUID =
      "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d";

  final String charRxUUID =
      "b2c3d4e5-f6a7-4b5c-8d9e-1f2a3b4c5d6e";

  final String charTxUUID =
      "c3d4e5f6-a7b8-4c5d-8e9f-2a3b4c5d6e7f";

  String hotsideTemp = "--";
  String voltage = "5V";

  bool isRgbOn = true;
  bool isAiModeOn = false;

  double brightness = 255;

  String currentVersion = "V?";
  int rgbModeIndex = 0;

  bool isCloudSyncing = false;

  DatabaseReference? _dbRef;

  final String firebaseDbUrl =
      "https://horizon-cooler-a4723-default-rtdb.asia-southeast1.firebasedatabase.app";

  int selectedMenuIndex = 0;

  double phoneBatteryTemp = -1.0;
  bool phoneBatteryTempAvailable = false;

  Timer? _batteryTempTimer;

  int aiModeType = 0;

  int limitHot = 45;
  int limitBat5v = 25;
  int limitBat9v = 30;
  int limitBat12v = 35;

  String _incomingBuffer = "";

  static const platformChannel =
      MethodChannel('horizon_cooler/battery_temp');

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
        databaseURL: firebaseDbUrl,
      ).ref();

      _initFirebaseMonitoring();
    } catch (e) {
      debugPrint(
        "Firebase Database Unavailable: $e",
      );
    }
  }

  Future<void> _fetchBatteryTemperature() async {
    try {
      final result =
          await platformChannel.invokeMethod<dynamic>(
        'getBatteryTemperature',
      );

      final nativeTemp =
          result is num
              ? result.toDouble()
              : -1.0;

      final valid =
          nativeTemp >= 0.0 &&
          nativeTemp <= 100.0;

      if (!mounted) {
        return;
      }

      if (valid) {
        final changed =
            !phoneBatteryTempAvailable ||
            (nativeTemp - phoneBatteryTemp)
                    .abs() >=
                0.1;

        if (changed) {
          setState(() {
            phoneBatteryTemp = nativeTemp;
            phoneBatteryTempAvailable = true;
          });
        }

        if (
          isConnected &&
          aiModeType == 1 &&
          (nativeTemp -
                      _lastSentPhoneBatteryTemp)
                  .abs() >=
              0.2
        ) {
          _lastSentPhoneBatteryTemp =
              nativeTemp;

          await sendCommand(
            'BTP:${nativeTemp.toStringAsFixed(1)}',
          );
        }

        if (
          isCloudSyncing &&
          _dbRef != null
        ) {
          await _dbRef!
              .child(
                'telemetry/battery_temp',
              )
              .set(
                nativeTemp.toStringAsFixed(1),
              );

          await _dbRef!
              .child(
                'telemetry/battery_temp_available',
              )
              .set(true);
        }
      } else {
        if (phoneBatteryTempAvailable) {
          setState(() {
            phoneBatteryTempAvailable = false;
          });
        }

        if (
          isCloudSyncing &&
          _dbRef != null
        ) {
          await _dbRef!
              .child(
                'telemetry/battery_temp',
              )
              .set(null);

          await _dbRef!
              .child(
                'telemetry/battery_temp_available',
              )
              .set(false);
        }
      }
    } catch (e) {
      debugPrint(
        'Direct battery fetch error: $e',
      );

      if (!mounted) {
        return;
      }

      if (phoneBatteryTempAvailable) {
        setState(() {
          phoneBatteryTempAvailable = false;
        });
      }
    }
  }

  void _startRealtimeBatteryTempReader() {
    _batteryTempTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) async {
        await _fetchBatteryTemperature();
      },
    );
  }

  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      final scan =
          await Permission.bluetoothScan.request();

      final connect =
          await Permission.bluetoothConnect.request();

      // Android 11 and below require location permission
      // for BLE scans.
      if (
        !scan.isGranted ||
        !connect.isGranted
      ) {
        await Permission.locationWhenInUse
            .request();
      }

      final adapterState =
          await FlutterBluePlus.adapterState.first;

      if (
        adapterState ==
        BluetoothAdapterState.off
      ) {
        await FlutterBluePlus.turnOn();
      }
    } catch (e) {
      debugPrint(
        'Bluetooth permission/setup error: $e',
      );
    }
  }

  void _initFirebaseMonitoring() {
    if (_dbRef == null) {
      return;
    }

    _firebaseConnectionSubscription
        ?.cancel();

    _firebaseConnectionSubscription =
        _dbRef!
            .child('.info/connected')
            .onValue
            .listen(
      (event) {
        if (!mounted) {
          return;
        }

        final value =
            event.snapshot.value;

        setState(() {
          isCloudSyncing =
              value is bool && value;
        });
      },
    );
  }

  void _showSnackBar(
    String message, {
    Color color = Colors.blueAccent,
  }) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
        .hideCurrentSnackBar();

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(10),
        ),
        margin: const EdgeInsets.all(10),
        duration:
            const Duration(seconds: 2),
      ),
    );
  }

  void showBluetoothMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor:
          const Color(0xFF15161E),
      shape:
          const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(
          top: Radius.circular(25),
        ),
      ),
      builder: (context) {
        return SizedBox(
          height:
              MediaQuery.of(context)
                      .size
                      .height *
                  0.5,
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 15,
                ),
                decoration:
                    const BoxDecoration(
                  color:
                      Color(0xFF1E202B),
                  borderRadius:
                      BorderRadius.vertical(
                    top:
                        Radius.circular(25),
                  ),
                ),
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment
                          .spaceBetween,
                  children: [
                    const Text(
                      "Select Device",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream:
                          FlutterBluePlus
                              .isScanning,
                      initialData: false,
                      builder:
                          (c, snapshot) {
                        if (
                          snapshot.data ==
                          true
                        ) {
                          return const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(
                              color:
                                  Colors.blueAccent,
                              strokeWidth: 2,
                            ),
                          );
                        }

                        return IconButton(
                          icon:
                              const Icon(
                            Icons.refresh,
                            color:
                                Colors.blueAccent,
                          ),
                          onPressed:
                              _startSafeScan,
                        );
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: StreamBuilder<
                    List<ScanResult>>(
                  stream:
                      FlutterBluePlus
                          .scanResults,
                  initialData: const [],
                  builder:
                      (c, snapshot) {
                    final results =
                        snapshot.data ??
                            [];

                    final horizonDevices =
                        results.where(
                      (r) {
                        String devName =
                            r.device.platformName
                                    .isNotEmpty
                                ? r.device
                                    .platformName
                                : r
                                    .advertisementData
                                    .advName;

                        if (
                          devName
                              .trim()
                              .isEmpty
                        ) {
                          return false;
                        }

                        return devName
                            .toUpperCase()
                            .contains(
                              "HORIZON",
                            );
                      },
                    ).toList();

                    if (
                      horizonDevices
                          .isEmpty
                    ) {
                      return const Center(
                        child: Text(
                          "Scanning for Horizon Cooler...",
                          style: TextStyle(
                            color:
                                Colors.grey,
                          ),
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount:
                          horizonDevices
                              .length,
                      itemBuilder:
                          (context, index) {
                        final r =
                            horizonDevices[
                                index];

                        String devName =
                            r.device.platformName
                                    .isNotEmpty
                                ? r.device
                                    .platformName
                                : r
                                    .advertisementData
                                    .advName;

                        return ListTile(
                          leading:
                              const Icon(
                            Icons.bluetooth,
                            color:
                                Colors.blueAccent,
                          ),
                          title: Text(
                            devName,
                            style:
                                const TextStyle(
                              color:
                                  Colors.white,
                              fontWeight:
                                  FontWeight
                                      .bold,
                            ),
                          ),
                          subtitle: Text(
                            r.device.remoteId
                                .toString(),
                            style:
                                const TextStyle(
                              color:
                                  Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(
                              context,
                            );

                            connectToDevice(
                              r.device,
                            );
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
      await FlutterBluePlus.startScan(
        timeout:
            const Duration(seconds: 15),
      );
    } catch (e) {
      debugPrint(
        'BLE scan start error: $e',
      );
    }
  }

  Future<void> connectToDevice(
    BluetoothDevice device,
  ) async {
    _showSnackBar(
      'Connecting...',
      color: Colors.blueGrey,
    );

    try {
      await FlutterBluePlus.stopScan();

      await connectionSubscription
          ?.cancel();

      await dataSubscription?.cancel();

      if (
        targetDevice != null &&
        targetDevice != device
      ) {
        try {
          await targetDevice!.disconnect();
        } catch (e) {
          debugPrint(
            'Previous BLE device disconnect error: $e',
          );
        }
      }

      targetDevice = device;

      txChar = null;
      rxChar = null;

      _connectionEverEstablished =
          false;

      _incomingBuffer = '';

      connectionSubscription =
          device.connectionState.listen(
        (state) async {
          if (
            state ==
            BluetoothConnectionState
                .connected
          ) {
            _connectionEverEstablished =
                true;

            if (mounted) {
              setState(() {
                isConnected = true;
              });
            }

            if (Platform.isAndroid) {
              try {
                await device.requestMtu(
                  512,
                );
              } catch (e) {
                debugPrint(
                  'MTU request error: $e',
                );
              }
            }

            await discoverServices(
              device,
            );
          } else if (
            state ==
            BluetoothConnectionState
                .disconnected
          ) {
            await dataSubscription
                ?.cancel();

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

                _lastSentPhoneBatteryTemp =
                    -999.0;

                phoneBatteryTempAvailable =
                    false;
              });
            }

            if (
              _connectionEverEstablished
            ) {
              _showSnackBar(
                'Connection Lost',
                color:
                    Colors.redAccent,
              );
            }
          }
        },
      );

      await device.connect(
        autoConnect: false,
        timeout:
            const Duration(seconds: 10),
      );
    } catch (e) {
      _connectionEverEstablished =
          false;

      if (mounted) {
        setState(() {
          isConnected = false;

          txChar = null;
          rxChar = null;
        });
      }

      _showSnackBar(
        'Failed to connect!',
        color: Colors.redAccent,
      );

      try {
        await device.disconnect();
      } catch (e) {
        debugPrint(
          'BLE disconnect after connection failure: $e',
        );
      }
    }
  }

  Future<void> discoverServices(
    BluetoothDevice device,
  ) async {
    try {
      final services =
          await device.discoverServices();

      BluetoothCharacteristic?
          discoveredTx;

      BluetoothCharacteristic?
          discoveredRx;

      for (
        final service in services
      ) {
        if (
          service.uuid
                  .toString()
                  .toLowerCase() !=
              serviceUUID.toLowerCase()
        ) {
          continue;
        }

        for (
          final characteristic
              in service.characteristics
        ) {
          final id =
              characteristic.uuid
                  .toString()
                  .toLowerCase();

          if (
            id ==
            charTxUUID.toLowerCase()
          ) {
            discoveredTx =
                characteristic;
          } else if (
            id ==
            charRxUUID.toLowerCase()
          ) {
            discoveredRx =
                characteristic;
          }
        }
      }

      if (
        discoveredTx == null ||
        discoveredRx == null
      ) {
        _showSnackBar(
          'UUID Mismatch!',
          color:
              Colors.redAccent,
        );

        try {
          await device.disconnect();
        } catch (e) {
          debugPrint(
            'BLE disconnect after UUID mismatch: $e',
          );
        }

        return;
      }

      txChar = discoveredTx;
      rxChar = discoveredRx;

      final tx = txChar!;

      if (
        tx.properties.notify ||
        tx.properties.indicate
      ) {
        await tx.setNotifyValue(
          true,
        );
      } else {
        _showSnackBar(
          'TX characteristic cannot notify!',
          color:
              Colors.redAccent,
        );

        await device.disconnect();

        return;
      }

      await dataSubscription?.cancel();

      dataSubscription =
          tx.lastValueStream.listen(
        (value) {
          if (value.isNotEmpty) {
            parseIncomingData(
              utf8.decode(
                value,
                allowMalformed:
                    true,
              ),
            );
          }
        },
      );

      await Future<void>.delayed(
        const Duration(
          milliseconds: 100,
        ),
      );

      await sendCommand('SYNC');

      await sendCommand(
        'AIM:$aiModeType',
      );

      if (
        phoneBatteryTempAvailable &&
        aiModeType == 1
      ) {
        await sendCommand(
          'BTP:${phoneBatteryTemp.toStringAsFixed(1)}',
        );

        _lastSentPhoneBatteryTemp =
            phoneBatteryTemp;
      }
    } catch (e) {
      debugPrint(
        'Discovery Error: $e',
      );

      _showSnackBar(
        'Bluetooth service setup failed',
        color:
            Colors.redAccent,
      );
    }
  }

  Future<void> disconnectDevice() async {
    try {
      await targetDevice?.disconnect();
    } catch (e) {
      debugPrint(
        'BLE disconnect error: $e',
      );
    }
  }

  void parseIncomingData(
    String incoming,
  ) {
    if (!mounted) {
      return;
    }

    try {
      _incomingBuffer += incoming;

      if (
        _incomingBuffer.length >
        8192
      ) {
        final marker =
            _incomingBuffer.lastIndexOf(
          '<SYNC_START>',
        );

        _incomingBuffer =
            marker >= 0
                ? _incomingBuffer
                    .substring(
                    marker,
                  )
                : '';
      }

      // 1. Tangani frame sync.
      if (
        _incomingBuffer
                .contains(
              "<SYNC_START>",
            ) &&
        _incomingBuffer
                .contains(
              "<SYNC_END>",
            )
      ) {
        int start =
            _incomingBuffer.indexOf(
          "<SYNC_START>",
        );

        int end =
            _incomingBuffer.indexOf(
          "<SYNC_END>",
        );

        if (start < end) {
          String payload =
              _incomingBuffer.substring(
            start + 12,
            end,
          );

          _incomingBuffer =
              _incomingBuffer.substring(
            end + 10,
          );

          List<String> lines =
              payload.split('\n');

          for (String l in lines) {
            _updateField(
              l.trim(),
            );
          }

          setState(() {});

          return;
        }
      }

      // 2. Tangani update tunggal
      // setelah sinkronisasi.
      if (
        !_incomingBuffer.contains(
          "<SYNC_START>",
        )
      ) {
        while (
          _incomingBuffer.contains(
            '\n',
          )
        ) {
          int nl =
              _incomingBuffer.indexOf(
            '\n',
          );

          String line =
              _incomingBuffer
                  .substring(
                    0,
                    nl,
                  )
                  .trim();

          _incomingBuffer =
              _incomingBuffer.substring(
            nl + 1,
          );

          if (
            line.isNotEmpty &&
            _updateField(line)
          ) {
            setState(() {});
          }
        }
      }
    } catch (e) {
      debugPrint(
        "Parse stream error: $e",
      );
    }
  }

  bool _updateField(
    String line,
  ) {
    if (!line.contains(":")) {
      return false;
    }

    final separator =
        line.indexOf(':');

    if (separator <= 0) {
      return false;
    }

    final key =
        line.substring(
          0,
          separator,
        ).trim();

    final value =
        line.substring(
          separator + 1,
        ).trim();

    if (key == "TMP") {
      hotsideTemp =
          value.replaceAll(
        RegExp(r'\.0+$'),
        '',
      );

      if (
        isCloudSyncing &&
        _dbRef != null
      ) {
        _dbRef!
            .child(
              "telemetry/hotside_temp",
            )
            .set(
              hotsideTemp,
            );
      }
    } else if (key == "VOL") {
      voltage = value;

      if (
        isCloudSyncing &&
        _dbRef != null
      ) {
        _dbRef!
            .child(
              "telemetry/voltage",
            )
            .set(
              voltage,
            );
      }
    } else if (key == "RGB") {
      isRgbOn = value == "1";
    } else if (key == "AI") {
      isAiModeOn = value == "1";
    } else if (key == "AIM") {
      final mode =
          int.tryParse(value);

      if (
        mode != null &&
        (mode == 0 || mode == 1)
      ) {
        aiModeType = mode;
      }
    } else if (key == "BRV") {
      brightness =
          double.tryParse(value) ??
              255;
    } else if (key == "VER") {
      currentVersion = value;
    } else if (key == "MD") {
      rgbModeIndex =
          int.tryParse(value) ?? 0;
    } else if (key == "LHT") {
      limitHot =
          int.tryParse(value) ?? 45;
    } else if (key == "LB5") {
      limitBat5v =
          int.tryParse(value) ?? 25;
    } else if (key == "LB9") {
      limitBat9v =
          int.tryParse(value) ?? 30;
    } else if (key == "LB12") {
      limitBat12v =
          int.tryParse(value) ?? 35;
    } else {
      return false;
    }

    return true;
  }

  Future<bool> sendCommand(
    String cmd,
  ) {
    final completer =
        Completer<bool>();

    _commandWriteQueue =
        _commandWriteQueue.then(
      (_) async {
        if (
          rxChar == null ||
          !isConnected
        ) {
          if (mounted) {
            _showSnackBar(
              'Bluetooth Not Synchronized!',
              color:
                  Colors.orangeAccent,
            );
          }

          completer.complete(false);
          return;
        }

        try {
          final payload =
              utf8.encode(
            '$cmd\n',
          );

          final supportsNoResponse =
              rxChar!
                  .properties
                  .writeWithoutResponse;

          await rxChar!.write(
            payload,
            withoutResponse:
                supportsNoResponse,
          );

          completer.complete(true);
        } catch (e) {
          debugPrint(
            'BLE write failed ($cmd): $e',
          );

          completer.complete(false);
        }
      },
    ).catchError(
      (error) {
        if (
          !completer.isCompleted
        ) {
          completer.complete(false);
        }
      },
    );

    return completer.future;
  }

  Future<void> _waitForVersionSync() async {
    if (currentVersion != 'V?') {
      return;
    }

    final deadline =
        DateTime.now().add(
      const Duration(seconds: 2),
    );

    while (
      mounted &&
      currentVersion == 'V?' &&
      DateTime.now()
          .isBefore(deadline)
    ) {
      await Future<void>.delayed(
        const Duration(
          milliseconds: 100,
        ),
      );
    }
  }

  Future<void> _openFirmwareUpdateMenu() async {
    if (!isConnected) {
      _showSnackBar(
        'Connect to Horizon Cooler first!',
        color:
            Colors.orangeAccent,
      );

      return;
    }

    await sendCommand('SYNC');

    await _waitForVersionSync();

    if (!mounted) {
      return;
    }

    await showDialog(
      context: context,
      builder: (context) {
        return FirmwareUpdateDialog(
          currentVersion:
              currentVersion,
          dbRef: _dbRef,
          onUpdateTriggered:
              (
            ssid,
            pass,
            url,
          ) {
            _showSnackBar(
              "Firmware Update Initiated!",
              color:
                  Colors.purpleAccent,
            );

            _triggerCloudOTASequence(
              ssid,
              pass,
              url,
            );
          },
        );
      },
    );
  }

  void _triggerCloudOTASequence(
    String ssid,
    String pass,
    String fwUrl,
  ) async {
    if (!isConnected) {
      return;
    }

    if (
      !await sendCommand(
        'OTAENTER',
      )
    ) {
      return;
    }

    await Future<void>.delayed(
      const Duration(
        milliseconds: 250,
      ),
    );

    if (
      !await sendCommand(
        'SSID:$ssid',
      )
    ) {
      return;
    }

    await Future<void>.delayed(
      const Duration(
        milliseconds: 250,
      ),
    );

    if (
      !await sendCommand(
        'PASS:$pass',
      )
    ) {
      return;
    }

    await Future<void>.delayed(
      const Duration(
        milliseconds: 250,
      ),
    );

    if (
      !await sendCommand(
        'URL:$fwUrl',
      )
    ) {
      return;
    }

    await Future<void>.delayed(
      const Duration(
        milliseconds: 250,
      ),
    );

    await sendCommand(
      'CLOUDOTA',
    );
  }

  void resetTempSettings() {
    setState(() {
      limitHot = 45;
      limitBat5v = 25;
      limitBat9v = 30;
      limitBat12v = 35;
    });

    sendCommand("LHT:45");
    sendCommand("LB5:25");
    sendCommand("LB9:30");
    sendCommand("LB12:35");

    _showSnackBar(
      "Settings Reset to Default",
      color:
          Colors.green,
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          const Color(0xFF111113),
      appBar: AppBar(
        title: const Text(
          "Horizon Cooler",
          style: TextStyle(
            fontWeight:
                FontWeight.bold,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        backgroundColor:
            Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            isConnected
                ? Icons
                    .bluetooth_connected
                : Icons.bluetooth,
            color: isConnected
                ? Colors.blueAccent
                : Colors.white,
          ),
          onPressed: isConnected
              ? disconnectDevice
              : showBluetoothMenu,
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.settings,
              color: Colors.white,
            ),
            onPressed:
                _openFirmwareUpdateMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.only(
              left: 20,
              right: 10,
              top: 10,
              bottom: 20,
            ),
            child: Row(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      _buildTopData(
                        phoneBatteryTempAvailable
                            ? phoneBatteryTemp
                                .toStringAsFixed(
                                1,
                              )
                            : "--",
                        "°C",
                        "Battery Temperature",
                        color:
                            Colors.orangeAccent,
                      ),
                      const SizedBox(
                        height: 20,
                      ),
                      _buildTopData(
                        isConnected
                            ? hotsideTemp
                            : "--",
                        "°C",
                        "Hotside Temperature",
                        color:
                            Colors.cyanAccent,
                      ),
                      const SizedBox(
                        height: 20,
                      ),
                      _buildTopData(
                        isConnected
                            ? voltage.replaceAll(
                                'V',
                                '',
                              )
                            : "--",
                        "V",
                        "Voltage Indicator",
                        color:
                            Colors.blueAccent,
                      ),
                      const SizedBox(
                        height: 20,
                      ),
                      _buildTopData(
                        isConnected
                            ? (isAiModeOn
                                ? "ON"
                                : "OFF")
                            : "--",
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
                    offset:
                        const Offset(
                      -25,
                      -10,
                    ),
                    child: Transform.scale(
                      scale: 1.35,
                      child: Image.asset(
                        'assets/cooler.png',
                        fit:
                            BoxFit.contain,
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
              padding:
                  const EdgeInsets.only(
                top: 20,
                left: 10,
                right: 10,
              ),
              decoration:
                  const BoxDecoration(
                color: Colors.white,
                borderRadius:
                    BorderRadius.vertical(
                  top:
                      Radius.circular(35),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .spaceEvenly,
                    children: [
                      Expanded(
                        child:
                            _buildTabMenu(
                          "Voltage",
                          0,
                        ),
                      ),
                      Expanded(
                        child:
                            _buildTabMenu(
                          "Adaptive Mode",
                          1,
                        ),
                      ),
                      Expanded(
                        child:
                            _buildTabMenu(
                          "RGB Led",
                          2,
                        ),
                      ),
                      Expanded(
                        child:
                            _buildTabMenu(
                          "Temp Set",
                          3,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 10,
                  ),
                  const Divider(
                    color:
                        Colors.black12,
                    thickness: 1.5,
                  ),
                  Expanded(
                    child: Container(
                      padding:
                          const EdgeInsets
                              .symmetric(
                        horizontal: 10,
                      ),
                      child:
                          _buildMenuContent(),
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

  Widget _buildTopData(
    String value,
    String unit,
    String label, {
    Color color = Colors.white,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize:
              MainAxisSize.min,
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: 26,
                fontWeight:
                    FontWeight.w900,
              ),
            ),
            if (
              unit.isNotEmpty &&
              value != "--"
            )
              Padding(
                padding:
                    const EdgeInsets.only(
                  top: 4.0,
                  left: 2,
                ),
                child: Text(
                  unit,
                  style:
                      const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(
          height: 2,
        ),
        Text(
          label,
          style:
              const TextStyle(
            color: Colors.grey,
            fontSize: 11,
            fontWeight:
                FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildTabMenu(
    String title,
    int index,
  ) {
    bool isSelected =
        selectedMenuIndex ==
            index;

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedMenuIndex =
              index;
        });
      },
      child: Container(
        margin:
            const EdgeInsets.symmetric(
          horizontal: 2,
        ),
        padding:
            const EdgeInsets.symmetric(
          vertical: 10,
        ),
        decoration:
            BoxDecoration(
          color: isSelected
              ? Colors.black
              : Colors.transparent,
          borderRadius:
              BorderRadius.circular(
            20,
          ),
        ),
        child: Center(
          child: Text(
            title,
            textAlign:
                TextAlign.center,
            style: TextStyle(
              color: isSelected
                  ? Colors.white
                  : Colors.black54,
              fontWeight:
                  FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuContent() {
    switch (
        selectedMenuIndex) {
      case 0:
        return _buildVoltageMenu();

      case 1:
        return _buildAiMenu();

      case 2:
        return _buildRgbMenu();

      case 3:
        return _buildTempSettingMenu();

      default:
        return Container();
    }
  }

  Widget _buildVoltageMenu() {
    return Column(
      mainAxisAlignment:
          MainAxisAlignment.center,
      children: [
        if (isAiModeOn) ...[
          const Icon(
            Icons.lock_outline,
            color:
                Colors.redAccent,
            size: 50,
          ),
          const SizedBox(
            height: 10,
          ),
          const Text(
            "Voltage Locked by Adaptive Mode",
            style: TextStyle(
              color:
                  Colors.redAccent,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          const SizedBox(
            height: 20,
          ),
        ],
        Row(
          mainAxisAlignment:
              MainAxisAlignment
                  .spaceEvenly,
          children: [
            _voltButton("5V"),
            _voltButton("9V"),
            _voltButton("12V"),
          ],
        ),
      ],
    );
  }

  Widget _voltButton(
    String v,
  ) {
    bool isActive =
        voltage == v;

    return Opacity(
      opacity:
          isAiModeOn ? 0.4 : 1.0,
      child: InkWell(
        onTap: isAiModeOn
            ? null
            : () {
                setState(() {
                  voltage = v;
                });

                sendCommand(v);
              },
        child: AnimatedContainer(
          duration:
              const Duration(
            milliseconds: 200,
          ),
          width: 80,
          height: 80,
          decoration:
              BoxDecoration(
            color: isActive
                ? Colors.black
                : Colors.white,
            borderRadius:
                BorderRadius.circular(
              20,
            ),
            border:
                Border.all(
              color: isActive
                  ? Colors.black
                  : Colors.grey.shade300,
              width: 2,
            ),
            boxShadow: isActive
                ? [
                    const BoxShadow(
                      color:
                          Colors.black26,
                      blurRadius: 10,
                      offset:
                          Offset(0, 5),
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: Text(
              v,
              style: TextStyle(
                color: isActive
                    ? Colors.white
                    : Colors.black87,
                fontSize: 22,
                fontWeight:
                    FontWeight.w900,
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
          title: const Text(
            "Master Adaptive Switch",
            style: TextStyle(
              fontWeight:
                  FontWeight.bold,
              fontSize: 16,
            ),
          ),
          subtitle: const Text(
            "Turn adaptive control ON or OFF",
          ),
          trailing: Switch(
            value: isAiModeOn,
            activeColor:
                Colors.blueAccent,
            onChanged:
                (val) async {
              setState(() {
                isAiModeOn =
                    val;
              });

              await sendCommand(
                val
                    ? 'AION'
                    : 'AIOFF',
              );

              await sendCommand(
                'AIM:$aiModeType',
              );

              if (
                val &&
                aiModeType == 1 &&
                phoneBatteryTempAvailable
              ) {
                await sendCommand(
                  'BTP:${phoneBatteryTemp.toStringAsFixed(1)}',
                );

                _lastSentPhoneBatteryTemp =
                    phoneBatteryTemp;
              }
            },
          ),
        ),
        const Divider(),
        _aiOptionTile(
          0,
          "Temperature Protection",
          "Protect the cooler from overheating.",
        ),
        _aiOptionTile(
          1,
          "Temperature + Battery Protection",
          "Adjust voltage automatically from phone battery temperature.",
        ),
      ],
    );
  }

  Widget _aiOptionTile(
    int index,
    String title,
    String sub,
  ) {
    bool isSelected =
        aiModeType == index;

    return InkWell(
      onTap: () async {
        setState(() {
          aiModeType =
              index;
        });

        await sendCommand(
          'AIM:$index',
        );

        if (
          index == 1 &&
          phoneBatteryTempAvailable
        ) {
          await sendCommand(
            'BTP:${phoneBatteryTemp.toStringAsFixed(1)}',
          );

          _lastSentPhoneBatteryTemp =
              phoneBatteryTemp;
        }
      },
      child: Container(
        margin:
            const EdgeInsets.symmetric(
          vertical: 8,
        ),
        padding:
            const EdgeInsets.all(
          15,
        ),
        decoration:
            BoxDecoration(
          color: isSelected
              ? Colors.blue
                  .withOpacity(
                  0.1,
                )
              : Colors.white,
          border:
              Border.all(
            color: isSelected
                ? Colors.blueAccent
                : Colors.grey.shade300,
            width: 2,
          ),
          borderRadius:
              BorderRadius.circular(
            15,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons
                      .check_circle
                  : Icons.circle_outlined,
              color: isSelected
                  ? Colors.blueAccent
                  : Colors.grey,
            ),
            const SizedBox(
              width: 15,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    sub,
                    style: TextStyle(
                      color:
                          Colors.grey.shade600,
                      fontSize: 11,
                    ),
                  ),
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
      mainAxisAlignment:
          MainAxisAlignment.center,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              isRgbOn =
                  !isRgbOn;
            });

            sendCommand(
              "RGBTOGGLE",
            );
          },
          child: AnimatedContainer(
            duration:
                const Duration(
              milliseconds: 200,
            ),
            padding:
                const EdgeInsets.all(
              20,
            ),
            decoration:
                BoxDecoration(
              color: isRgbOn
                  ? Colors.black
                  : Colors.white,
              shape:
                  BoxShape.circle,
              border:
                  Border.all(
                color: isRgbOn
                    ? Colors.black
                    : Colors.grey.shade300,
                width: 2,
              ),
              boxShadow: isRgbOn
                  ? [
                      const BoxShadow(
                        color:
                            Colors.black26,
                        blurRadius: 15,
                      ),
                    ]
                  : [],
            ),
            child: Icon(
              Icons.power_settings_new,
              color: isRgbOn
                  ? Colors.white
                  : Colors.grey,
              size: 40,
            ),
          ),
        ),
        const SizedBox(
          height: 25,
        ),
        Row(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(
                Icons.arrow_back_ios,
                color:
                    Colors.black87,
              ),
              onPressed: () {
                sendCommand(
                  "RGBPREV",
                );
              },
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 30,
                vertical: 10,
              ),
              decoration:
                  BoxDecoration(
                color:
                    Colors.grey.shade100,
                borderRadius:
                    BorderRadius.circular(
                  15,
                ),
              ),
              child: Text(
                "Mode $rgbModeIndex",
                style:
                    const TextStyle(
                  fontWeight:
                      FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.arrow_forward_ios,
                color:
                    Colors.black87,
              ),
              onPressed: () {
                sendCommand(
                  "RGBNEXT",
                );
              },
            ),
          ],
        ),
        const SizedBox(
          height: 25,
        ),
        Row(
          children: [
            const Icon(
              Icons.brightness_low,
              color: Colors.grey,
            ),
            Expanded(
              child: Slider(
                value: brightness,
                min: 1,
                max: 255,
                activeColor:
                    Colors.black,
                inactiveColor:
                    Colors.grey.shade300,
                onChangeEnd:
                    (val) => sendCommand(
                  "BR:${val.toInt()}",
                ),
                onChanged: (val) {
                  setState(() {
                    brightness = val;
                  });
                },
              ),
            ),
            Text(
              "${(brightness / 255 * 100).toInt()}%",
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTempSettingMenu() {
    if (isAiModeOn) {
      return const Column(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline,
            color:
                Colors.redAccent,
            size: 50,
          ),
          SizedBox(
            height: 10,
          ),
          Text(
            "Settings Locked by Adaptive Mode",
            style: TextStyle(
              color:
                  Colors.redAccent,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      );
    }

    return ListView(
      physics:
          const BouncingScrollPhysics(),
      children: [
        _tempAdjusterTile(
          "Coldside / Overheat Limit",
          limitHot,
          (v) {
            setState(() {
              limitHot = v;
            });

            sendCommand(
              "LHT:$v",
            );
          },
          "°C",
        ),
        const Divider(),
        const Padding(
          padding:
              EdgeInsets.symmetric(
            vertical: 8.0,
          ),
          child: Text(
            "Battery Temperature Limits",
            style: TextStyle(
              fontWeight:
                  FontWeight.w900,
              color:
                  Colors.black54,
            ),
          ),
        ),
        _tempAdjusterTile(
          "5V Limit (Drop if <)",
          limitBat5v,
          (v) {
            setState(() {
              limitBat5v = v;
            });

            sendCommand(
              "LB5:$v",
            );
          },
          "°C",
        ),
        _tempAdjusterTile(
          "9V Limit (Normal)",
          limitBat9v,
          (v) {
            setState(() {
              limitBat9v = v;
            });

            sendCommand(
              "LB9:$v",
            );
          },
          "°C",
        ),
        _tempAdjusterTile(
          "12V Limit (Boost if >)",
          limitBat12v,
          (v) {
            setState(() {
              limitBat12v = v;
            });

            sendCommand(
              "LB12:$v",
            );
          },
          "°C",
        ),
        const SizedBox(
          height: 20,
        ),
        ElevatedButton.icon(
          style:
              ElevatedButton.styleFrom(
            backgroundColor:
                Colors.redAccent
                    .withOpacity(
              0.1,
            ),
            foregroundColor:
                Colors.red,
            elevation: 0,
            padding:
                const EdgeInsets
                    .symmetric(
              vertical: 12,
            ),
          ),
          onPressed:
              resetTempSettings,
          icon: const Icon(
            Icons.restore,
          ),
          label: const Text(
            "Reset to Default Settings",
            style: TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(
          height: 20,
        ),
      ],
    );
  }

  Widget _tempAdjusterTile(
    String label,
    int value,
    Function(int) onChanged,
    String unit,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 5,
      ),
      child: Row(
        mainAxisAlignment:
            MainAxisAlignment
                .spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(
                  Icons
                      .remove_circle_outline,
                  color:
                      Colors.black54,
                ),
                onPressed: () {
                  onChanged(
                    value - 1,
                  );
                },
              ),
              SizedBox(
                width: 45,
                child: Center(
                  child: Text(
                    "$value$unit",
                    style:
                        const TextStyle(
                      fontWeight:
                          FontWeight.w900,
                      fontSize: 15,
                      color:
                          Colors.blueAccent,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons
                      .add_circle_outline,
                  color:
                      Colors.black54,
                ),
                onPressed: () {
                  onChanged(
                    value + 1,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class FirmwareUpdateDialog
    extends StatefulWidget {
  final String currentVersion;
  final DatabaseReference? dbRef;

  final Function(
    String,
    String,
    String,
  ) onUpdateTriggered;

  const FirmwareUpdateDialog({
    super.key,
    required this.currentVersion,
    required this.dbRef,
    required this.onUpdateTriggered,
  });

  @override
  State<FirmwareUpdateDialog> createState() =>
      _FirmwareUpdateDialogState();
}

class _FirmwareUpdateDialogState
    extends State<FirmwareUpdateDialog> {
  bool isChecking = true;

  String latestVersion = "";
  String fwUrl = "";

  bool hasUpdate = false;

  final TextEditingController
      ssidCtrl =
      TextEditingController();

  final TextEditingController
      passCtrl =
      TextEditingController();

  @override
  void initState() {
    super.initState();

    _loadSavedCredentials();
    _checkFirebaseForUpdate();
  }

  @override
  void didUpdateWidget(
    covariant FirmwareUpdateDialog
        oldWidget,
  ) {
    super.didUpdateWidget(
      oldWidget,
    );

    if (
      oldWidget.currentVersion !=
      widget.currentVersion
    ) {
      _checkFirebaseForUpdate();
    }
  }

  @override
  void dispose() {
    ssidCtrl.dispose();
    passCtrl.dispose();

    super.dispose();
  }

  Future<void>
      _loadSavedCredentials() async {
    SharedPreferences prefs =
        await SharedPreferences
            .getInstance();

    if (mounted) {
      setState(() {
        ssidCtrl.text =
            prefs.getString(
                  "saved_ssid",
                ) ??
                "";

        passCtrl.text =
            prefs.getString(
                  "saved_pass",
                ) ??
                "";
      });
    }
  }

  int _versionValue(
    String version,
  ) {
    final match = RegExp(
      r'^V(\d+)(?:\.(\d+))?$',
    ).firstMatch(
      version
          .trim()
          .toUpperCase(),
    );

    if (match == null) {
      return -1;
    }

    final major =
        int.tryParse(
              match.group(1)!,
            ) ??
            0;

    final minor =
        int.tryParse(
              match.group(2) ??
                  '0',
            ) ??
            0;

    return major * 100 + minor;
  }

  Future<void>
      _checkFirebaseForUpdate() async {
    if (widget.dbRef == null) {
      if (mounted) {
        setState(() {
          isChecking = false;

          latestVersion =
              widget.currentVersion;

          hasUpdate = false;
        });
      }

      return;
    }

    try {
      final snapshot =
          await widget.dbRef!
              .child(
                "firmware_update",
              )
              .get();

      if (
        snapshot.exists &&
        snapshot.value != null
      ) {
        final raw =
            snapshot.value;

        if (raw is Map) {
          final data =
              Map<String, dynamic>.from(
            raw,
          );

          latestVersion =
              data['version']
                      ?.toString() ??
                  widget.currentVersion;

          fwUrl =
              data['url']
                      ?.toString() ??
                  '';
        } else {
          latestVersion =
              widget.currentVersion;
        }
      } else {
        latestVersion =
            widget.currentVersion;
      }
    } catch (e) {
      latestVersion =
          widget.currentVersion;
    }

    if (mounted) {
      setState(() {
        isChecking = false;

        hasUpdate =
            widget.currentVersion !=
                'V?' &&
            _versionValue(
                  latestVersion,
                ) >
                _versionValue(
                  widget.currentVersion,
                ) &&
            latestVersion
                .isNotEmpty &&
            fwUrl.isNotEmpty;
      });
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return AlertDialog(
      backgroundColor:
          const Color(0xFF1E202B),
      shape:
          RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(
          20,
        ),
      ),
      title: const Text(
        "Firmware Settings",
        style: TextStyle(
          color: Colors.white,
          fontWeight:
              FontWeight.bold,
        ),
      ),
      content: isChecking
          ? const SizedBox(
              height: 100,
              child:
                  Center(
                child:
                    CircularProgressIndicator(
                  color:
                      Colors.blueAccent,
                ),
              ),
            )
          : Column(
              mainAxisSize:
                  MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  "Current Firmware: ${widget.currentVersion}",
                  style:
                      const TextStyle(
                    color:
                        Colors.white70,
                  ),
                ),
                const SizedBox(
                  height: 8,
                ),
                Text(
                  "Latest Firmware: $latestVersion",
                  style:
                      const TextStyle(
                    color:
                        Colors.white70,
                  ),
                ),
                const SizedBox(
                  height: 20,
                ),
                if (!hasUpdate)
                  Center(
                    child: Text(
                      widget.currentVersion ==
                              "V?"
                          ? "Synchronizing Device Version..."
                          : "System is Up to Date",
                      style: TextStyle(
                        color: widget
                                    .currentVersion ==
                                "V?"
                            ? Colors.orangeAccent
                            : Colors
                                .greenAccent,
                        fontWeight:
                            FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  )
                else
                  ...[
                    const Text(
                      "New Firmware Available!",
                      style:
                          TextStyle(
                        color:
                            Colors.orangeAccent,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    const SizedBox(
                      height: 15,
                    ),
                    TextField(
                      controller:
                          ssidCtrl,
                      style:
                          const TextStyle(
                        color:
                            Colors.white,
                      ),
                      decoration:
                          const InputDecoration(
                        labelText:
                            "WiFi SSID",
                        labelStyle:
                            TextStyle(
                          color:
                              Colors.grey,
                        ),
                        prefixIcon:
                            Icon(
                          Icons.wifi,
                          color:
                              Colors.blueAccent,
                        ),
                        enabledBorder:
                            UnderlineInputBorder(
                          borderSide:
                              BorderSide(
                            color:
                                Colors.grey,
                          ),
                        ),
                      ),
                    ),
                    TextField(
                      controller:
                          passCtrl,
                      style:
                          const TextStyle(
                        color:
                            Colors.white,
                      ),
                      obscureText:
                          true,
                      decoration:
                          const InputDecoration(
                        labelText:
                            "Password",
                        labelStyle:
                            TextStyle(
                          color:
                              Colors.grey,
                        ),
                        prefixIcon:
                            Icon(
                          Icons.lock,
                          color:
                              Colors.blueAccent,
                        ),
                        enabledBorder:
                            UnderlineInputBorder(
                          borderSide:
                              BorderSide(
                            color:
                                Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  ],
              ],
            ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(
              context,
            );
          },
          child: const Text(
            "Close",
            style: TextStyle(
              color:
                  Colors.grey,
            ),
          ),
        ),
        if (
          hasUpdate &&
          !isChecking
        )
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(
              backgroundColor:
                  Colors.blueAccent,
            ),
            onPressed: () async {
              final prefs =
                  await SharedPreferences
                      .getInstance();

              await prefs.setString(
                'saved_ssid',
                ssidCtrl.text
                    .trim(),
              );

              await prefs.setString(
                'saved_pass',
                passCtrl.text,
              );

              if (!context
                  .mounted) {
                return;
              }

              widget
                  .onUpdateTriggered(
                ssidCtrl.text,
                passCtrl.text,
                fwUrl,
              );

              Navigator.pop(
                context,
              );
            },
            child: const Text(
              "Update Firmware",
              style: TextStyle(
                color:
                    Colors.white,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
      ],
    );
  }
}
