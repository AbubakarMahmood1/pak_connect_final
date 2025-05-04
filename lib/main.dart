import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble/ble_service.dart';
import 'logging/log_service.dart';

late final FlutterBackgroundService backgroundService;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services in correct order
  await LogService.init();

  // Initialize background service once
  backgroundService = await setupBackgroundService();

  bool hasPermission = await Permission.bluetooth.status.isGranted;
  if (!hasPermission) {
    debugPrint('Requesting Bluetooth permission...');
    await Permission.bluetooth.request();
  }
  debugPrint('Bluetooth permission status: ${await Permission.bluetooth.status}');

  // Initialize BLE service with the background service instance
  final bleService = BleService(backgroundService);
  await bleService.initialize();

  // Request permissions after service initialization
  await requestRequiredPermissions();

  // Handle app foreground/background state in one place
  SystemChannels.lifecycle.setMessageHandler((msg) async {
    debugPrint('Lifecycle state: $msg');
    if (msg == AppLifecycleState.resumed.toString()) {
      await bleService.handleAppForeground();
    } else if (msg == AppLifecycleState.paused.toString()) {
      await bleService.saveBackgroundTimestamp();
    }
    return null;
  });

  runApp(const PakConnectApp());
}

// Single setup function for background service
Future<FlutterBackgroundService> setupBackgroundService() async {
  final service = FlutterBackgroundService();

  // Create notification service first
  final notificationService = NotificationService();
  await notificationService.initialize();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundServiceEntryPoint,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'ble_service_foreground',
      initialNotificationTitle: 'BLE Messaging Service',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: 888,
      autoStartOnBoot: true,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: backgroundServiceEntryPoint,
      onBackground: iosBackgroundHandler,
    ),
  );

  return service;
}

// Single background service entry point
@pragma('vm:entry-point')
void backgroundServiceEntryPoint(ServiceInstance service) async {
  // Update notification to show service is running
  final notificationService = NotificationService();
  await notificationService.initialize();

  await notificationService.updateServiceNotification(
      'BLE Messaging Service',
      'Service starting...'
  );

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  // Initialize BLE service with the service instance
  final bleService = BleService.backgroundInstance(service);
  await bleService.initialize();

  // Setup battery monitoring, wake locks, etc. as needed
  final batteryMonitor = BatteryMonitor();
  await batteryMonitor.initialize();

  // Set up periodic tasks
  Timer.periodic(Duration(minutes: 1), (timer) async {
    final batteryState = await batteryMonitor.getCurrentState();

    // Perform adaptive background tasks based on battery state
    await performBackgroundTasks(service, bleService, batteryState);
  });

  // Handle service commands
  service.on('stopService').listen((event) {
    bleService.dispose();
    service.stopSelf();
  });
}


// iOS background handler
@pragma('vm:entry-point')
Future<bool> iosBackgroundHandler(ServiceInstance service) async {
  // Delegate to BleService for iOS background processing
  final bleService = BleService.backgroundInstance(service);
  return await bleService.handleIosBackground();
}

// Central permission handling
Future<void> requestRequiredPermissions() async {
  // First request location permission which is required for BLE
  await Permission.location.request();

  // For Android 12+ devices, request the new Bluetooth permissions
  if (Platform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 31) { // Android 12+
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.bluetoothAdvertise.request();
      await Permission.scheduleExactAlarm.request();
    } else {
      // For older Android versions, use the legacy Bluetooth permission
      await Permission.bluetooth.request();
      await Permission.bluetoothScan.request();
      await Permission.scheduleExactAlarm.request();
    }

    // For Android 13+, also request notification permission
    if (androidInfo.version.sdkInt >= 33) {
      await Permission.notification.request();
    }
  }
}

// Separated battery monitoring class
class BatteryMonitor {
  final Battery _battery = Battery();
  BatteryState _batteryState = BatteryState.unknown;
  int _batteryLevel = 100;
  bool _isLowPowerMode = false;

