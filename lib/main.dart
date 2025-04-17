import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:flutter_blue_plus_windows/flutter_blue_plus_windows.dart';
import 'package:pak_connect/security/SecureMessaging.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble/ble_service_utility.dart';
import 'log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await requestBluetoothPermissions();
  setupBleServiceCommunication();
  await BleServiceUtility.initialize();
  await BleServiceUtility.getDeviceId();
  await LogService.init();
  runApp(const PakConnectApp());
}

Future<void> requestBluetoothPermissions() async {
  Map<Permission, PermissionStatus> statuses = await[
    Permission.bluetooth,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
  ].request();

  if (statuses[Permission.bluetooth]!.isGranted &&
      statuses[Permission.bluetoothScan]!.isGranted &&
      statuses[Permission.bluetoothConnect]!.isGranted &&
      statuses[Permission.location]!.isGranted) {
    print('All required permissions granted');
  } else {
    print('Required permissions denied');
  }
}

void setupBleServiceCommunication() {
  final receivePort = ReceivePort();

  // Optional cleanup if re-registering
  IsolateNameServer.removePortNameMapping('ble_service_port');

  IsolateNameServer.registerPortWithName(
    receivePort.sendPort,
    'ble_service_port',
  );

  receivePort.listen((message) {
    if (message is Map && message['action'] == 'scanResults') {
      final List devices = message['devices'];
      debugPrint("Received devices: $devices");
      // Update UI or store results
    }
  });
}


class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: BleDevicesScreen(),
    );
  }
}


/// GLOBAL SETTINGS (in-memory)
class GlobalSettings {
  // Theme: "blue" = our custom blue/red/white theme; "dark" = dark theme.
  static String themeMode = "blue";
  static bool onlineVisible = true; // online visibility toggle
  static bool notificationsOn = true; // master toggle for notifications
}

/// Data Models
// Contact: username is fixed once set; displayName is editable.
class Contact {
  final String username; // unique and fixed
  String displayName;
  bool isBlocked;
  bool isEmergency;
  String? profileImage;
  String notificationSound;
  String? bleDeviceId;

  Contact({
    required this.username,
    required this.displayName,
    this.isBlocked = false,
    this.isEmergency = false,
    this.profileImage,
    this.notificationSound = "Default",
    this.bleDeviceId,
  });
}

// Message model.
class Message {
  final String content;
  final DateTime timestamp;
  final bool isSent; // true if sent by "self"

  Message({
    required this.content,
    required this.timestamp,
    required this.isSent,
  });
}

// Chat model with optional lock password.
class Chat {
  final Contact contact;
  final List<Message> messages;
  String? lockPassword; // if set, chat is "locked"

  Chat({
    required this.contact,
    required this.messages,
    this.lockPassword,
  });
}

/// In-Memory Data Store
class InMemoryStore {
  // Self profile (username is fixed once set)
  static String? myUsername;
  static String myDisplayName = "Me";
  static String? myProfileImage;

  // Preloaded emergency contacts.
  static final List<Contact> contacts = [
    Contact(username: 'police', displayName: 'Police', isEmergency: true),
    Contact(username: '911', displayName: 'Ambulance', isEmergency: true),
    Contact(username: 'hospital', displayName: 'Hospital', isEmergency: true),
    // Preloaded normal contacts.
    Contact(username: 'tmr5212', displayName: 'Taimoor'),
    Contact(username: 'zn1987', displayName: 'Zain'),
    Contact(username: 'abbk344', displayName: 'AbuBakar'),
    Contact(username: 'sq9876', displayName: 'Sir Qamar'),
  ];

  // All chats
  static final List<Chat> chats = [];

  // Get or create chat with a contact.
  static Chat getOrCreateChat(Contact contact) {
    try {
      return chats.firstWhere((chat) => chat.contact.username == contact.username);
    } catch (e) {
      final newChat = Chat(contact: contact, messages: []);
      chats.add(newChat);
      return newChat;
    }
  }

  // Add a new contact if username not already exists.
  static bool addContact(String username, String displayName) {
    final exists = contacts.any((c) => c.username.toLowerCase() == username.toLowerCase());
    if (exists) return false;
    contacts.add(Contact(username: username, displayName: displayName));
    return true;
  }

  static bool associateDeviceWithContact(String deviceId, String username) {
    final contact = contacts.firstWhere(
          (c) => c.username == username,
      orElse: () => throw Exception('Contact not found'),
    );
    contact.bleDeviceId = deviceId;
    return true;
  }
}

/// Main App Widget with dynamic theming.
class PakConnectApp extends StatefulWidget {
  const PakConnectApp({super.key});

  @override
  State<PakConnectApp> createState() => _PakConnectAppState();
}

class _PakConnectAppState extends State<PakConnectApp> {
  ThemeData _currentTheme = _buildBlueTheme();

