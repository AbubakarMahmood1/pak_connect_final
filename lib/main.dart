import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble/ble_service.dart';
import 'logging/log_service.dart';

late final FlutterBackgroundService backgroundService;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize services in correct order
  await LogService.init();

  // Initialize background service once
  backgroundService = await setupBackgroundService();

  await InMemoryStore.loadProfile();
  await InMemoryStore.loadContacts();
  await InMemoryStore.loadChats();

  // Check permissions in main app
  bool hasPermission = await Permission.bluetooth.status.isGranted;
  if (!hasPermission) {
    debugPrint('Requesting Bluetooth permission...');
    await Permission.bluetooth.request();
  }
  debugPrint('Bluetooth permission status: ${await Permission.bluetooth.status}');

  // Initialize BLE service with the background service instance
  final bleService = BleService(backgroundService);

  // Check initialization context to avoid duplicate initializations
  final coordinator = BleInitializationCoordinator();
  final context = await coordinator.getInitializationContext();

  // Only initialize in main app if not recently initialized in background
  // or if initialization is old (more than 5 minutes)
  if (!context['initialized'] ||
      !context['inBackground'] ||
      context['age'] > 5 * 60 * 1000) {

    debugPrint('🔄 Initializing BLE service in main app');
    await coordinator.initializeBle(service: bleService, isBackgroundService: false);
  } else {
    debugPrint('⏩ Skipping BLE initialization, already initialized in background recently');
    // Still need to make sure the BLE service knows it's initialized
    bleService.markAsInitialized();
  }

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
@pragma('vm:entry-point')
void backgroundServiceEntryPoint(ServiceInstance service) async {
  debugPrint('🔄 Background service entry point started');

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

  debugPrint('🔄 Creating BLE service for background');

  // Initialize BLE service with the service instance
  final bleService = BleService.backgroundInstance(service);

  // Use coordinator to manage initialization state
  final coordinator = BleInitializationCoordinator();
  final context = await coordinator.getInitializationContext();

  // Only initialize in background if not already initialized in main app recently
  if (!context['initialized'] ||
      context['inBackground'] ||  // If previous init was in background, we should reinitialize
      context['age'] > 5 * 60 * 1000) {

    debugPrint('🔄 Initializing BLE service in background service');
    await coordinator.initializeBle(service: bleService, isBackgroundService: true);
  } else {
    debugPrint('⏩ Skipping BLE initialization, already initialized in main app recently');
    // Make sure the BLE service knows it's initialized
    bleService.markAsInitialized();
  }

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
  // For Android 12+, request location permission BEFORE BLE permissions
  if (Platform.isAndroid) {
    // Always request location first as it's required for BLE on Android
    await Permission.locationWhenInUse.request();

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 31) { // Android 12+
      // Request permissions with explicit user interaction
      bool scanGranted = await Permission.bluetoothScan.status.isGranted;
      if (!scanGranted) {
        scanGranted = await Permission.bluetoothScan.request().isGranted;
      }

      bool connectGranted = await Permission.bluetoothConnect.status.isGranted;
      if (!connectGranted) {
        connectGranted = await Permission.bluetoothConnect.request().isGranted;
      }

      bool advertiseGranted = await Permission.bluetoothAdvertise.status.isGranted;
      if (!advertiseGranted) {
        advertiseGranted = await Permission.bluetoothAdvertise.request().isGranted;
      }
    } else {
      // For older Android versions
      await Permission.bluetooth.request();
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

    // Use critical duty cycling pattern (brief scans, long intervals)
    final currentMinute = DateTime.now().minute;
    shouldScan = (currentMinute % 15 == 0) && // Only scan once every 15 minutes
        (bleService.hasPendingMessages() ||  // Either has messages
            DateTime.now().difference(bleService.lastMessageActivityTime).inMinutes > 60); // Or long since activity
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

  Map<String, dynamic> toJson() {
    return {
      'username': username,
      'displayName': displayName,
      'isBlocked': isBlocked,
      'isEmergency': isEmergency,
      'profileImage': profileImage,
      'notificationSound': notificationSound,
      'bleDeviceId': bleDeviceId,
    };
  }
}

// Message model.
class Message {
  final String content;
  final DateTime timestamp;
  final bool isSent;
  final Map<String, dynamic>? metadata;

  Message({
    required this.content,
    required this.timestamp,
    required this.isSent,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    return {
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isSent': isSent,
      'metadata': metadata,
    };
  }
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

  Map<String, dynamic> toJson() {
    return {
      'contact': contact.toJson(),
      'messages': messages.map((m) => m.toJson()).toList(),
      'lockPassword': lockPassword,
    };
  }

}

/// In-Memory Data Store
class InMemoryStore {
  // Self profile (username is fixed once set)
  static String? myUsername;
  static String myDisplayName = "Me";
  static String? myProfileImage;
  static String? myDeviceId;
  static bool serviceEnabled = true;

  // Preloaded emergency contacts.
  static final List<Contact> contacts = [
    Contact(username: 'police', displayName: 'Police', isEmergency: true),
    Contact(username: '911', displayName: 'Ambulance', isEmergency: true),
    Contact(username: 'hospital', displayName: 'Hospital', isEmergency: true),
  ];


  static Future<void> saveContacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final contactsJson = contacts.map((c) => jsonEncode({
        'username': c.username,
        'displayName': c.displayName,
        'isBlocked': c.isBlocked,
        'isEmergency': c.isEmergency,
        'profileImage': c.profileImage,
        'notificationSound': c.notificationSound,
        'bleDeviceId': c.bleDeviceId,
      })).toList();

      await prefs.setStringList('saved_contacts', contactsJson);
      debugPrint('Contacts saved successfully: ${contacts.length}');
    } catch (e) {
      debugPrint('Error saving contacts: $e');
    }
  }

  static Future<void> loadContacts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final contactsJson = prefs.getStringList('saved_contacts');

      if (contactsJson != null && contactsJson.isNotEmpty) {
        // Clear hardcoded contacts except emergency ones
        contacts.removeWhere((c) => !c.isEmergency);

        for (final json in contactsJson) {
          final data = jsonDecode(json) as Map<String, dynamic>;
          contacts.add(Contact(
            username: data['username'],
            displayName: data['displayName'],
            isBlocked: data['isBlocked'] ?? false,
            isEmergency: data['isEmergency'] ?? false,
            profileImage: data['profileImage'],
            notificationSound: data['notificationSound'] ?? 'Default',
            bleDeviceId: data['bleDeviceId'],
          ));
        }
        debugPrint('Loaded ${contactsJson.length} contacts');
      }
    } catch (e) {
      debugPrint('Error loading contacts: $e');
    }
  }

  // Add these methods to your InMemoryStore class
  static Future<void> saveProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('my_username', myUsername ?? '');
      await prefs.setString('my_display_name', myDisplayName);
      await prefs.setString('my_device_id', myDeviceId ?? '');
      if (myProfileImage != null) {
        await prefs.setString('my_profile_image', myProfileImage!);
      }
      debugPrint('Profile saved successfully');
    } catch (e) {
      debugPrint('Error saving profile: $e');
    }
  }

  static Future<void> loadProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Retrieve user profile data from SharedPreferences
      final savedUsername = prefs.getString('my_username');
      final savedDisplayName = prefs.getString('my_display_name');
      final savedDeviceId = prefs.getString('my_device_id');
      final savedProfileImage = prefs.getString('my_profile_image');

      // Update InMemoryStore with retrieved values if they exist
      if (savedUsername != null && savedUsername.isNotEmpty) {
        myUsername = savedUsername;
      }

      if (savedDisplayName != null && savedDisplayName.isNotEmpty) {
        myDisplayName = savedDisplayName;
      }

      if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
        myDeviceId = savedDeviceId;
      }

      if (savedProfileImage != null && savedProfileImage.isNotEmpty) {
        myProfileImage = savedProfileImage;
      }

      debugPrint('Profile loaded successfully');
    } catch (e) {
      debugPrint('Error loading profile: $e');
    }
  }

  // Delete a contact by username
  static Future<bool> deleteContact(String username) async {
    // Find contact in list, but don't fail if already removed
    final contactIndex = contacts.indexWhere((c) => c.username == username);
    String? bleDeviceId;

    if (contactIndex >= 0) {
      // Capture BLE device ID before removing
      bleDeviceId = contacts[contactIndex].bleDeviceId;
      contacts.removeAt(contactIndex);
    }

    // Remove associated chat if it exists
    chats.removeWhere((chat) => chat.contact.username == username);

    // Clear related messages from BLE service queue if we have the device ID
    if (bleDeviceId != null) {
      final bleService = BleService();
      await bleService.deleteAllMessagesForContact(bleDeviceId);
    }

    // Save changes to persistent storage
    await saveContacts();
    await saveChats();

    return true;
  }

  // Delete a chat by contact username
  static Future<bool> deleteChat(String contactUsername) async {
    // Find chat in list, but don't fail if already removed
    final chatIndex = chats.indexWhere((chat) => chat.contact.username == contactUsername);
    String? bleDeviceId;

    if (chatIndex >= 0) {
      // Capture BLE device ID before removing
      bleDeviceId = chats[chatIndex].contact.bleDeviceId;
      chats.removeAt(chatIndex);
    }

    // Clear related messages from BLE service queue if we have the device ID
    if (bleDeviceId != null) {
      final bleService = BleService();
      await bleService.deleteMessagesForRecipient(bleDeviceId);
    }

    // Save changes
    await saveChats();

    return true;
  }

  // Delete a specific message from a chat
  static Future<bool> deleteMessage(String contactUsername, int messageIndex) async {
    final chatIndex = chats.indexWhere((chat) => chat.contact.username == contactUsername);

    // If chat not found or message already deleted, just save and return
    if (chatIndex < 0 || messageIndex < 0 || messageIndex >= chats[chatIndex].messages.length) {
      await saveChats(); // Save any other changes
      return false;
    }

    final message = chats[chatIndex].messages[messageIndex];
    final bleDeviceId = chats[chatIndex].contact.bleDeviceId;

    // Remove the message from the chat if it still exists
    if (messageIndex < chats[chatIndex].messages.length) {
      chats[chatIndex].messages.removeAt(messageIndex);
    }

    // If this is an outgoing message that might be queued, remove from BLE service
    if (message.isSent && bleDeviceId != null) {
      // We need a way to identify the BLE message
      final bleService = BleService();

      // Note: This is a simplification. In a production app, you'd want a more
      // reliable way to correlate UI messages with BLE messages
      final now = DateTime.now();
      final timeDiff = now.difference(message.timestamp).inMinutes;

      // Only attempt to delete from queue if message is recent (less than 3 hours old)
      if (timeDiff < 180) {
        final bleMessages = await bleService.messages.first;

        // Look for matching messages in the BLE queue
        for (final bleMessage in bleMessages) {
          if (bleMessage.content == message.content &&
              bleMessage.recipientId == bleDeviceId &&
              bleMessage.status != MessageStatus.delivered &&
              bleMessage.status != MessageStatus.ack) {

            // Found a matching queued message, delete it
            await bleService.deleteMessage(bleMessage.id);
            break;
          }
        }
      }
    }

    // Save changes
    await saveChats();

    return true;
  }

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

  static Future<void> saveChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final chatsJson = chats.map((chat) => jsonEncode({
        'contact': chat.contact.toJson(),
        'messages': chat.messages.map((m) => m.toJson()).toList(),
        'lockPassword': chat.lockPassword,
      })).toList();

      await prefs.setStringList('saved_chats', chatsJson);
      debugPrint('Chats saved successfully: ${chats.length}');
    } catch (e) {
      debugPrint('Error saving chats: $e');
    }
  }

  static Future<void> loadChats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final chatsJson = prefs.getStringList('saved_chats');

      if (chatsJson != null && chatsJson.isNotEmpty) {
        chats.clear();

        for (final json in chatsJson) {
          final data = jsonDecode(json) as Map<String, dynamic>;

          // Get or create contact for this chat
          final contactData = data['contact'] as Map<String, dynamic>;
          final contactUsername = contactData['username'] as String;

          // Find if we already have this contact loaded
          Contact chatContact;
          try {
            chatContact = contacts.firstWhere((c) => c.username == contactUsername);
          } catch (e) {
            // Contact not found, create a new one
            chatContact = Contact(
              username: contactData['username'],
              displayName: contactData['displayName'],
              isBlocked: contactData['isBlocked'] ?? false,
              isEmergency: contactData['isEmergency'] ?? false,
              profileImage: contactData['profileImage'],
              notificationSound: contactData['notificationSound'] ?? 'Default',
              bleDeviceId: contactData['bleDeviceId'],
            );

            // Add to contacts list if not already present
            if (!contacts.any((c) => c.username == chatContact.username)) {
              contacts.add(chatContact);
            }
          }

          // Load messages
          final messagesData = data['messages'] as List<dynamic>;
          final messages = messagesData.map((m) {
            final msgData = m as Map<String, dynamic>;
            return Message(
              content: msgData['content'],
              timestamp: DateTime.parse(msgData['timestamp']),
              isSent: msgData['isSent'],
            );
          }).toList();

          // Create chat
          final chat = Chat(
            contact: chatContact,
            messages: messages,
            lockPassword: data['lockPassword'],
          );

          chats.add(chat);
        }

        debugPrint('Loaded ${chats.length} chats');
      }
    } catch (e) {
      debugPrint('Error loading chats: $e');
    }
  }

  static Future<Chat> handleMessageFromUnknownContact(String username, String content, bool isSent) async {
    // Check if we already have this contact
    Contact contact;

    try {
      contact = contacts.firstWhere((c) => c.username == username);
    } catch (e) {
      // Create a new contact for this unknown user
      contact = Contact(
        username: username,
        displayName: username, // Use username as display name initially
        isBlocked: false,
        isEmergency: false,
      );

      // Add to contacts list
      contacts.add(contact);

      // Save contacts
      await saveContacts();
    }

    // Create or get chat for this contact
    final chat = getOrCreateChat(contact);

    // Add the message
    chat.messages.add(Message(
      content: content,
      timestamp: DateTime.now(),
      isSent: isSent,
    ));

    // Save chats
    await saveChats();

    return chat;
  }

  // Add a new contact if username not already exists.
  static bool addContact(String username, String displayName, {String? bleDeviceId}) {
    final exists = contacts.any((c) => c.username.toLowerCase() == username.toLowerCase());
    if (exists) return false;

    contacts.add(Contact(
      username: username,
      displayName: displayName,
      bleDeviceId: bleDeviceId,
    ));

    saveContacts(); // Auto-save
    return true;
  }