  Future<void> initialize() async {
    await _updateBatteryState();

    // Listen for battery changes
    _battery.onBatteryStateChanged.listen((state) {
      _batteryState = state;
      _updateBatteryState();
    });
  }

  Future<void> _updateBatteryState() async {
    try {
      _batteryLevel = await _battery.batteryLevel;

      if (Platform.isAndroid || Platform.isIOS) {
        _isLowPowerMode = await _battery.isInBatterySaveMode;
      }
    } catch (e) {
      debugPrint('Failed to check battery state: $e');
    }
  }

  Future<BatteryStatus> getCurrentState() async {
    await _updateBatteryState();
    return BatteryStatus(
        state: _batteryState,
        level: _batteryLevel,
        isLowPowerMode: _isLowPowerMode
    );
  }
}

class BatteryStatus {
  final BatteryState state;
  final int level;
  final bool isLowPowerMode;

  BatteryStatus({
    required this.state,
    required this.level,
    required this.isLowPowerMode
  });
}

// Perform background tasks based on battery state
Future<void> performBackgroundTasks(
    ServiceInstance service,
    BleService bleService,
    BatteryStatus batteryStatus
    ) async {
  // Determine appropriate scan parameters based on state
  bool shouldScan = false;
  Duration scanDuration;

  // Battery state affects scan behavior
  if (batteryStatus.state == BatteryState.discharging && batteryStatus.level < 15) {
    // Very conservative in critical battery
    scanDuration = const Duration(seconds: 5);
    shouldScan = bleService.hasPendingMessages() &&
        DateTime.now().difference(bleService.lastMessageActivityTime).inMinutes > 15;
  }
  else if ((batteryStatus.state == BatteryState.discharging &&
      batteryStatus.level < 30) ||
      batteryStatus.isLowPowerMode) {
    // Conservative in low battery
    scanDuration = const Duration(seconds: 10);
    shouldScan = bleService.hasPendingMessages() ||
        DateTime.now().difference(bleService.lastMessageActivityTime).inMinutes > 10;
  }
  else {
    // Normal scan behavior
    scanDuration = const Duration(seconds: 30);
    shouldScan = bleService.hasPendingMessages() ||
        DateTime.now().difference(bleService.lastMessageActivityTime) >=
            bleService.getAdaptiveScanInterval();
  }

  // Process pending messages
  await bleService.processOutgoingMessages();

  // Scan if needed
  if (shouldScan && !bleService.isScanning) {
    await bleService.startScan(maxDuration: scanDuration);
  }

  // Update notification with meaningful status
  final pendingCount = bleService.getPendingMessageCount();
  String statusMessage;

  if (batteryStatus.state == BatteryState.charging) {
    statusMessage = "Charging: ${pendingCount > 0 ? '$pendingCount pending messages' : 'No pending messages'}";
  } else if (pendingCount > 0) {
    statusMessage = "Active: $pendingCount pending message${pendingCount == 1 ? '' : 's'}";
  } else if (batteryStatus.state == BatteryState.discharging && batteryStatus.level < 15) {
    statusMessage = "Limited service: Battery critical (${batteryStatus.level}%)";
  } else if ((batteryStatus.state == BatteryState.discharging && batteryStatus.level < 30) ||
      batteryStatus.isLowPowerMode) {
    statusMessage = "Standby: Battery saving mode (${batteryStatus.level}%)";
  } else {
    statusMessage = "Standby: Monitoring for messages (${batteryStatus.level}%)";
  }

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: "BLE Messaging Service",
      content: statusMessage,
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
  final BleService _bleService = BleService();

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
    // Clean up BLE Service when app is closed
    _bleService.dispose();
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

class BleDevicesScreen extends StatefulWidget {
  const BleDevicesScreen({super.key});

  @override
  State<BleDevicesScreen> createState() => _BleDevicesScreenState();
}

class _BleDevicesScreenState extends State<BleDevicesScreen> {
  String _statusMessage = "Ready";
  final BleService _bleService = BleService();
  bool _isScanning = false;
  List<BleDevice> _devices = [];
  StreamSubscription<List<BleDevice>>? _devicesSubscription;
  StreamSubscription<String>? _connectionStateSubscription;

  @override
  void initState() {
    super.initState();
    _setupBleListeners();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    bool allGranted = statuses.values.every((status) => status.isGranted);
    if (!allGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing required permissions')),
      );
    }
  }

  void _setupBleListeners() {
    // Listen for device discoveries
    _devicesSubscription = _bleService.devices.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });

    // Listen for connection state changes
    _connectionStateSubscription = _bleService.connectionState.listen((state) {
      if (mounted) {
        setState(() {
          _isScanning = state == 'Scanning';
        });
      }
    });
  }

  void _startScanning() async {
    setState(() {
      _statusMessage = "Starting scan...";
    });
    try {
      await _bleService.startScan(maxDuration: const Duration(seconds: 30));
      setState(() {
        _statusMessage = "Scan started";
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Scan error: $e";
      });
      debugPrint('Error scanning for BLE devices: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error scanning: $e')),
        );
      }
    }
  }

  void _stopScanning() async {
    setState(() {
      _statusMessage = "Scan stopped.";
    });
    try {
      await _bleService.stopScan();
    } catch (e) {
      setState(() {
        _statusMessage = "Scan stopping error: $e";
      });
      debugPrint('Error stopping scan: $e');
    }
  }

  void _connectToDevice(BleDevice device) async {
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

    try {
      final success = await _bleService.connectToDevice(device);
      if (mounted) {
        Navigator.pop(context); // Close connecting dialog

        if (success) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => BleDeviceDetailScreen(device: device),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to connect to device')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection error: $e')),
        );
      }
    }
  }

  // Convert RSSI to signal strength widget
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
              icon: const Icon(Icons.refresh),
              onPressed: _startScanning,
              tooltip: 'Start scanning',
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Colors.blue.shade50,
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Icon(
                  _isScanning ? Icons.search : Icons.bluetooth,
                  color: Colors.blue,
                ),
                const SizedBox(width: 8),
                Text(
                  'Status: ${_isScanning ? "Scanning..." : _statusMessage}',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Found ${_devices.length} devices',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: _devices.isEmpty
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
              itemCount: _devices.length,
              itemBuilder: (context, index) {
                final device = _devices[index];
                final deviceName = _bleService.getDisplayName(device);
                final deviceId = device.id;
                final rssi = device.rssi;

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
                  onTap: () => _connectToDevice(device),
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
    _devicesSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _stopScanning();
    super.dispose();
  }
}