  static ThemeData _buildBlueTheme() {
    return ThemeData(
      brightness: Brightness.light,
      primaryColor: Colors.blue,
      scaffoldBackgroundColor: Colors.white,
      colorScheme: ColorScheme.fromSwatch(
        primarySwatch: Colors.red,
        backgroundColor: Colors.white,
      ).copyWith(secondary: Colors.blue),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
    );
  }

  static ThemeData _buildDarkTheme() {
    return ThemeData.dark().copyWith(
      primaryColor: Colors.blueGrey,
      appBarTheme: const AppBarTheme(backgroundColor: Colors.blueGrey),
    );
  }

  void _updateTheme(String mode) {
    setState(() {
      GlobalSettings.themeMode = mode;
      if (mode == "blue") {
        _currentTheme = _buildBlueTheme();
      } else {
        _currentTheme = _buildDarkTheme();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PakConnect',
      theme: _currentTheme,
      home: const HomeScreen(),
      routes: {
        '/generalSettings': (context) => GeneralSettingsScreen(onThemeChanged: _updateTheme),
      },
    );
  }

  @override
  void dispose() {
    // Clean up BLE Service Utility when app is closed
    BleServiceUtility.dispose();
    super.dispose();
  }
}

/// HomeScreen with Bottom Navigation for Chats, Contacts, and Settings.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final List<Widget> _screens = const [
    ChatsScreen(),
    ContactsScreen(),
    SettingsScreen(),
    BleDevicesScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            // Placeholder "logo". Replace with Image.asset('assets/logo.png') if you add assets.
            const Icon(Icons.message_rounded, color: Colors.white),
            const SizedBox(width: 8),
            const Text(
              'PakConnect',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: Colors.red,
        unselectedItemColor: Colors.blueGrey,
        onTap: (idx) => setState(() => _currentIndex = idx),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chats'),
          BottomNavigationBarItem(icon: Icon(Icons.contacts), label: 'Contacts'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
          BottomNavigationBarItem(icon: Icon(Icons.bluetooth), label: 'BLE'),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// BLE DEVICES SCREEN
// -----------------------------------------------------------------------------

class BleManager {
  static final BleManager _instance = BleManager._internal();
  factory BleManager() => _instance;

  final Map<String, BluetoothDevice> _connectedDevices = {};

  BleManager._internal();

  void addConnectedDevice(BluetoothDevice device) {
    _connectedDevices[device.remoteId.toString()] = device;
  }

  BluetoothDevice? getDevice(String deviceId) {
    return _connectedDevices[deviceId];
  }

  void removeDevice(String deviceId) {
    _connectedDevices.remove(deviceId);
  }

}

class BleDevicesScreen extends StatefulWidget {
  const BleDevicesScreen({super.key});

  @override
  State<BleDevicesScreen> createState() => _BleDevicesScreenState();
}

class _BleDevicesScreenState extends State<BleDevicesScreen> {
  final List<Map<String, dynamic>> _bleDevices = [];
  bool _isScanning = false;
  StreamSubscription<Map<String, dynamic>>? _bluetoothStateSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _scanResultsSubscription;
  StreamSubscription<bool>? _serviceStatusSubscription;

  @override
  void initState() {
    super.initState();
    _initializeBleService();
  }

  Future<void> _initializeBleService() async {
    // Initialize BLE service utility
    await BleServiceUtility.initialize();

    // Check Bluetooth state
    _checkBluetoothState();

    // Set up subscriptions
    _bluetoothStateSubscription = BleServiceUtility.bluetoothState.listen((state) {
      if (mounted) {
        final isOn = state['isOn'] ?? false;
        if (!isOn) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth is turned off')),
          );
          setState(() {
            _isScanning = false;
            _bleDevices.clear();
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bluetooth is turned on')),
          );
        }
      }
    });

    _scanResultsSubscription = BleServiceUtility.scanResults.listen((devices) {
      if (mounted) {
        setState(() {
          _bleDevices.clear();
          _bleDevices.addAll(devices);
        });
      }
    });

    _serviceStatusSubscription = BleServiceUtility.serviceStatus.listen((isRunning) {
      if (mounted) {
        setState(() {
          _isScanning = isRunning && _isScanning;
        });
      }
    });
  }

  // Check if Bluetooth is available and turned on
  Future<void> _checkBluetoothState() async {
    try {
      // Get permissions first
      bool hasPermissions = await _checkPermissions();
      if (!hasPermissions) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Missing required permissions')),
          );
        }
        return;
      }

      // Service will handle Bluetooth state checking
      // We'll receive updates via the bluetoothState stream
    } catch (e) {
      print('Error checking Bluetooth state: $e');
    }
  }