// Add a new method for Contact objects
  static bool addContactObject(Contact contact) {
    final exists = contacts.any((c) => c.username.toLowerCase() == contact.username.toLowerCase());
    if (exists) return false;
    contacts.add(contact);
    saveContacts(); // Auto-save
    return true;
  }

  static bool associateDeviceWithContact(String deviceId, String username) {
    final contact = contacts.firstWhere(
          (c) => c.username == username,
      orElse: () => throw Exception('Contact not found'),
    );

    contact.bleDeviceId = BleService().normalizeDeviceId(deviceId);

    saveContacts(); // Make sure to save after modification
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
  final NotificationService _notificationService = NotificationService();

  @override
  void initState() {
    super.initState();

    // Request notification permissions after UI is initialized
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationService.requestPermissions();
    });
  }


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
  final BleService _bleService = BleService();
  bool _isScanning = false;
  bool _isResetting = false;
  String _connectionState = 'Ready';
  List<BleDevice> _devices = [];
  StreamSubscription<List<BleDevice>>? _devicesSubscription;
  StreamSubscription<String>? _connectionStateSubscription;
  final ValueNotifier<bool> _isConnecting = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _connectingDeviceId = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _setupBleListeners();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissions();
    });
  }

  Future<void> _checkPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    if (mounted) {
      List<String> deniedPermissions = [];

      statuses.forEach((permission, status) {
        if (!status.isGranted) {
          deniedPermissions.add(permission.toString().split('.').last);
        }
      });

      if (deniedPermissions.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Missing permissions: ${deniedPermissions.join(", ")}'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () => openAppSettings(),
            ),
          ),
        );
      }
    }
  }

  void _setupBleListeners() {
    // Only show PakConnect devices by default
    _devicesSubscription = _bleService.devices.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices.where((device) => device.supportsRelay).toList();
        });
      }
    });

    // Listen for connection state changes
    _connectionStateSubscription = _bleService.connectionState.listen((state) {
      if (mounted) {
        setState(() {
          _isScanning = state == 'Scanning';
          _connectionState = state;
        });
      }
    });
  }

  void _startScanning() async {
    try {
      // Check if scanning already in progress
      if (_isScanning) {
        return;
      }

      // Start scan through your service
      setState(() {
        _isScanning = true;
      });

      await _bleService.startScan(
        maxDuration: const Duration(seconds: 30),
        lowPowerMode: false,
      );

    } catch (e) {
      debugPrint('Error scanning for BLE devices: $e');

      // Use a local context reference for showing the snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error scanning: $e')),
        );
      }

      setState(() {
        _isScanning = false;
      });
    }
  }

  void _stopScanning() async {
    try {
      await _bleService.stopScan();
    } catch (e) {
      debugPrint('Error stopping scan: $e');
    }
  }

  Future<void> _resetBleSystem() async {
    if (_isResetting) return;

    setState(() {
      _isResetting = true;
    });

    try {
      // Show a loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Resetting BLE'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('Resetting BLE system...\nThis may take a moment.'),
            ],
          ),
        ),
      );

      // Call the BLE service to perform a reset
      final success = await _bleService.forceReinitializeBle();

      // Close the dialog
      if (mounted) {
        Navigator.of(context).pop();
      }

      // Show the result
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                success
                    ? 'BLE system reset successful'
                    : 'Failed to reset BLE system'
            ),
            backgroundColor: success ? Colors.green : Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }

      // If successful, start scanning again
      if (success && mounted) {
        _startScanning();
      }
    } catch (e) {
      // Close the dialog if an exception occurs
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error resetting BLE: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isResetting = false;
      });
    }
  }

  // Connect to device (your existing code)
  void _connectToDevice(BleDevice device) async {
    // Set connection state in the UI
    _isConnecting.value = true;
    _connectingDeviceId.value = device.id;

    try {
      final success = await _bleService.connectToDevice(device);

      // Reset connection state
      _isConnecting.value = false;
      _connectingDeviceId.value = null;

      if (!mounted) return;

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
    } catch (e) {
      debugPrint('Connection error: $e');

      // Reset connection state
      _isConnecting.value = false;
      _connectingDeviceId.value = null;

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection error: $e')),
      );
    }
  }

  // Convert RSSI to signal strength widget
  Widget _buildSignalStrength(int rssi) {
    Color color;
    IconData icon;

    if (rssi >= -60) {
      color = Colors.green;
      icon = Icons.network_wifi;
    } else if (rssi >= -70) {
      color = Colors.lightGreen;
      icon = Icons.network_wifi;
    } else if (rssi >= -80) {
      color = Colors.orange;
      icon = Icons.network_wifi;
    } else {
      color = Colors.red;
      icon = Icons.network_wifi;
    }

    return Icon(icon, color: color);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          // Add the scan button to the app bar
          if (!_isScanning && !_isResetting)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startScanning,
              tooltip: 'Scan for Devices',
            ),
          if (_isScanning)
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _stopScanning,
              tooltip: 'Stop scanning',
            ),
        ],
      ),
      body: Stack(
        children: [
          // Main content
          Column(
            children: [
              // Add progress indicator for scanning
              if (_isScanning)
                LinearProgressIndicator(
                  backgroundColor: Colors.blue[100],
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
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
                      Text('Scanning for nearby devices...'),
                    ],
                  )
                      : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bluetooth_searching, size: 64, color: Colors.blue),
                      SizedBox(height: 16),
                      Text('No devices found nearby.'),
                      SizedBox(height: 8),
                      Text('Tap the refresh button to scan.', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
                    : ListView.builder(
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    final device = _devices[index];
                    final deviceName = _bleService.getDisplayName(device);
                    final deviceId = device.id;
                    final rssi = device.rssi;

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: device.isConnected ? Colors.green : Colors.blue,
                          child: Icon(
                              device.isConnected ? Icons.link : Icons.devices,
                              color: Colors.white
                          ),
                        ),
                        title: Text(
                          deviceName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _buildSignalStrength(rssi),
                                const SizedBox(width: 4),
                                Text('$rssi dBm'),
                              ],
                            ),
                            Text(
                              'ID: ${deviceId.substring(0, math.min(deviceId.length, 8))}...',
                              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                        trailing: ValueListenableBuilder<String?>(
                          valueListenable: _connectingDeviceId,
                          builder: (context, connectingId, _) {
                            return connectingId == deviceId
                                ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                                : IconButton(
                              icon: const Icon(Icons.connect_without_contact),
                              tooltip: 'Connect',
                              color: Colors.blue,
                              onPressed: () => _connectToDevice(device),
                            );
                          },
                        ),
                        onTap: () => _connectToDevice(device),
                      ),
                    );
                  },
                ),
              ),

              // Bottom action card for reset BLE functionality
              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BLE Status: $_connectionState',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _connectionState.contains('error') || _connectionState == 'Not Initialized'
                              ? Colors.red
                              : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Having connection issues?',
                            style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                          ),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reset BLE'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _isResetting ? null : _resetBleSystem,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Connection overlay
          ValueListenableBuilder<bool>(
            valueListenable: _isConnecting,
            builder: (context, isConnecting, _) {
              return isConnecting
                  ? Container(
                color: Colors.black54,
                child: ValueListenableBuilder<String?>(
                  valueListenable: _connectingDeviceId,
                  builder: (context, deviceId, _) {
                    final deviceName = deviceId != null
                        ? _devices.firstWhere((d) => d.id == deviceId,
                        orElse: () => _devices.first).name ?? 'Device'
                        : 'Device';

                    return Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 24),
                              Text('Connecting to $deviceName...'),
                              const SizedBox(height: 8),
                              Text(
                                'This may take a moment',
                                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              )
                  : const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _isConnecting.dispose();
    _connectingDeviceId.dispose();
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

    debugPrint('📱 UI triggered message send to ${widget.device.id}: $messageText');

    try {
      final success = await _bleService.sendMessage(widget.device.id, messageText);

      if (mounted) {
        if (success) {
          debugPrint('✅ UI received success response for message: $messageText');
          _messageController.clear();
        } else {
          debugPrint('⚠️ UI received failure response for message: $messageText');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to send message')),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Send message error in UI: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send error: $e')),
        );
      }
    }
  }

  // Normalized device ID helper
  static String _normalizeDeviceId(String deviceId) {
    // If it's already a UUID with dashes, keep as is
    if (deviceId.contains('-')) return deviceId;

    // If it's a MAC address like format (with colons)
    if (deviceId.contains(':')) {
      return '00000000-0000-0000-0000-${deviceId.replaceAll(':', '').toLowerCase()}';
    }

    // If it's a hex string without formatting, add dashes
    if (deviceId.length == 32) {
      return '${deviceId.substring(0, 8)}-${deviceId.substring(8, 12)}-${deviceId.substring(12, 16)}-${deviceId.substring(16, 20)}-${deviceId.substring(20)}';
    }

    // Default - keep as is
    return deviceId;
  }

  // Fixed associate device with contact method
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
              content: Container(
                width: double.maxFinite,
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
                child: SingleChildScrollView(
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
                      final normalizedDeviceId = _normalizeDeviceId(widget.device.id);
                      final success = InMemoryStore.addContact(username, displayName, bleDeviceId: normalizedDeviceId);
                      if (!success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Username already exists!')),
                        );
                        return;
                      }

                      // Associate the device with the new contact
                      try {
                        InMemoryStore.associateDeviceWithContact(normalizedDeviceId, username);
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
                        final normalizedDeviceId = _normalizeDeviceId(widget.device.id);
                        InMemoryStore.associateDeviceWithContact(normalizedDeviceId, username);

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
        return Dismissible(
          key: Key('chat_${chat.contact.username}'),
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20.0),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          direction: DismissDirection.endToStart,
          confirmDismiss: (direction) async {
            return await showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Delete Chat'),
                content: Text('Are you sure you want to delete the chat with ${chat.contact.displayName}?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
          },
          onDismissed: (direction) {
            final contactName = chat.contact.displayName;
            final contactUsername = chat.contact.username;

            // Remove chat from the list immediately for UI responsiveness
            setState(() {
              InMemoryStore.chats.removeAt(index);
            });

            // Show feedback right away
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Chat with $contactName deleted')),
            );

            Future.microtask(() async {
              await InMemoryStore.deleteChat(contactUsername);
            });
          },
          child: ListTile(
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
          ),
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
        (m.content == bleMessage.content && m.timestamp.isAtSameMomentAs(bleMessage.timestamp)) ||
            (m.metadata != null && m.metadata!['bleMessageId'] == bleMessage.id)
        );

        if (!exists) {
          final message = Message(
            content: bleMessage.content,
            timestamp: bleMessage.timestamp,
            isSent: bleMessage.senderId == _bleService.deviceId,
            metadata: {'bleMessageId': bleMessage.id},
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

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final deviceId = widget.chat.contact.bleDeviceId;
    if (deviceId != null) {
      try {
        // Try the new direct send method first
        debugPrint('📱 UI triggered message send to $deviceId: $text');

        // IMPORTANT: Use the new direct method first
        final directSuccess = await _bleService.sendMessageDirect(deviceId, text);

        if (directSuccess) {
          debugPrint('✅ Direct send succeeded!');
          _controller.clear();

          // Save chats after sending a message
          InMemoryStore.saveChats();

          return;
        }

        debugPrint('⚠️ Direct send failed, falling back to queue method');

        // Fall back to regular method
        final success = await _bleService.sendMessage(deviceId, text);

        if (success) {
          _controller.clear();

          // Save chats after sending a message
          InMemoryStore.saveChats();
        } else {
          // Message will be delivered later via store-and-forward
          _controller.clear();

          // Save chats anyway
          InMemoryStore.saveChats();

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

      // Save chats after adding a message
      InMemoryStore.saveChats();

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
                  return MessageBubble(
                    message: message,
                    onLongPress: (message) => _showMessageOptions(message, index),
                  );
                },
              )
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  void _showMessageOptions(Message message, int index) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy Message'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.content));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Message copied to clipboard')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete Message', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteMessage(index);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteMessage(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Message'),
        content: const Text('Are you sure you want to delete this message? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              // Close the dialog immediately
              Navigator.pop(context);

              // Store the username before any async operations
              final contactUsername = widget.chat.contact.username;

              // Update UI immediately for responsiveness
              setState(() {
                widget.chat.messages.removeAt(index);
              });

              // Scroll to appropriate position
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollController.hasClients) {
                  _scrollController.animateTo(
                    _scrollController.position.maxScrollExtent,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                }
              });

              // Then perform the actual deletion in the background
              Future.microtask(() async {
                await InMemoryStore.deleteMessage(contactUsername, index);
              });
            },
            child: const Text('Delete'),
          ),
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
  final Function(Message)? onLongPress;

  const MessageBubble({super.key, required this.message, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final bubbleColor = message.isSent ? Colors.blue[200] : Colors.grey[300];
    final align = message.isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    return Column(
      crossAxisAlignment: align,
      children: [
        GestureDetector(
          onTap: () => _showTimestamp(context),
          onLongPress: () => onLongPress != null ? onLongPress!(message) : _showTimestamp(context),
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
        onPressed: () {
          // Show options dialog
          showModalBottomSheet(
            context: context,
            builder: (context) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_add),
                    title: const Text('Add Contact Manually'),
                    onTap: () {
                      Navigator.pop(context);
                      _showAddContactDialog();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.qr_code_scanner),
                    title: const Text('Scan QR Code'),
                    onTap: () async {
                      Navigator.pop(context);
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const QrScannerScreen()),
                      );
                      if (result != null) {
                        setState(() {}); // Refresh list if contact was added
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.qr_code),
                    title: const Text('Show My QR Code'),
                    onTap: () {
                      Navigator.pop(context);
                      _showMyQrCode();
                    },
                  ),
                ],
              );
            },
          );
        },
        backgroundColor: Colors.red,
        tooltip: 'Add new contact',
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showMyQrCode() {
    if (InMemoryStore.myUsername == null || InMemoryStore.myUsername!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please set up your profile first')),
      );
      return;
    }

    // Get BLE service instance to access deviceId
    final BleService bleService = BleService();

    final normalizedDeviceId = bleService.normalizeDeviceId(
        InMemoryStore.myDeviceId ?? bleService.deviceId
    );

    // Create contact data with proper deviceId fallback
    final myContactData = {
      'username': InMemoryStore.myUsername,
      'displayName': InMemoryStore.myDisplayName,
      'deviceId': normalizedDeviceId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    // Convert to JSON string
    final qrData = jsonEncode(myContactData);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('My Contact Info'),
        // Use SizedBox with fixed width instead of complex layouts
        content: SizedBox(
          width: 250, // Fixed width to prevent layout calculation issues
          child: Column(
            mainAxisSize: MainAxisSize.min, // Important to prevent expansion
            children: [
              const Text('My Contact QR Code',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
              ),
              const SizedBox(height: 10),
              QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 200.0, // Fixed size
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 10),
              Text('Username: ${InMemoryStore.myUsername ?? "Not set"}'),
              Text('Display Name: ${InMemoryStore.myDisplayName}'),
              const Text(
                'Scan this QR code to add me as a contact',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
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
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('Delete Contact', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(context);
              _confirmDeleteContact(contact);
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

  void _addContact(String username, String displayName, {String? bleDeviceId}) {
    final cleanUsername = username.trim();
    final cleanDisplayName = displayName.trim();

    if (cleanUsername.isEmpty || cleanDisplayName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username and display name cannot be empty')),
      );
      return;
    }

    // Create contact with optional BLE device ID
    final contact = Contact(
      username: cleanUsername,
      displayName: cleanDisplayName,
      bleDeviceId: bleDeviceId,
    );

    // Use the new method for Contact objects
    final success = InMemoryStore.addContactObject(contact);
    Navigator.pop(context);

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username already exists!')),
      );
    } else {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Contact "$cleanDisplayName" added successfully!')),
      );
    }
  }

  void _confirmDeleteContact(Contact contact) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contact'),
        content: Text('Are you sure you want to delete ${contact.displayName}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              _deleteContact(contact);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _deleteContact(Contact contact) {
    // Store these values before any async work
    final username = contact.username;
    final displayName = contact.displayName;

    // First immediately remove from the contacts list for UI responsiveness
    setState(() {
      InMemoryStore.contacts.removeWhere((c) => c.username == username);
      InMemoryStore.chats.removeWhere((chat) => chat.contact.username == username);
    });

    // Show feedback right away
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Contact "$displayName" deleted')),
    );

    // Then perform the actual deletion in the background
    Future.microtask(() async {
      await InMemoryStore.deleteContact(username);
    });
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
  final BleService _bleService = BleService();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    // Call the InMemoryStore method to load the profile
    await InMemoryStore.loadProfile();

    // Update UI controllers
    setState(() {
      _usernameController.text = InMemoryStore.myUsername ?? '';
      _displayNameController.text = InMemoryStore.myDisplayName;
    });
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
      // Store the device ID as well
      InMemoryStore.myDeviceId = _bleService.deviceId;
    } else if (newUsername != InMemoryStore.myUsername) {
      _usernameController.text = InMemoryStore.myUsername!;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Username is fixed and cannot be changed')),
      );
    }

    InMemoryStore.myDisplayName = newDisplayName.isEmpty ? 'Me' : newDisplayName;

    // Save profile persistently using the InMemoryStore method
    InMemoryStore.saveProfile();

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
                child: InMemoryStore.myProfileImage != null
                    ? ClipOval(
                  child: Image.memory(
                    base64Decode(InMemoryStore.myProfileImage!),
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                  ),
                )
                    : const Icon(Icons.person, size: 40),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Username (unique)',
                  helperText: 'Cannot be changed once set',
                ),
                readOnly: InMemoryStore.myUsername != null &&
                    InMemoryStore.myUsername!.isNotEmpty,
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
              if (InMemoryStore.myUsername != null &&
                  InMemoryStore.myUsername!.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code),
                  label: const Text('Show My QR Code'),
                  onPressed: _showMyQrCode,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMyQrCode() {
    if (InMemoryStore.myUsername == null || InMemoryStore.myUsername!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please set up your profile first')),
      );
      return;
    }

    // Create contact data outside the builder to avoid rebuilds
    final myContactData = {
      'username': InMemoryStore.myUsername,
      'displayName': InMemoryStore.myDisplayName,
      'deviceId': InMemoryStore.myDeviceId ?? _bleService.deviceId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    // Convert to JSON string
    final qrData = jsonEncode(myContactData);

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('My Contact Info'),
        content: Container(
          width: 250, // Fixed width
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7, // Limit max height to 70% of screen
          ),
          child: SingleChildScrollView( // Add SingleChildScrollView here
            child: Column(
              mainAxisSize: MainAxisSize.min, // Keep this to ensure it only takes necessary space
              children: [
                const Text('My Contact QR Code',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                ),
                const SizedBox(height: 10),
                QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 200.0, // Fixed size
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 10),
                Text('Username: ${InMemoryStore.myUsername ?? "Not set"}'),
                Text('Display Name: ${InMemoryStore.myDisplayName}'),
                const Text(
                    'Scan this QR code to add me as a contact',
                    style: TextStyle(fontSize: 12, color: Colors.grey)
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildServiceStatusCard() {
    return Card(
      color: Colors.blue[50],
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Service Status',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // BLE Status
            StreamBuilder<String>(
                stream: _bleService.connectionState,
                builder: (context, snapshot) {
                  final status = snapshot.data ?? 'Unknown';
                  final isRunning = status != 'Not Initialized' && status != 'Error';

                  return SwitchListTile(
                    title: const Text('BLE Messaging Service'),
                    subtitle: Text('Status: $status'),
                    value: isRunning,
                    activeColor: Colors.green,
                    onChanged: (value) {
                      if (value) {
                        // Attempt to start service - using a separate method to avoid async gap
                        _startBleService();
                      } else {
                        // Stop service - using a separate method to avoid async gap
                        _stopBleService();
                      }

                      // Update UI immediately
                      setState(() {
                        InMemoryStore.serviceEnabled = value;
                      });
                    },
                  );
                }
            ),

            // Background Service Status
            FutureBuilder<bool>(
                future: _bleService.isBackgroundServiceRunning(),
                builder: (context, snapshot) {
                  final isRunning = snapshot.data ?? false;

                  return SwitchListTile(
                    title: const Text('Background Service'),
                    subtitle: Text(
                        isRunning
                            ? 'Running - Messages will be delivered when app is closed'
                            : 'Stopped - Messages only delivered when app is open'
                    ),
                    value: isRunning,
                    activeColor: Colors.green,
                    onChanged: (value) {
                      // Use separate methods to avoid async gaps
                      if (value) {
                        _startBackgroundService();
                      } else {
                        _stopBackgroundService();
                      }

                      // Update UI immediately
                      setState(() {});
                    },
                  );
                }
            ),

            const SizedBox(height: 12),

            // Pending Messages Info
            StreamBuilder<List<BleMessage>>(
                stream: _bleService.messages,
                builder: (context, snapshot) {
                  final messages = snapshot.data ?? [];
                  final pendingCount = messages.where((m) =>
                  m.status != MessageStatus.delivered &&
                      m.status != MessageStatus.ack
                  ).length;

                  return pendingCount > 0
                      ? Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amber[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('$pendingCount pending ${pendingCount == 1 ? "message" : "messages"}'),
                              const Text(
                                'Messages will be delivered when recipients are in range',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: _retryPendingMessages,
                          child: const Text('Retry Now'),
                        ),
                      ],
                    ),
                  )
                      : Container();
                }
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBleMetricsCard() {
    return Card(
      color: Colors.blue[50],
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'BLE Metrics',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            ListTile(
              title: const Text('Bluetooth Metrics'),
              subtitle: const Text('View detailed BLE operation metrics'),
              onTap: () {
                final metrics = _bleService.errorMetrics.getMetrics();
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('BLE Metrics'),
                    content: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Connection Failures: ${metrics['connectionFailures']}'),
                          Text('Service Discovery Failures: ${metrics['serviceDiscoveryFailures']}'),
                          Text('Write Failures: ${metrics['writeFailures']}'),
                          Text('Read Failures: ${metrics['readFailures']}'),
                          Text('Scan Failures: ${metrics['scanFailures']}'),
                          const SizedBox(height: 16),
                          const Text('Device Specific Failures:', style: TextStyle(fontWeight: FontWeight.bold)),
                          ...(metrics['deviceSpecificFailures'] as Map<String, dynamic>).entries.map((e) =>
                              Text('${e.key}: ${e.value} failures')
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      TextButton(
                        onPressed: () {
                          _bleService.errorMetrics.reset();
                          Navigator.pop(context);
                        },
                        child: const Text('Reset Metrics'),
                      ),
                    ],
                  ),
                );
              },
            ),

            // Message Queue Health
            ListTile(
              title: const Text('Message Queue Health'),
              subtitle: const Text('View message delivery statistics'),
              onTap: () {
                final metrics = _bleService.messageQueueHealth.getMetrics();
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Message Queue Metrics'),
                    content: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Total Messages Sent: ${metrics['totalMessagesSent']}'),
                          Text('Successful Deliveries: ${metrics['successfulDeliveries']}'),
                          Text('Failed Deliveries: ${metrics['failedDeliveries']}'),
                          Text('Pending Messages: ${metrics['pendingMessages']}'),
                          Text('Success Rate: ${metrics['successRate']}'),
                          Text('Average Delivery Time: ${metrics['averageDeliveryTime']}'),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startBleService() async {
    await _bleService.initialize();
    await _bleService.startAdvertising();
    await _bleService.startScan();
  }

  Future<void> _stopBleService() async {
    // First stop all BLE operations
    await _bleService.stopScan();
    await _bleService.stopAdvertising();

    // Then check if we're still mounted before showing a dialog
    if (!mounted) return;

    // Show warning dialog
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Service Disabled'),
        content: const Text(
            'Warning: Without the BLE service, you cannot send or receive messages. '
                'Enable it again when you want to communicate.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _startBackgroundService() async {
    await _bleService.startBackgroundService();
    // No UI updates needed here as setState is called in the parent method
  }

  Future<void> _stopBackgroundService() async {
    // First stop the background service
    await _bleService.stopBackgroundService();

    // Then check if we're still mounted before showing a dialog
    if (!mounted) return;

    // Show warning dialog
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Background Service Disabled'),
        content: const Text(
            'Warning: Without the background service, messages will only be '
                'delivered when the app is open.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _retryPendingMessages() {
    _bleService.retryAllPendingMessages();
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
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('About'),
          subtitle: const Text('App version and information'),
          onTap: () {
            _showAboutDialog();
          },
        ),
      ],
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AboutDialog(
        applicationName: 'PakConnect',
        applicationVersion: '1.0.0',
        applicationIcon: Image.asset('assets/logo.png', width: 48, height: 48),
        applicationLegalese: '© 2025 PakConnect Team',
        children: [
          const SizedBox(height: 16),
          const Text(
            'PakConnect is a Bluetooth Low Energy (BLE) based messaging app designed to work without internet connectivity.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Device ID: ',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          SelectableText(
            _bleService.deviceId,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          const SizedBox(height: 16),
          _buildProfileCard(),
          _buildServiceStatusCard(),
          _buildBleMetricsCard(),
          const Divider(thickness: 1),
          _buildSettingsList(),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    super.dispose();
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

// -----------------------------------------------------------------------------
//
/// QR code scanner screen for adding contacts
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController controller = MobileScannerController(
    // Set to normal detection speed for better battery performance
    detectionSpeed: DetectionSpeed.normal,
    // Enable device's torch if needed
    torchEnabled: false,
    // Enable auto zoom feature for better UX
    autoZoom: true,
    // Only scan QR codes
    formats: [BarcodeFormat.qrCode],
  );

  bool _processing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Contact QR Code'),
        actions: [
          // Flashlight control button
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: controller,
            builder: (context, state, _) {
              // Only show if torch is available
              if (state.torchState == TorchState.unavailable) {
                return const SizedBox.shrink();
              }

              return IconButton(
                icon: Icon(
                  state.torchState == TorchState.on
                      ? Icons.flash_on
                      : Icons.flash_off,
                ),
                onPressed: () => controller.toggleTorch(),
              );
            },
          ),

          // Camera switching button
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: controller,
            builder: (context, state, _) {
              // Only show if multiple cameras available
              if (state.availableCameras == null ||
                  state.availableCameras! < 2) {
                return const SizedBox.shrink();
              }

              return IconButton(
                icon: Icon(
                  state.cameraDirection == CameraFacing.front
                      ? Icons.camera_front
                      : Icons.camera_rear,
                ),
                onPressed: () => controller.switchCamera(),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: controller,
              fit: BoxFit.contain,
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error, color: Colors.red, size: 32),
                    SizedBox(height: 16),
                    Text(
                      'Scanner error: ${error.errorDetails?.message ?? error.errorCode.name}',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              // Add a custom overlay with scanning indicator
              overlayBuilder: (context, constraints) {
                return Stack(
                  children: [
                    // Dimmed background
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(),
                      ),
                    ),
                    // Centered scan area
                    Center(
                      child: Container(
                        width: constraints.maxWidth * 0.8,
                        height: constraints.maxWidth * 0.8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white,
                            width: 2.0,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.transparent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Instructions text at bottom
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text(
                          'Position the QR code within the frame to scan',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    if (_processing) return;
    _processing = true;

    try {
      // Get detected barcodes
      final List<Barcode> barcodes = capture.barcodes;

      // Find first valid QR code
      for (final barcode in barcodes) {
        final qrContent = barcode.rawValue;
        if (qrContent != null && qrContent.isNotEmpty) {
          _processQrCode(qrContent);
          break;
        }
      }
    } finally {
      // Reset processing flag after a delay to prevent multiple scans
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _processing = false;
        }
      });
    }
  }

  void _processQrCode(String data) {
    try {
      final contactData = jsonDecode(data) as Map<String, dynamic>;

      // Validate required fields
      if (!contactData.containsKey('username') ||
          !contactData.containsKey('displayName') ||
          !contactData.containsKey('deviceId')) {
        _showError('Invalid QR code format');
        return;
      }

      // Create contact from QR data
      final newContact = Contact(
        username: contactData['username'],
        displayName: contactData['displayName'],
        bleDeviceId: contactData['deviceId'],
      );

      // Use the new method for Contact objects
      final success = InMemoryStore.addContactObject(newContact);

      if (success) {
        // Return to previous screen with the new contact
        Navigator.pop(context, newContact);

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added ${newContact.displayName} to contacts!')),
        );
      } else {
        _showError('Contact already exists');
      }
    } catch (e) {
      _showError('Error processing QR code: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}