// -----------------------------------------------------------------------------
// BLE DEVICE DETAIL SCREEN
// -----------------------------------------------------------------------------

class BleDeviceDetailScreen extends StatefulWidget {
  final BleDevice device;

  const BleDeviceDetailScreen({super.key, required this.device});

  @override
  State<BleDeviceDetailScreen> createState() => _BleDeviceDetailScreenState();
}

class _BleDeviceDetailScreenState extends State<BleDeviceDetailScreen> {
  final BleService _bleService = BleService();
  bool _isConnected = false;
  bool _isLoading = true;
  StreamSubscription<List<BleDevice>>? _devicesSubscription;
  final TextEditingController _messageController = TextEditingController();
  StreamSubscription<List<BleMessage>>? _messagesSubscription;
  List<BleMessage> _messages = [];

  @override
  void initState() {
    super.initState();
    _isLoading = true;
    _setupSubscriptions();
    _checkConnectionStatus();
  }

  void _setupSubscriptions() {
    // Listen for device updates to track connection status
    _devicesSubscription = _bleService.devices.listen((devices) {
      final deviceIndex = devices.indexWhere((d) => d.id == widget.device.id);
      if (deviceIndex >= 0) {
        final updatedDevice = devices[deviceIndex];
        if (mounted) {
          setState(() {
            _isConnected = updatedDevice.isConnected;
            _isLoading = false;
          });
        }
      }
    });

    // Listen for messages
    _messagesSubscription = _bleService.messages.listen((messages) {
      final deviceMessages = messages.where((m) =>
      (m.senderId == widget.device.id && m.recipientId == _bleService.deviceId) ||
          (m.senderId == _bleService.deviceId && m.recipientId == widget.device.id)
      ).toList();

      if (mounted) {
        setState(() {
          _messages = deviceMessages;
        });
      }
    });
  }