  // Start BLE scanning
  void _startScanning() async {
    try {
      setState(() {
        _isScanning = true;
        _bleDevices.clear();
      });

      // Check permissions again before scanning
      bool hasPermissions = await _checkPermissions();
      if (!hasPermissions) {
        setState(() {
          _isScanning = false;
        });
        return;
      }

      // Start scanning with the utility
      await BleServiceUtility.startScanning(
        withServices: [SecureMessaging.MESSAGING_SERVICE_UUID],
        timeoutSeconds: 10,
      );
    } catch (e) {
      print('Error scanning for BLE devices: $e');
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  // Stop BLE scanning
  void _stopScanning() async {
    try {
      await BleServiceUtility.stopScanning();
      setState(() {
        _isScanning = false;
      });
    } catch (e) {
      print('Error stopping scan: $e');
    }
  }

  // Check required permissions
  Future<bool> _checkPermissions() async {
    if (Platform.isAndroid) {
      bool locationEnabled = await Geolocator.isLocationServiceEnabled();
      if (!locationEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please enable location services in device settings.'),
            ),
          );
        }
        return false;
      }

      var scanStatus = await Permission.bluetoothScan.status;
      var connectStatus = await Permission.bluetoothConnect.status;
      var locationStatus = await Permission.locationWhenInUse.status;

      final neededPermissions = [
        if (!scanStatus.isGranted) Permission.bluetoothScan,
        if (!connectStatus.isGranted) Permission.bluetoothConnect,
        if (!locationStatus.isGranted) Permission.locationWhenInUse,
      ];

      if (neededPermissions.isEmpty) return true;

      final statuses = await neededPermissions.request();
      final allGranted = statuses.values.every((status) => status.isGranted);

      if (!allGranted && mounted) {
        final permanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
        if (permanentlyDenied) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Permissions permanently denied. Please enable them in settings.'),
              action: SnackBarAction(
                label: 'Settings',
                onPressed: openAppSettings,
              ),
            ),
          );
        }
      }

      return allGranted;
    } else if (Platform.isIOS) {
      var scanStatus = await Permission.bluetoothScan.status;
      var connectStatus = await Permission.bluetoothConnect.status;

      final neededPermissions = [
        if (!scanStatus.isGranted) Permission.bluetoothScan,
        if (!connectStatus.isGranted) Permission.bluetoothConnect,
      ];

      if (neededPermissions.isEmpty) return true;

      final statuses = await neededPermissions.request();
      return statuses.values.every((s) => s.isGranted);
    }

    return false;
  }

  // Connect to device
  void _connectToDevice(String deviceId) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const AlertDialog(
          title: Text('Connecting'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to device...'),
            ],
          ),
        );
      },
    );

    StreamSubscription? connectResultSubscription;

    try {
      connectResultSubscription = BleServiceUtility.connectResults.listen((result) {
        if (result['deviceId'] == deviceId) {
          connectResultSubscription?.cancel();
          if (result['success'] == true) {
            Navigator.pop(context); // Close connecting dialog
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => BleDeviceDetailScreen(deviceId: deviceId),
              ),
            );
          } else {
            Navigator.pop(context); // Close connecting dialog
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to connect: ${result['error'] ?? 'Unknown error'}')),
            );
          }
        }
      });

      await BleServiceUtility.connectToDevice(deviceId, timeout: 15, maxRetries: 3);
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    }
  }

  // Convert RSSI to signal strength
  Widget _buildSignalStrength(int rssi) {
    Color color;

    if (rssi >= -60) {
      color = Colors.green;
    } else if (rssi >= -70) {
      color = Colors.lightGreen;
    } else if (rssi >= -80) {
      color = Colors.orange;
    } else {
      color = Colors.red;
    }

    return Icon(Icons.signal_wifi_4_bar, color: color);
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Devices'),
        actions: [
          if (_isScanning)
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _stopScanning,
              tooltip: 'Stop scanning',
            ),
          if (!_isScanning)
            IconButton(
                icon: Icon(Icons.refresh),
                onPressed: _startScanning
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Found ${_bleDevices.length} devices',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: _bleDevices.isEmpty
                ? Center(
              child: _isScanning
                  ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Scanning for devices...'),
                ],
              )
                  : const Text('No devices found. Start scanning to discover BLE devices.'),
            )
                : ListView.builder(
              itemCount: _bleDevices.length,
              itemBuilder: (context, index) {
                final device = _bleDevices[index];
                final deviceName = device['name'] ?? 'Unknown Device';
                final deviceId = device['id'] ?? '';
                final rssi = device['rssi'] ?? -100;

                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: const Icon(Icons.bluetooth, color: Colors.white),
                  ),
                  title: Text(
                    deviceName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('ID: $deviceId'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$rssi dBm'),
                      const SizedBox(width: 8),
                      _buildSignalStrength(rssi),
                    ],
                  ),
                  onTap: () => _connectToDevice(deviceId),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isScanning ? null : _startScanning,
        backgroundColor: _isScanning ? Colors.grey : Colors.red,
        child: _isScanning
            ? const CircularProgressIndicator(color: Colors.white)
            : const Icon(Icons.search),
      ),
    );
  }

  @override
  void dispose() {
    _scanResultsSubscription?.cancel();
    _bluetoothStateSubscription?.cancel();
    _serviceStatusSubscription?.cancel();
    _stopScanning();
    super.dispose();
  }
}

// -----------------------------------------------------------------------------
// BLE DEVICE DETAIL SCREEN
// -----------------------------------------------------------------------------

class BleDeviceDetailScreen extends StatefulWidget {
  final String deviceId;

  const BleDeviceDetailScreen({super.key, required this.deviceId});

  @override
  State<BleDeviceDetailScreen> createState() => _BleDeviceDetailScreenState();
}

class _BleDeviceDetailScreenState extends State<BleDeviceDetailScreen> {
  bool _isConnected = false;
  Map<String, dynamic> _deviceInfo = {};
  List<Map<String, dynamic>> _services = [];
  bool _isLoading = true;
  StreamSubscription<Map<String, dynamic>>? _connectionSubscription;
  StreamSubscription<Map<String, dynamic>>? _readResultSubscription;
  StreamSubscription<Map<String, dynamic>>? _writeResultSubscription;

  @override
  void initState() {
    super.initState();
    _isLoading = true;
    _setupListeners();
    _fetchDeviceInfo();
  }

  void _setupListeners() {
    // Listen to connection state changes
    _connectionSubscription = BleServiceUtility.connectionState.listen((state) {
      if (state['deviceId'] == widget.deviceId) {
        setState(() {
          _isConnected = state['connected'] ?? false;
          _isLoading = false;
        });

        // Fetch services when connected
        if (_isConnected) {
          _fetchServices();
        }
      }
    });

    // Listen to read results
    _readResultSubscription = BleServiceUtility.readResults.listen((result) {
      if (result['deviceId'] == widget.deviceId) {
        final success = result['success'] ?? false;
        final data = result['data'];

        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Read value: $data')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error reading: ${result['error'] ?? 'Unknown error'}')),
          );
        }
      }
    });

    // Listen to write results
    _writeResultSubscription = BleServiceUtility.writeResults.listen((result) {
      if (result['deviceId'] == widget.deviceId) {
        final success = result['success'] ?? false;

        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Write successful')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Write failed: ${result['error'] ?? 'Unknown error'}')),
          );
        }
      }
    });
  }

  Future<void> _fetchDeviceInfo() async {
    // This would come from the service in a real implementation
    // For now we'll just populate with the device ID
    setState(() {
      _deviceInfo = {
        'id': widget.deviceId,
        'name': 'Device ${widget.deviceId.substring(0, 8)}',
      };
      _isLoading = false;
    });
  }

  Future<void> _fetchServices() async {
    // In a real implementation, you would get this from the service
    // This is just a placeholder
    setState(() {
      _services = [
        {
          'uuid': SecureMessaging.MESSAGING_SERVICE_UUID,
          'characteristics': [
            {
              'uuid': SecureMessaging.MESSAGING_CHARACTERISTIC_UUID,
              'properties': {
                'read': true,
                'write': true,
                'notify': true,
              }
            }
          ]
        }
      ];
    });
  }

  // Disconnect from device
  Future<void> _disconnectFromDevice() async {
    try {
      await BleServiceUtility.disconnectDevice(widget.deviceId);

      // Navigate back after disconnection
      // The disconnect result will be handled by the listener
      Navigator.pop(context);
    } catch (e) {
      print('Error disconnecting: $e');
    }
  }

  Future<void> _readCharacteristic(String serviceUuid, String characteristicUuid) async {
    try {
      await BleServiceUtility.readCharacteristic(
        remoteId: widget.deviceId,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
      // Result will be handled by the listener
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error reading: $e')),
      );
    }
  }

  Future<void> _writeCharacteristic(String serviceUuid, String characteristicUuid) async {
    TextEditingController textController = TextEditingController();

    // Show dialog to get text to write
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Write to Characteristic'),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            hintText: 'Enter text to write',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              String text = textController.text;

              try {
                await BleServiceUtility.writeCharacteristic(
                  remoteId: widget.deviceId,
                  serviceUuid: serviceUuid,
                  characteristicUuid: characteristicUuid,
                  data: text,
                );
                // Result will be handled by the listener
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Write failed: $e')),
                );
              }
            },
            child: const Text('Write'),
          ),
        ],
      ),
    );
  }

  void _associateDeviceWithContact() {
    showDialog(
      context: context,
      builder: (context) {
        final usernameController = TextEditingController();
        return AlertDialog(
          title: const Text('Associate Device with Contact'),
          content: TextField(
            controller: usernameController,
            decoration: const InputDecoration(labelText: 'Contact Username'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final username = usernameController.text.trim();
                if (username.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Username cannot be empty')),
                  );
                  return;
                }
                try {
                  // Using your existing in-memory store
                  InMemoryStore.associateDeviceWithContact(widget.deviceId, username);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Device associated successfully')),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e')),
                  );
                }
              },
              child: const Text('Associate'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildServicesList() {
    return ListView.builder(
      itemCount: _services.length,
      itemBuilder: (context, index) {
        final service = _services[index];
        final serviceUuid = service['uuid'] as String;
        final characteristics = List<Map<String, dynamic>>.from(service['characteristics'] as List);

        return ExpansionTile(
          title: Text(
            'Service: $serviceUuid',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          children: [
            ...characteristics.map(
                  (characteristic) {
                final characteristicUuid = characteristic['uuid'] as String;
                final properties = characteristic['properties'] as Map<String, dynamic>;

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Characteristic: $characteristicUuid',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text('Properties:'),
                        Wrap(
                          spacing: 4,
                          children: [
                            if (properties['read'] == true)
                              Chip(label: const Text('Read')),
                            if (properties['write'] == true)
                              Chip(label: const Text('Write')),
                            if (properties['notify'] == true)
                              Chip(label: const Text('Notify')),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            if (properties['read'] == true)
                              ElevatedButton(
                                onPressed: () => _readCharacteristic(serviceUuid, characteristicUuid),
                                child: const Text('Read'),
                              ),
                            if (properties['write'] == true)
                              ElevatedButton(
                                onPressed: () => _writeCharacteristic(serviceUuid, characteristicUuid),
                                child: const Text('Write'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ).toList(),
          ],
        );
      },
    );
  }

  void _sendTestMessage() async {
    try {
      // Send a test message using your secure messaging implementation
      await BleServiceUtility.writeCharacteristic(
        remoteId: widget.deviceId,
        serviceUuid: SecureMessaging.MESSAGING_SERVICE_UUID,
        characteristicUuid: SecureMessaging.MESSAGING_CHARACTERISTIC_UUID,
        data: "Hello from App!",
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test message sent')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send test message: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_deviceInfo['name'] ?? 'Device Details'),
        actions: [
          if (_isConnected)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              onPressed: _disconnectFromDevice,
              tooltip: 'Disconnect',
            ),
          if (_isConnected)
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: _associateDeviceWithContact,
              tooltip: 'Associate with Contact',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading device details...'),
          ],
        ),
      )
          : Column(
        children: [
          // Device info
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.blue[50],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: _isConnected ? Colors.green : Colors.red,
                      radius: 8,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isConnected ? 'Connected' : 'Disconnected',
                      style: TextStyle(
                        color: _isConnected ? Colors.green : Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('Device ID: ${_deviceInfo['id'] ?? 'Unknown'}'),
                const SizedBox(height: 4),
                Text('Device Name: ${_deviceInfo['name'] ?? 'Unknown'}'),
              ],
            ),
          ),

          // Services heading
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'Services',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),

          // Services list
          Expanded(
            child: _services.isEmpty
                ? const Center(child: Text('No services discovered'))
                : _buildServicesList(),
          ),
        ],
      ),
      floatingActionButton: _isConnected
          ? FloatingActionButton.extended(
        onPressed: _sendTestMessage,
        icon: const Icon(Icons.send),
        label: const Text('Test Communication'),
        backgroundColor: Colors.red,
      )
          : null,
    );
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _readResultSubscription?.cancel();
    _writeResultSubscription?.cancel();
    super.dispose();
  }
}

// -----------------------------------------------------------------------------
// CHATS SCREEN
// -----------------------------------------------------------------------------

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  @override
  Widget build(BuildContext context) {
    final allChats = InMemoryStore.chats;
    if (allChats.isEmpty) {
      return const Center(
        child: Text(
          'No chats yet. Add a contact and start chatting!',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: allChats.length,
      itemBuilder: (context, index) {
        final chat = allChats[index];
        final lastMsg = chat.messages.isNotEmpty ? chat.messages.last.content : 'No messages';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: chat.contact.isEmergency ? Colors.red : Colors.blueAccent,
            child: Text(chat.contact.displayName[0].toUpperCase()),
          ),
          title: Text(chat.contact.displayName),
          subtitle: Text(lastMsg),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ChatScreenDetail(chat: chat)),
            ).then((_) => setState(() {}));
          },
        );
      },
    );
  }
}