  void _checkConnectionStatus() {
    // Check if device is already connected
    setState(() {
      _isConnected = widget.device.isConnected;
      _isLoading = false;
    });
  }

  Future<void> _disconnectFromDevice() async {
    try {
      await _bleService.disconnectDevice(widget.device);
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Error disconnecting: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnect error: $e')),
        );
      }
    }
  }

  Future<void> _sendMessage() async {
    final messageText = _messageController.text.trim();
    if (messageText.isEmpty) return;

    try {
      final success = await _bleService.sendMessage(widget.device.id, messageText);
      if (mounted) {
        if (success) {
          _messageController.clear();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to send message')),
          );
        }
      }
    } catch (e) {
      debugPrint('Send message error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send error: $e')),
        );
      }
    }
  }

  // Enhanced _associateDeviceWithContact method for BleDeviceDetailScreen
  void _associateDeviceWithContact() {
    showDialog(
      context: context,
      builder: (context) {
        final usernameController = TextEditingController();
        final displayNameController = TextEditingController();
        bool createNewContact = false;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(createNewContact
                  ? 'Create New Contact'
                  : 'Associate with Existing Contact'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Device info summary
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.bluetooth, color: Colors.blue),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _bleService.getDisplayName(widget.device),
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'ID: ${widget.device.id.substring(0, math.min(widget.device.id.length, 8))}...',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Toggle between creating new contact and associating with existing
                    Row(
                      children: [
                        Checkbox(
                          value: createNewContact,
                          onChanged: (value) {
                            setState(() {
                              createNewContact = value ?? false;
                              // Clear controllers when switching modes
                              usernameController.clear();
                              displayNameController.clear();
                            });
                          },
                        ),
                        const Text('Create new contact'),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // Fields based on the selected mode
                    if (createNewContact) ...[
                      const Text(
                        'Enter new contact information:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: usernameController,
                        decoration: const InputDecoration(
                          labelText: 'Username (unique)',
                          border: OutlineInputBorder(),
                        ),
                        autocorrect: false,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: displayNameController,
                        decoration: const InputDecoration(
                          labelText: 'Display Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ] else ...[
                      const Text(
                        'Select an existing contact:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        decoration: const InputDecoration(
                          labelText: 'Contact',
                          border: OutlineInputBorder(),
                        ),
                        hint: const Text('Select a contact'),
                        items: InMemoryStore.contacts
                            .where((c) => c.bleDeviceId == null) // Only show contacts not already associated
                            .map((contact) => DropdownMenuItem(
                          value: contact.username,
                          child: Text('${contact.displayName} (${contact.username})'),
                        ))
                            .toList(),
                        onChanged: (value) {
                          usernameController.text = value ?? '';
                        },
                      ),
                      if (InMemoryStore.contacts.where((c) => c.bleDeviceId == null).isEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.yellow.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'All contacts already have associated devices. Create a new contact instead.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (createNewContact) {
                      final username = usernameController.text.trim();
                      final displayName = displayNameController.text.trim();

                      if (username.isEmpty || displayName.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Username and display name cannot be empty')),
                        );
                        return;
                      }

                      // Create new contact and associate the device
                      final success = InMemoryStore.addContact(username, displayName);
                      if (!success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Username already exists!')),
                        );
                        return;
                      }

                      // Associate the device with the new contact
                      try {
                        InMemoryStore.associateDeviceWithContact(widget.device.id, username);
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Contact "$displayName" created and device associated')),
                        );

                        // Offer to start a chat with the new contact
                        _offerToStartChat(username);
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error: $e')),
                        );
                      }
                    } else {
                      // Associate with existing contact
                      final username = usernameController.text.trim();
                      if (username.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please select a contact')),
                        );
                        return;
                      }
                      try {
                        InMemoryStore.associateDeviceWithContact(widget.device.id, username);

                        // Find the contact's display name for the success message
                        final contact = InMemoryStore.contacts.firstWhere(
                              (c) => c.username == username,
                          orElse: () => Contact(username: username, displayName: username),
                        );

                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Device associated with ${contact.displayName}')),
                        );

                        // Offer to start a chat with the contact
                        _offerToStartChat(username);
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error: $e')),
                        );
                      }
                    }
                  },
                  child: Text(createNewContact ? 'Create & Associate' : 'Associate'),
                ),
              ],
            );
          },
        );
      },
    );
  }