/// Chat Detail Screen
class ChatScreenDetail extends StatefulWidget {
  final Chat chat;
  const ChatScreenDetail({super.key, required this.chat});

  @override
  State<ChatScreenDetail> createState() => _ChatScreenDetailState();
}

class _ChatScreenDetailState extends State<ChatScreenDetail> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _canSend = false;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _messagingChar;
  StreamSubscription<List<int>>? _notificationSubscription;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final canSendNow = _controller.text.trim().isNotEmpty;
      if (canSendNow != _canSend) {
        setState(() {
          _canSend = canSendNow;
        });
      }
    });
    _setupBleMessaging();
  }

  Future<void> _setupBleMessaging() async {
    if (widget.chat.contact.bleDeviceId == null) return;

    try {
      // Find the device (you'll need a way to access connected devices)
      // For simplicity, assume we have a method to get the device
      _device = await _getDeviceById(widget.chat.contact.bleDeviceId!);
      if (_device == null) return;

      final services = await _device!.discoverServices();
      final messagingService = services.firstWhere(
            (s) => s.uuid.toString() == SecureMessaging.MESSAGING_SERVICE_UUID,
        orElse: () => throw Exception('Messaging service not found'),
      );
      _messagingChar = messagingService.characteristics.firstWhere(
            (c) => c.uuid.toString() == SecureMessaging.MESSAGING_CHARACTERISTIC_UUID,
        orElse: () => throw Exception('Messaging characteristic not found'),
      );

      // Enable notifications
      if (_messagingChar!.properties.notify) {
        await _messagingChar!.setNotifyValue(true);
        _notificationSubscription = _messagingChar!.lastValueStream.listen((data) {
          _receiveMessage(data);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error setting up BLE messaging: ${e.toString()}')),
        );
      }
    }
  }

  Future<BluetoothDevice?> _getDeviceById(String deviceId) async {
    // Could use FlutterBluePlus.instance.connectedDevices
    return BleManager().getDevice(deviceId);
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final message = Message(
      content: text,
      timestamp: DateTime.now(),
      isSent: true,
    );

    setState(() {
      widget.chat.messages.add(message);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
      _controller.clear();
    });
    await _ensureConnected();
    if (_device != null && _messagingChar != null && widget.chat.contact.bleDeviceId != null) {
      try {
        final secureMessaging = SecureMessaging();
        await secureMessaging.sendSecureMessage(
          _device!,
          _messagingChar!,
          text,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send secure message: ${e.toString()}')),
          );
        }
      }
    }
  }

  Future<void> _receiveMessage(List<int> data) async {
    if (widget.chat.contact.bleDeviceId == null) return;
    if (_device == null) {
      await _ensureConnected();
    }
    try {
      final secureMessaging = SecureMessaging();
      final decrypted = await secureMessaging.decryptMessage(
        Uint8List.fromList(data),
        widget.chat.contact.bleDeviceId!,
      );
      final message = Message(
        content: decrypted,
        timestamp: DateTime.now(),
        isSent: false,
      );
      if (mounted) {
        setState(() {
          widget.chat.messages.add(message);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          });
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to decrypt message: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _ensureConnected() async {
    final deviceId = widget.chat.contact.bleDeviceId;
    if (deviceId == null) return;

    if (_device == null || await _device!.connectionState.first != BluetoothConnectionState.connected) {
      await _reconnectToDevice();
    }
  }

  Future<void> _reconnectToDevice() async {
    if (_device != null) {
      final isConnected = await _device!.connectionState.first == BluetoothConnectionState.connected;
      if (isConnected) return;
    }

    final deviceId = widget.chat.contact.bleDeviceId;
    if (deviceId == null) return;

    const int maxAttempts = 5;
    const Duration retryDelay = Duration(seconds: 2);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        _device = BluetoothDevice.fromId(deviceId);

        await _device!.connect(timeout: const Duration(seconds: 5));
        final services = await _device!.discoverServices();

        final messagingService = services.firstWhere(
              (s) => s.uuid.toString() == SecureMessaging.MESSAGING_SERVICE_UUID,
          orElse: () => throw Exception('Messaging service not found'),
        );

        _messagingChar = messagingService.characteristics.firstWhere(
              (c) => c.uuid.toString() == SecureMessaging.MESSAGING_CHARACTERISTIC_UUID,
          orElse: () => throw Exception('Messaging characteristic not found'),
        );

        return; // success
      } catch (e) {
        if (attempt == maxAttempts) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to reconnect: ${e.toString()}')),
            );
          }
        } else {
          await Future.delayed(retryDelay);
        }
      }
    }
  }


  @override
  void dispose() {
    _controller.dispose();
    _notificationSubscription?.cancel();
    super.dispose();
  }

  void _showChatOptions() {
    showModalBottomSheet(
      context: context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('View Profile'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileViewScreen(contact: widget.chat.contact),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('Lock Chat'),
            onTap: () {
              Navigator.pop(context);
              _promptSetLock();
            },
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Block Contact'),
            onTap: () {
              setState(() {
                widget.chat.contact.isBlocked = true;
              });
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  void _promptSetLock() {
    final pwdController = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Set Lock Password'),
        content: TextField(
          controller: pwdController,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Enter password'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                widget.chat.lockPassword = pwdController.text.trim();
              });
              Navigator.pop(context);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
              decoration: const InputDecoration(
                hintText: 'Type a message...',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: _canSend ? _sendMessage : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.chat.messages;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chat.contact.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: _showChatOptions,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(child: Text('No messages yet.'))
                : ListView.builder(
              controller: _scrollController,
              itemCount: widget.chat.messages.length,
              itemBuilder: (context, index) {
                final message = widget.chat.messages[index];
                return MessageBubble(message: message);
              },
            )
          ),
          _buildInputBar(),
        ],
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final Message message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final bubbleColor = message.isSent ? Colors.blue[200] : Colors.grey[300];
    final align = message.isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    return Column(
      crossAxisAlignment: align,
      children: [
        GestureDetector(
          onTap: () => _showTimestamp(context),
          onLongPress: () => _showTimestamp(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(message.content),
          ),
        ),
      ],
    );
  }

  void _showTimestamp(BuildContext context) {
    final time = DateFormat.jm().format(message.timestamp);
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 80,
        left: 20,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                time,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);
    Future.delayed(const Duration(seconds: 2), () {
      overlayEntry.remove();
    });
  }
}


// -----------------------------------------------------------------------------
// CONTACTS SCREEN
// -----------------------------------------------------------------------------

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  @override
  Widget build(BuildContext context) {
    // Separate emergency from normal contacts.
    final emergencyContacts =
    InMemoryStore.contacts.where((c) => c.isEmergency).toList();
    final normalContacts =
    InMemoryStore.contacts.where((c) => !c.isEmergency).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(12.0),
            child: Text(
              'Emergency Contacts',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          if (emergencyContacts.isEmpty)
            const ListTile(title: Text('No emergency contacts found.'))
          else
            ...emergencyContacts.map((contact) => ListTile(
              leading: const Icon(Icons.warning, color: Colors.red),
              title: Text(contact.displayName),
              subtitle: Text('Username: ${contact.username}'),
              onTap: () => _openChat(contact),
            )),
          const Divider(thickness: 1, height: 20),
          const Padding(
            padding: EdgeInsets.all(12.0),
            child: Text(
              'My Contacts',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          if (normalContacts.isEmpty)
            const ListTile(title: Text('No contacts yet.'))
          else
            ...normalContacts.map((contact) => ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(contact.displayName),
              subtitle: Text('Username: ${contact.username}'),
              onTap: () => _openChat(contact),
            )),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.red,
        child: const Icon(Icons.person_add),
        onPressed: _showAddContactDialog,
      ),
    );
  }

  void _openChat(Contact c) {
    final chat = InMemoryStore.getOrCreateChat(c);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreenDetail(chat: chat)),
    );
  }

  void _showAddContactDialog() {
    final userCtrl = TextEditingController();
    final nameCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add New Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: userCtrl,
              decoration: const InputDecoration(labelText: 'Username (unique)'),
            ),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Display Name'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final username = userCtrl.text.trim();
              final displayName = nameCtrl.text.trim();
              if (username.isEmpty || displayName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Fields cannot be empty')),
                );
                return;
              }
              final success = InMemoryStore.addContact(username, displayName);
              Navigator.pop(context);
              if (!success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Username already exists!')),
                );
              } else {
                setState(() {});
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SETTINGS SCREEN
// -----------------------------------------------------------------------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // For editing self profile.
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _usernameController.text = InMemoryStore.myUsername ?? '';
    _displayNameController.text = InMemoryStore.myDisplayName;
  }

  void _saveProfile() {
    final newUsername = _usernameController.text.trim();
    final newDisplayName = _displayNameController.text.trim();
    if (InMemoryStore.myUsername == null || InMemoryStore.myUsername!.isEmpty) {
      if (newUsername.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Username cannot be empty')),
        );
        return;
      }
      InMemoryStore.myUsername = newUsername;
    } else if (newUsername != InMemoryStore.myUsername) {
      _usernameController.text = InMemoryStore.myUsername!;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username is fixed and cannot be changed')),
      );
    }
    InMemoryStore.myDisplayName = newDisplayName.isEmpty ? 'Me' : newDisplayName;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Profile Saved')),
    );
  }

  Widget _buildProfileCard() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Card(
        color: Colors.blue[50],
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            children: [
              // Profile image placeholder.
              CircleAvatar(
                radius: 40,
                backgroundColor: Colors.red[100],
                child: const Icon(Icons.person, size: 40),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Username (unique)',
                ),
              ),
              TextField(
                controller: _displayNameController,
                decoration: const InputDecoration(
                  labelText: 'Display Name',
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _saveProfile,
                child: const Text('Save Profile'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsList() {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.palette),
          title: const Text('General'),
          subtitle: const Text('Change theme'),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => GeneralSettingsScreen(onThemeChanged: (mode) {
                // Update theme via a global method.
                Navigator.pop(context);
              })),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.lock_open),
          title: const Text('Privacy'),
          subtitle: const Text('Blocked list and online visibility'),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacySettingsScreen()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.security),
          title: const Text('Security'),
          subtitle: const Text('Lock chats with passwords'),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SecuritySettingsScreen()),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.notifications),
          title: const Text('Notifications'),
          subtitle: const Text('Sound settings and toggle notifications'),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationsSettingsScreen()),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          const SizedBox(height: 16),
          _buildProfileCard(),
          const Divider(thickness: 1),
          _buildSettingsList(),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// GENERAL SETTINGS SCREEN (Change Theme)