// Helper method to offer starting a chat with the associated contact
  void _offerToStartChat(String username) {
    // Find the contact
    final contact = InMemoryStore.contacts.firstWhere(
          (c) => c.username == username,
      orElse: () => throw Exception('Contact not found'),
    );

    // Show prompt to start chatting
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start Chatting?'),
        content: Text('Would you like to start chatting with ${contact.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Close device detail screen

              // Open chat screen
              final chat = InMemoryStore.getOrCreateChat(contact);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ChatScreenDetail(chat: chat)),
              );
            },
            child: const Text('Start Chat'),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    return ListView.builder(
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final isSent = message.senderId == _bleService.deviceId;

        return Align(
          alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSent ? Colors.blue[100] : Colors.grey[300],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.content,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('HH:mm').format(message.timestamp),
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final deviceName = _bleService.getDisplayName(widget.device);

    return Scaffold(
      appBar: AppBar(
        title: Text(deviceName),
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
                Text('Device ID: ${widget.device.id}'),
                const SizedBox(height: 4),
                Text('RSSI: ${widget.device.rssi} dBm'),
              ],
            ),
          ),

          // Messages
          Expanded(
            child: _buildMessageList(),
          ),

          // Message input
          if (_isConnected)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _messagesSubscription?.cancel();
    _messageController.dispose();
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
  final BleService _bleService = BleService();
  StreamSubscription<List<BleMessage>>? _messagesSubscription;

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

    // Listen for messages from the BLE service
    _messagesSubscription = _bleService.messages.listen((messages) {
      final deviceId = widget.chat.contact.bleDeviceId;
      if (deviceId == null) return;

      // Filter messages for this contact
      final contactMessages = messages.where((m) =>
      (m.senderId == deviceId && m.recipientId == _bleService.deviceId) ||
          (m.senderId == _bleService.deviceId && m.recipientId == deviceId)
      ).toList();

      // Add new messages to the chat
      for (final bleMessage in contactMessages) {
        // Check if message already exists in the chat
        final exists = widget.chat.messages.any((m) =>
        m.content == bleMessage.content &&
            m.timestamp.isAtSameMomentAs(bleMessage.timestamp)
        );

        if (!exists) {
          final message = Message(
            content: bleMessage.content,
            timestamp: bleMessage.timestamp,
            isSent: bleMessage.senderId == _bleService.deviceId,
          );

          setState(() {
            widget.chat.messages.add(message);
            // Sort messages by timestamp
            widget.chat.messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          });

          // Scroll to bottom
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });
        }
      }
    });

    // Check if contact's device is available
    final deviceId = widget.chat.contact.bleDeviceId;
    if (deviceId != null) {
      _bleService.devices.listen((devices) {
        final contactDevice = devices.where((d) => d.id == deviceId).toList();
        if (contactDevice.isNotEmpty && !contactDevice.first.isConnected) {
          // Try to connect to the device if it's discovered but not connected
          _bleService.connectToDevice(contactDevice.first);
        }
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final deviceId = widget.chat.contact.bleDeviceId;
    if (deviceId != null) {
      try {
        final success = await _bleService.sendMessage(deviceId, text);

        if (success) {
          _controller.clear();
        } else {
          // Message will be delivered later via store-and-forward
          _controller.clear();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Device not in range. Message will be delivered when possible.'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send message: $e')),
          );
        }
      }
    } else {
      // Fallback for contacts without associated BLE devices
      final message = Message(
        content: text,
        timestamp: DateTime.now(),
        isSent: true,
      );

      setState(() {
        widget.chat.messages.add(message);
        _controller.clear();
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
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

  @override
  void dispose() {
    _controller.dispose();
    _messagesSubscription?.cancel();
    super.dispose();
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
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          // Add a search button for finding contacts
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              // Implement contact search
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Contact search coming soon')),
              );
            },
          ),
        ],
      ),
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
              trailing: contact.bleDeviceId != null
                  ? Icon(Icons.bluetooth_connected, color: Colors.blue)
                  : null,
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
            const ListTile(title: Text('No contacts yet. Add a contact using the button below.'))
          else
            ...normalContacts.map((contact) => ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(contact.displayName),
              subtitle: Text('Username: ${contact.username}'),
              trailing: contact.bleDeviceId != null
                  ? Tooltip(
                message: 'Bluetooth device connected',
                child: Icon(Icons.bluetooth_connected, color: Colors.blue),
              )
                  : null,
              onTap: () => _openChat(contact),
              onLongPress: () => _showContactOptions(contact),
            )),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddContactDialog,
        backgroundColor: Colors.red,
        tooltip: 'Add new contact',
        child: const Icon(Icons.person_add),
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

  void _showContactOptions(Contact contact) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.chat),
            title: const Text('Chat'),
            onTap: () {
              Navigator.pop(context);
              _openChat(contact);
            },
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('View Profile'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileViewScreen(contact: contact),
                ),
              );
            },
          ),
          ListTile(
            leading: contact.isBlocked
                ? const Icon(Icons.block, color: Colors.red)
                : const Icon(Icons.block_flipped),
            title: Text(contact.isBlocked ? 'Unblock Contact' : 'Block Contact'),
            onTap: () {
              setState(() {
                contact.isBlocked = !contact.isBlocked;
              });
              Navigator.pop(context);
            },
          ),
          if (contact.bleDeviceId != null)
            ListTile(
              leading: const Icon(Icons.bluetooth_disabled),
              title: const Text('Unlink Bluetooth Device'),
              onTap: () {
                setState(() {
                  contact.bleDeviceId = null;
                });
                Navigator.pop(context);
              },
            ),
        ],
      ),
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
              autocorrect: false,
              autofocus: true,
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Display Name'),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                // Handle enter key as "Add" action
                _addContact(userCtrl.text, nameCtrl.text);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => _addContact(userCtrl.text, nameCtrl.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _addContact(String username, String displayName) {
    final cleanUsername = username.trim();
    final cleanDisplayName = displayName.trim();

    if (cleanUsername.isEmpty || cleanDisplayName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username and display name cannot be empty')),
      );
      return;
    }

    final success = InMemoryStore.addContact(cleanUsername, cleanDisplayName);
    Navigator.pop(context);

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username already exists!')),
      );
    } else {
      setState(() {}); // Refresh the list
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Contact "$cleanDisplayName" added successfully!')),
      );
    }
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
            Navigator.pushNamed(context, '/generalSettings');
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
          }),
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
            // Placeholder for contact's image.
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