class GeneralSettingsScreen extends StatefulWidget {
  final Function(String) onThemeChanged;
  const GeneralSettingsScreen({super.key, required this.onThemeChanged});

  @override
  State<GeneralSettingsScreen> createState() => _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends State<GeneralSettingsScreen> {
  String _selectedTheme = GlobalSettings.themeMode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('General Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text('Select Theme', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 12),
            DropdownButton<String>(
              value: _selectedTheme,
              items: const [
                DropdownMenuItem(value: 'blue', child: Text('Blue/Red/White')),
                DropdownMenuItem(value: 'dark', child: Text('Dark')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedTheme = value;
                  });
                }
              },
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                GlobalSettings.themeMode = _selectedTheme;
                widget.onThemeChanged(_selectedTheme);
                Navigator.pop(context);
              },
              child: const Text('Apply Theme'),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// PRIVACY SETTINGS SCREEN (Blocked List & Online Visibility)
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});
  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  bool _onlineVisible = GlobalSettings.onlineVisible;

  @override
  Widget build(BuildContext context) {
    final blockedContacts = InMemoryStore.contacts.where((c) => c.isBlocked).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Show me online'),
            value: _onlineVisible,
            onChanged: (val) {
              setState(() {
                _onlineVisible = val;
                GlobalSettings.onlineVisible = val;
              });
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(12.0),
            child: Text(
              'Blocked Contacts',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          if (blockedContacts.isEmpty)
            const ListTile(title: Text('No blocked contacts'))
          else
            ...blockedContacts.map((c) => ListTile(
              title: Text(c.displayName),
              subtitle: Text('Username: ${c.username}'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ProfileViewScreen(contact: c)),
              ),
            )),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SECURITY SETTINGS SCREEN (Lock Chats)
class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});
  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  final TextEditingController _pwdController = TextEditingController();

  void _setChatLock(Chat chat) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Set Lock for Chat'),
        content: TextField(
          controller: _pwdController,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Enter password'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                chat.lockPassword = _pwdController.text.trim();
              });
              _pwdController.clear();
              Navigator.pop(context);
            },
            child: const Text('Set Lock'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security Settings')),
      body: ListView.builder(
        itemCount: InMemoryStore.chats.length,
        itemBuilder: (context, index) {
          final chat = InMemoryStore.chats[index];
          return ListTile(
            title: Text(chat.contact.displayName),
            subtitle: Text(chat.lockPassword == null || chat.lockPassword!.isEmpty
                ? 'Not Locked'
                : 'Locked'),
            trailing: ElevatedButton(
              onPressed: () => _setChatLock(chat),
              child: const Text('Set Lock'),
            ),
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// NOTIFICATIONS SETTINGS SCREEN (Global and Per-Contact Settings)
class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});
  @override
  State<NotificationsSettingsScreen> createState() => _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState extends State<NotificationsSettingsScreen> {
  bool _notificationsOn = GlobalSettings.notificationsOn;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Enable Notifications'),
            value: _notificationsOn,
            onChanged: (val) {
              setState(() {
                _notificationsOn = val;
                GlobalSettings.notificationsOn = val;
              });
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(12.0),
            child: Text(
              'Per-Contact Notification Sounds',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          ...InMemoryStore.contacts.map((c) {
            final controller = TextEditingController(text: c.notificationSound);
            return ListTile(
              title: Text(c.displayName),
              subtitle: Text('Username: ${c.username}'),
              trailing: SizedBox(
                width: 120,
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(labelText: 'Sound'),
                  onSubmitted: (val) {
                    setState(() {
                      c.notificationSound = val;
                    });
                  },
                ),
              ),
            );
          }).toList(),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// PROFILE VIEW SCREEN (For Other Contacts)
class ProfileViewScreen extends StatelessWidget {
  final Contact contact;
  const ProfileViewScreen({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(contact.displayName),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Placeholder for contact’s image.
            CircleAvatar(
              radius: 50,
              backgroundColor: Colors.blue[100],
              child: Text(
                contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 40),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Username: ${contact.username}',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Display Name: ${contact.displayName}',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            if (contact.isBlocked)
              const Text(
                'This contact is blocked',
                style: TextStyle(color: Colors.red),
              ),
            const SizedBox(height: 8),
            Text('Notification Sound: ${contact.notificationSound}',
                style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }
}