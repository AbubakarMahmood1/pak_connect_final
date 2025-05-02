import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:math' as math;


import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../main.dart';

/// Enum to represent different scan power modes
enum ScanMode {
  lowPower,    // Least frequent scanning, highest latency, lowest power consumption
  balanced,    // Moderate frequency scanning, medium latency, moderate power consumption
  lowLatency   // Most frequent scanning, lowest latency, highest power consumption
}

/// enum for battery state tracking
enum DeviceBatteryState {
  unknown,
  full,
  low,
  critical,
  charging
}

enum DeviceConnectionState {
  disconnected,
  connecting,
  connected
}

/// Message status enum for better tracking of message lifecycle
enum MessageStatus {
  created,    // Message created but not yet attempted to send
  pending,    // Message is in queue for sending
  sending,    // Message is currently being sent
  delivered,  // Message was successfully delivered
  failed,     // Message failed to deliver
  ack         // Message was acknowledged by recipient
}

/// Message class with improved tracking and metadata
class BleMessage {
  final String id;
  final String senderId;
  final String recipientId;
  final String content;
  final DateTime timestamp;
  final MessageStatus status;
  final int attemptCount;
  final DateTime? lastAttempt;
  final List<String> relayPath; // For mesh routing
  final int ttl; // Time-to-live for mesh routing
  final Map<String, dynamic>? metadata; // For extension

  BleMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.timestamp,
    this.status = MessageStatus.created,
    this.attemptCount = 0,
    this.lastAttempt,
    this.relayPath = const [],
    this.ttl = 5, // Default TTL of 5 hops
    this.metadata,
  });

  factory BleMessage.fromJson(Map<String, dynamic> json) {
    return BleMessage(
      id: json['id'],
      senderId: json['senderId'],
      recipientId: json['recipientId'],
      content: json['content'],
      timestamp: DateTime.parse(json['timestamp']),
      status: MessageStatus.values.firstWhere(
              (e) => e.toString() == json['status'],
          orElse: () => MessageStatus.created),
      attemptCount: json['attemptCount'] ?? 0,
      lastAttempt: json['lastAttempt'] != null
          ? DateTime.parse(json['lastAttempt'])
          : null,
      relayPath: (json['relayPath'] as List<dynamic>?)?.cast<String>() ?? [],
      ttl: json['ttl'] ?? 5,
      metadata: json['metadata'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'recipientId': recipientId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'status': status.toString(),
      'attemptCount': attemptCount,
      'lastAttempt': lastAttempt?.toIso8601String(),
      'relayPath': relayPath,
      'ttl': ttl,
      'metadata': metadata,
    };
  }

  BleMessage copyWith({
    String? id,
    String? senderId,
    String? recipientId,
    String? content,
    DateTime? timestamp,
    MessageStatus? status,
    int? attemptCount,
    DateTime? lastAttempt,
    List<String>? relayPath,
    int? ttl,
    Map<String, dynamic>? metadata,
  }) {
    return BleMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      lastAttempt: lastAttempt ?? this.lastAttempt,
      relayPath: relayPath ?? this.relayPath,
      ttl: ttl ?? this.ttl,
      metadata: metadata ?? this.metadata,
    );
  }

  // Check if message is eligible for retry
  bool get canRetry => status == MessageStatus.failed ||
      status == MessageStatus.sending ||
      status == MessageStatus.pending;

  // Check if message was sent too recently to retry
  bool get isRecentFailure {
    if (lastAttempt == null) return false;
    return DateTime.now().difference(lastAttempt!).inSeconds <
        math.min(30 * attemptCount, 300); // Exponential backoff, max 5 min
  }
}

/// Device class with improved connection management and status tracking
class BleDevice {
  final Peripheral peripheral;
  final String? name;
  final int rssi;
  final ConnectionState connectionState;
  final DeviceConnectionState deviceConnectionState;
  final DateTime lastSeen;
  final bool supportsRelay; // For mesh networking
  final DateTime? lastConnected;
  final int failedConnectionAttempts;
  final int? mtu;

  BleDevice({
    required this.peripheral,
    this.name,
    required this.rssi,
    this.connectionState = ConnectionState.disconnected,
    DeviceConnectionState? deviceConnectionState,
    required this.lastSeen,
    this.supportsRelay = false,
    this.lastConnected,
    this.failedConnectionAttempts = 0,
    this.mtu,
  }) : deviceConnectionState = deviceConnectionState ??
      (connectionState == ConnectionState.connected ?
      DeviceConnectionState.connected : DeviceConnectionState.disconnected);

  factory BleDevice.fromPeripheral(
      Peripheral peripheral,
      int rssi,
      Advertisement advertisement,
      ) {
    // Check for relay capability in advertisement data
    bool relay = false;
    for (var mfgData in advertisement.manufacturerSpecificData) {
      if (mfgData.id == 0x01 && mfgData.data.length > 1) {
        // Check first byte for relay capability flag (0x01)
        relay = mfgData.data[0] == 0x01;
        break;
      }
    }

    return BleDevice(
      peripheral: peripheral,
      name: advertisement.name,
      rssi: rssi,
      lastSeen: DateTime.now(),
      supportsRelay: relay,
    );
  }

  BleDevice copyWith({
    Peripheral? peripheral,
    String? name,
    int? rssi,
    ConnectionState? connectionState,
    DeviceConnectionState? deviceConnectionState,
    DateTime? lastSeen,
    bool? supportsRelay,
    DateTime? lastConnected,
    int? failedConnectionAttempts,
    int? mtu,
  }) {
    return BleDevice(
      peripheral: peripheral ?? this.peripheral,
      name: name ?? this.name,
      rssi: rssi ?? this.rssi,
      connectionState: connectionState ?? this.connectionState,
      deviceConnectionState: deviceConnectionState ?? this.deviceConnectionState,
      lastSeen: lastSeen ?? this.lastSeen,
      supportsRelay: supportsRelay ?? this.supportsRelay,
      lastConnected: lastConnected ?? this.lastConnected,
      failedConnectionAttempts:
      failedConnectionAttempts ?? this.failedConnectionAttempts,
      mtu: mtu ?? this.mtu,
    );
  }

  String get id => peripheral.uuid.toString();

  bool get isConnected => deviceConnectionState == DeviceConnectionState.connected;

  // Determine if device is eligible for connection attempt
  bool get canConnect {
    // Don't try to connect if we've had too many recent failures
    if (failedConnectionAttempts > 5) {
      final cooldownPeriod = Duration(minutes: failedConnectionAttempts);
      if (lastConnected != null &&
          DateTime.now().difference(lastConnected!) < cooldownPeriod) {
        return false;
      }
    }
    return true;
  }

  // Calculate connection priority (higher is better)
  int get connectionPriority {
    int priority = 0;

    // Better signal strength improves priority
    priority += math.max(0, (rssi + 100));

    // Recently seen devices get higher priority
    final freshness = DateTime.now().difference(lastSeen).inSeconds;
    priority += math.max(0, 300 - freshness);

    // Penalize devices that frequently fail connection
    priority -= (failedConnectionAttempts * 50);

    // Bonus for devices that can relay messages
    if (supportsRelay) priority += 200;

    return priority;
  }
}

/// A class to represent a connection request
class _ConnectionRequest {
  final Peripheral peripheral;
  final int priority;
  final DateTime timestamp;
  final Future<bool> Function(Peripheral) connectFunc;

  _ConnectionRequest({
    required this.peripheral,
    required this.priority,
    required this.timestamp,
    required this.connectFunc,
  });
}

/// Connection pool to manage concurrent connections efficiently
class ConnectionPool {
  // Maximum number of concurrent connections
  static const int maxConcurrentConnections = 5;

  // Currently active connections
  final List<String> _activeConnections = [];

  // Connection queue
  final List<_ConnectionRequest> _pendingConnections = [];

  // Add a connection request with priority
  void queueConnection(Peripheral peripheral, int priority,
      Future<bool> Function(Peripheral) connectFunc) {
    final peripheralId = peripheral.uuid.toString();

    // Check if already connected or queued
    if (_activeConnections.contains(peripheralId) ||
        _pendingConnections.any((req) => req.peripheral.uuid.toString() == peripheralId)) {
      return;
    }

    final request = _ConnectionRequest(
      peripheral: peripheral,
      priority: priority,
      timestamp: DateTime.now(),
      connectFunc: connectFunc,
    );

    _pendingConnections.add(request);
    // Sort by priority (highest first)
    _pendingConnections.sort((a, b) => b.priority.compareTo(a.priority));

    // Process queue if we have capacity
    _processQueue();
  }

  // Process connection queue
  Future<void> _processQueue() async {
    while (_activeConnections.length < maxConcurrentConnections &&
        _pendingConnections.isNotEmpty) {
      final request = _pendingConnections.removeAt(0);
      final peripheralId = request.peripheral.uuid.toString();
      _activeConnections.add(peripheralId);

      // Execute connection
      request.connectFunc(request.peripheral).then((connected) {
        if (!connected) {
          _activeConnections.remove(peripheralId);
          _processQueue();
        }
      }).catchError((e) {
        _activeConnections.remove(peripheralId);
        _processQueue();
      });
    }
  }

  // Mark connection completed or failed
  void connectionCompleted(Peripheral peripheral) {
    final peripheralId = peripheral.uuid.toString();
    _activeConnections.remove(peripheralId);
    _processQueue();
  }

  // Check if a device is actively connecting
  bool isActivelyConnecting(String peripheralId) {
    return _activeConnections.contains(peripheralId);
  }

  // Check if we have capacity for new connections
  bool hasCapacity() {
    return _activeConnections.length < maxConcurrentConnections;
  }

  // Get number of pending connections
  int get pendingConnectionCount => _pendingConnections.length;

  // Get number of active connections
  int get activeConnectionCount => _activeConnections.length;
}

/// Service recovery state for error handling
enum ServiceRecoveryState {
  normal,
  recovering,
  failed
}

/// Manager for handling errors and service recovery
class ErrorRecoveryManager {
  ServiceRecoveryState _recoveryState = ServiceRecoveryState.normal;
  int _consecutiveErrors = 0;
  Timer? _recoveryTimer;

  // Reference to BLE service for recovery operations
  final BleService _service;

  ErrorRecoveryManager(this._service);

  // Current recovery state
  ServiceRecoveryState get state => _recoveryState;

  // Handle error with increasing backoff
  Future<void> handleError(String operation, dynamic error) async {
    _consecutiveErrors++;

    debugPrint('BLE error ($_consecutiveErrors) in $operation: $error');

    if (_recoveryState == ServiceRecoveryState.normal) {
      if (_consecutiveErrors > 3) {
        // Too many errors, enter recovery mode
        _recoveryState = ServiceRecoveryState.recovering;
        _startRecovery();
      }
    }
  }

  // Reset error count on successful operation
  void operationSucceeded() {
    if (_consecutiveErrors > 0) {
      _consecutiveErrors = math.max(0, _consecutiveErrors - 1);
    }

    if (_recoveryState == ServiceRecoveryState.recovering && _consecutiveErrors < 2) {
      _recoveryState = ServiceRecoveryState.normal;
      _recoveryTimer?.cancel();
    }
  }

  // Start recovery process
  Future<void> _startRecovery() async {
    _recoveryTimer?.cancel();

    // Calculate backoff time based on consecutive errors (exponential with cap)
    final backoffSeconds = math.min(120, math.pow(2, math.min(6, _consecutiveErrors)).toInt());

    debugPrint('Starting BLE recovery in $backoffSeconds seconds');

    _recoveryTimer = Timer(Duration(seconds: backoffSeconds), () async {
      await _resetBluetoothState();

      // If still failing after multiple attempts, enter failed state
      if (_consecutiveErrors > 10) {
        _recoveryState = ServiceRecoveryState.failed;
        debugPrint('Bluetooth recovery failed after multiple attempts');
      }
    });
  }

  // Reset Bluetooth state
  Future<void> _resetBluetoothState() async {
    debugPrint('Attempting Bluetooth state reset');

    try {
      // Stop all operations
      await _service.stopScan();
      await _service.stopAdvertising();

      // Disconnect all devices
      final connectedDevices = _service._discoveredDevices
          .where((d) => d.isConnected)
          .toList();

      for (final device in connectedDevices) {
        try {
          await _service._centralManager.disconnect(device.peripheral);
        } catch (_) {
          // Ignore errors during cleanup
        }
      }

      // Wait a moment
      await Future.delayed(const Duration(seconds: 2));

      // Restart core functionality
      await _service.startAdvertising();

      // Re-process pending messages
      await _service._processOutgoingMessages();

      // If recovery succeeded, reduce error count
      _consecutiveErrors = math.max(0, _consecutiveErrors - 2);

      if (_consecutiveErrors < 3) {
        _recoveryState = ServiceRecoveryState.normal;
      }
    } catch (e) {
      _consecutiveErrors++;
      debugPrint('Recovery failed: $e');
    }
  }
}

class BleService {
  // Singleton instance
  static final BleService _instance = BleService._internal();
  // Factory constructor for main app usage - take the already initialized service
  factory BleService([FlutterBackgroundService? service]) {
    if (service != null) {
      _instance._backgroundService = service;
    } else {
      // Use the global backgroundService if available, otherwise it will be set later
      try {
        // If we're in the context of the main app, use the globally defined instance
        _instance._backgroundService = backgroundService;
      } catch (e) {
        // This will happen during initialization if backgroundService isn't set yet
        // The service will be provided later when initialize() is called
        debugPrint('Warning: BleService created without explicit background service reference');
      }
    }
    return _instance;
  }

  // Factory for background service usage
  factory BleService.backgroundInstance(ServiceInstance service) {
    _instance._serviceInstance = service;
    return _instance;
  }

  BleService._internal() {
    _errorRecoveryManager = ErrorRecoveryManager(this);
  }

  // Constants for service/characteristic UUIDs
  static const String serviceUuid = "5f7bc8be-e3c2-4c78-8abd-ab2ad5b8f55e";
  static const String messageCharacteristicUuid = "23ba23c7-4bae-4b7b-a0e3-d9577342501e";
  static const String deviceInfoCharacteristicUuid = "9c0e63a7-843d-4c1b-b8c6-7a9b472e39a2";
  static const String ackCharacteristicUuid = "6e7d5cd8-b36f-4f54-8282-b5e2a98e2d93";

  // Protocol version
  static const int protocolVersion = 1;

  // Max packet size for BLE transmission
  static const int maxPacketSize = 512; // Most BLE implementations limit MTU

  // Constants for adaptive scanning
  static const Duration minScanInterval = Duration(minutes: 2);
  static const Duration maxScanInterval = Duration(minutes: 30);
  static const Duration activeScanDuration = Duration(seconds: 20);

  // Retry constants
  static const int maxRetryAttempts = 10;
  static const Duration initialRetryDelay = Duration(seconds: 5);

  // Status and management fields
  late final String _deviceId;
  final _stateLock = Lock();
  late final ErrorRecoveryManager _errorRecoveryManager;
  bool _isInitialized = false;
  bool _isScanning = false;
  bool _isAdvertising = false;
  DateTime _lastMessageActivity = DateTime.now();

  // Managers
  final CentralManager _centralManager = CentralManager();
  final PeripheralManager _peripheralManager = PeripheralManager();
  final ConnectionPool _connectionPool = ConnectionPool();


  // Stream controllers with better error handling
  final _devicesSubject = BehaviorSubject<List<BleDevice>>.seeded([]);
  final _messagesSubject = BehaviorSubject<List<BleMessage>>.seeded([]);
  final _connectionStateSubject = BehaviorSubject<String>.seeded('Not Initialized');
  final _errorSubject = PublishSubject<String>();

  late FlutterBackgroundService _backgroundService;
  ServiceInstance? _serviceInstance;

  // Storage
  List<BleDevice> _discoveredDevices = [];
  List<BleMessage> _messages = [];
  final Map<String, StreamSubscription> _subscriptions = {};
  final Map<String, GATTService?> _deviceGattServices = {};

  // Message packet tracking for fragmented messages
  final Map<String, List<Map<String, dynamic>>> _incomingPackets = {};
  final Map<String, Completer<bool>> _outgoingMessageCompleters = {};

  // Adaptive scanning parameters
  Timer? _adaptiveScanTimer;
  Timer? _messageProcessingTimer;
  Timer? _deviceUpdateDebouncer;

  // Stream getters
  Stream<List<BleDevice>> get devices => _devicesSubject.stream;
  Stream<List<BleMessage>> get messages => _messagesSubject.stream;
  Stream<String> get connectionState => _connectionStateSubject.stream;
  Stream<String> get errors => _errorSubject.stream;

  // Public getters
  bool get isInitialized => _isInitialized;
  bool get isScanning => _isScanning;
  bool get isAdvertising => _isAdvertising;
  String get deviceId => _deviceId;
  DateTime get lastMessageActivityTime => _lastMessageActivity;

  // BLE characteristics
  GATTCharacteristic? _ackCharacteristic;
  bool _pendingDeviceListUpdate = false;

  /// Initialize the BLE service with robust error handling
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _connectionStateSubject.add('Initializing...');

      // Generate or retrieve device ID
      final prefs = await SharedPreferences.getInstance();
      _deviceId = prefs.getString('device_id') ??
          _generateSecureDeviceId();
      await prefs.setString('device_id', _deviceId);

      // Set up BLE listeners with error handling
      _setupCentralListeners();
      _setupPeripheralListeners();

      // Wait for poweredOn state with timeout
      final bluetoothReady = await _waitForBluetoothPoweredOn();
      if (!bluetoothReady) {
        _connectionStateSubject.add('Bluetooth not available or timeout');
        return false;
      }

      // Load cached messages
      await _loadMessages();

      // Start message processing timer
      _startMessageProcessingTimer();

      // Start adaptive scanning
      _setupAdaptiveScanning();

      _isInitialized = true;
      _connectionStateSubject.add('Ready');

      // Start background tasks
      await startAdvertising();

      return true;
    } catch (e) {
      final errorMsg = 'Initialization error: $e';
      _connectionStateSubject.add(errorMsg);
      _errorSubject.add(errorMsg);
      return false;
    }
  }

  /// Handle iOS background processing
  Future<bool> handleIosBackground() async {
    try {
      // Process any pending messages
      await _processOutgoingMessages();
      return true;
    } catch (e) {
      debugPrint('iOS background handling error: $e');
      return false;
    }
  }

  /// Generate a secure device ID
  String _generateSecureDeviceId() {
    final random = math.Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Wait for Bluetooth to be powered on
  Future<bool> _waitForBluetoothPoweredOn() async {
    if (_centralManager.state == BluetoothLowEnergyState.poweredOn) {
      return true;
    }

    final completer = Completer<bool>();
    late StreamSubscription subscription;

    subscription = _centralManager.stateChanged.listen((event) {
      if (event.state == BluetoothLowEnergyState.poweredOn) {
        completer.complete(true);
        subscription.cancel();
      } else if (event.state == BluetoothLowEnergyState.unsupported ||
          event.state == BluetoothLowEnergyState.unauthorized) {
        completer.complete(false);
        subscription.cancel();
      }
    });

    // Return result or timeout after 10 seconds
    return await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        subscription.cancel();
        _errorSubject.add('Bluetooth initialization timeout');
        return false;
      },
    );
  }

  Duration getAdaptiveScanInterval() {
    return _getAdaptiveScanInterval();
  }

  // Public method for pending message checks
  bool hasPendingMessages() {
    return _countPendingMessages() > 0;
  }

  // Public method for pending message count
  int getPendingMessageCount() {
    return _countPendingMessages();
  }

  // Public version of process outgoing messages
  Future<void> processOutgoingMessages() async {
    return _processOutgoingMessages();
  }

  /// Periodically clean up device cache to prevent memory bloat
  Future<void> _cleanupDeviceCache() async {
    return _stateLock.synchronized(() async {
      final now = DateTime.now();

      // Remove devices not seen in the last 30 minutes (unless connected)
      _discoveredDevices.removeWhere((d) =>
      now.difference(d.lastSeen).inMinutes > 30 && !d.isConnected);

      // Cap maximum number of cached devices
      if (_discoveredDevices.length > 100) {
        // Sort by connection priority (highest first)
        _discoveredDevices.sort((a, b) => b.connectionPriority.compareTo(a.connectionPriority));
        _discoveredDevices = _discoveredDevices.take(100).toList();
      }

      _devicesSubject.add(_discoveredDevices);
    });
  }

  /// Setup adaptive scanning based on message activity
  void _setupAdaptiveScanning() {
    _adaptiveScanTimer?.cancel();
    _adaptiveScanTimer = Timer.periodic(_getAdaptiveScanInterval(), (_) async {
      await _cleanupDeviceCache();
      _cleanupFragmentedMessages();
      _cleanupMessageCompleter();

      if (!_isScanning) {
        await startScan(maxDuration: activeScanDuration);
      }
    });

    // Add periodic cache cleanup even between scans
    Timer.periodic(Duration(minutes: 5), (_) async {
      await _cleanupDeviceCache();
    });
  }

  /// Clean up stale fragmented messages
  void _cleanupFragmentedMessages() {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _incomingPackets.forEach((messageId, fragments) {
      // Add timestamp to fragments for tracking
      if (fragments.isNotEmpty && !fragments[0].containsKey('receivedAt')) {
        fragments[0]['receivedAt'] = now;
      }

      // Check reception time of first fragment
      if (fragments.isNotEmpty && fragments[0].containsKey('receivedAt')) {
        final timestamp = fragments[0]['receivedAt'] as DateTime;
        // Remove fragments older than 5 minutes
        if (now.difference(timestamp).inMinutes > 5) {
          keysToRemove.add(messageId);
        }
      }
    });

    for (final key in keysToRemove) {
      _incomingPackets.remove(key);
    }
  }

  /// Clean up stale message completer
  void _cleanupMessageCompleter() {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _outgoingMessageCompleters.forEach((messageId, completer) {
      // Find the message
      final messageIndex = _messages.indexWhere((m) => m.id == messageId);
      if (messageIndex < 0) {
        // Message doesn't exist anymore
        if (!completer.isCompleted) {
          completer.complete(false);
        }
        keysToRemove.add(messageId);
      } else {
        final message = _messages[messageIndex];
        // If message is very old and still pending, consider it failed
        if (now.difference(message.timestamp).inMinutes > 30 &&
            message.status != MessageStatus.delivered &&
            message.status != MessageStatus.ack) {
          if (!completer.isCompleted) {
            completer.complete(false);
          }
          keysToRemove.add(messageId);
        }
      }
    });

    for (final key in keysToRemove) {
      _outgoingMessageCompleters.remove(key);
    }
  }

  /// Calculate adaptive scan interval based on recent activity
  Duration _getAdaptiveScanInterval() {
    final timeSinceActivity =
        DateTime.now().difference(_lastMessageActivity).inMinutes;

    // More frequent scanning if recent activity
    if (timeSinceActivity < 15) {
      return minScanInterval;
    }
    // Moderate scanning if semi-recent activity
    else if (timeSinceActivity < 60) {
      return Duration(minutes: 10);
    }
    // Less frequent scanning if inactive for 1-3 hours
    else if (timeSinceActivity < 180) {
      return Duration(minutes: 20);
    }
    // Minimal scanning for battery saving if very inactive
    else {
      return maxScanInterval;
    }
  }

  /// Start timer for periodic message processing
  void _startMessageProcessingTimer() {
    _messageProcessingTimer?.cancel();
    _messageProcessingTimer = Timer.periodic(
      const Duration(seconds: 30),
          (_) => _processOutgoingMessages(),
    );
  }

  /// Set up central manager listeners with error handling
  void _setupCentralListeners() {
    // Discovered device
    _subscriptions['discovered'] = _centralManager.discovered.listen(
          (event) {
        _handleDiscoveredDevice(event);
      },
      onError: (error) {
        _errorSubject.add('Discovery error: $error');
      },
    );

    // Connection state changed
    _subscriptions['connectionStateChanged'] =
        _centralManager.connectionStateChanged.listen(
              (event) {
            _handleConnectionStateChanged(event);
          },
          onError: (error) {
            _errorSubject.add('Connection state error: $error');
          },
        );

    // Characteristic notification
    _subscriptions['characteristicNotified'] =
        _centralManager.characteristicNotified.listen(
              (event) {
            // Process incoming message
            if (_isServiceCharacteristic(event.characteristic, messageCharacteristicUuid)) {
              _processIncomingMessage(event.peripheral, event.value);
            }
            // Process acknowledgment
            else if (_isServiceCharacteristic(event.characteristic, ackCharacteristicUuid)) {
              _processAcknowledgment(event.peripheral, event.value);
            }
          },
          onError: (error) {
            _errorSubject.add('Notification error: $error');
          },
        );
  }

  /// Handle discovered device event
  void _handleDiscoveredDevice(DiscoveredEventArgs event) {
    _stateLock.synchronized(() async {
      // Process device discovery on a separate isolate
      final deviceProcessResult = await compute((args) {
        final peripheral = args[0] as Peripheral;
        final rssi = args[1] as int;
        final advertisement = args[2] as Advertisement;
        final devicesList = args[3] as List<BleDevice>;

        final device = BleDevice.fromPeripheral(
          peripheral,
          rssi,
          advertisement,
        );

        // Find existing device
        final index = devicesList.indexWhere(
                (d) => d.peripheral.uuid == device.peripheral.uuid
        );

        bool deviceListChanged = false;

        if (index >= 0) {
          devicesList[index] = devicesList[index].copyWith(
            rssi: device.rssi,
            name: device.name ?? devicesList[index].name,
            lastSeen: DateTime.now(),
            supportsRelay: device.supportsRelay,
          );
          deviceListChanged = true;
        } else {
          devicesList.add(device);
          deviceListChanged = true;
        }

        // Return processed data
        return {
          'device': device,
          'devicesList': devicesList,
          'deviceListChanged': deviceListChanged
        };
      }, [event.peripheral, event.rssi, event.advertisement, _discoveredDevices]);

      // Update with processed data
      final device = deviceProcessResult['device'] as BleDevice;
      _discoveredDevices = deviceProcessResult['devicesList'] as List<BleDevice>;
      final deviceListChanged = deviceProcessResult['deviceListChanged'] as bool;

      // Rest of the method stays the same
      if (deviceListChanged) {
        _pendingDeviceListUpdate = true;
      }

      _deviceUpdateDebouncer?.cancel();
      _deviceUpdateDebouncer = Timer(const Duration(milliseconds: 100), () {
        if (_pendingDeviceListUpdate) {
          _devicesSubject.add(_discoveredDevices);
          _pendingDeviceListUpdate = false;
        }
      });

      if (_shouldConnectToDevice(device.peripheral.uuid.toString())) {
        _connectToDevice(device.peripheral);
      }
    });
  }

  /// Determine if we should connect to a device with better prioritization
  bool _shouldConnectToDevice(String deviceId) {
    // Find the device
    final deviceIndex = _discoveredDevices.indexWhere((d) => d.id == deviceId);
    if (deviceIndex < 0) return false;

    final device = _discoveredDevices[deviceIndex];

    // Don't connect if in cooldown or already actively connecting
    if (!device.canConnect || _connectionPool.isActivelyConnecting(deviceId)) {
      return false;
    }

    // Don't connect if we have too many active connections and this isn't high priority
    if (!_connectionPool.hasCapacity() && device.connectionPriority < 300) {
      return false;
    }

    // Check if we have direct messages for this device
    final hasDirectMessages = _messages.any((m) =>
    m.canRetry &&
        m.senderId == _deviceId &&
        m.recipientId == deviceId
    );

    if (hasDirectMessages) return true;

    // Check if we have relay messages that could use this device
    final hasRelayMessages = _messages.any((m) =>
    m.canRetry &&
        m.senderId == _deviceId &&
        m.ttl > 0 &&
        !m.relayPath.contains(deviceId) // Don't re-use the same relay
    );

    // Find if this device can relay and has good signal quality
    if (device.supportsRelay && device.rssi > -80 && hasRelayMessages) {
      return true;
    }

    return false;
  }

  /// Handle connection state changed event
  void _handleConnectionStateChanged(PeripheralConnectionStateChangedEventArgs event) async {
    final index = _discoveredDevices.indexWhere(
            (d) => d.peripheral.uuid == event.peripheral.uuid
    );

    if (index >= 0) {
      // Update connection state and analytics
      final now = DateTime.now();
      final currentDevice = _discoveredDevices[index];
      final peripheralId = event.peripheral.uuid.toString();

      // When the device connects, mark it as connecting until services are discovered
      final newDeviceConnectionState = event.state == ConnectionState.connected ?
      DeviceConnectionState.connecting :
      DeviceConnectionState.disconnected;

      // Update device state
      _discoveredDevices[index] = currentDevice.copyWith(
        connectionState: event.state,
        deviceConnectionState: newDeviceConnectionState,
        lastConnected: event.state == ConnectionState.connected ? now : currentDevice.lastConnected,
        failedConnectionAttempts: event.state == ConnectionState.connected
            ? 0  // Reset counter on successful connection
            : event.state == ConnectionState.disconnected
            ? currentDevice.failedConnectionAttempts + 1
            : currentDevice.failedConnectionAttempts,
      );

      _devicesSubject.add(_discoveredDevices);

      // If connected, discover services
      if (event.state == ConnectionState.connected) {
        try {
          await _discoverServices(event.peripheral);

          // Now update to fully connected state after services discovered
          final updatedIndex = _discoveredDevices.indexWhere(
                  (d) => d.peripheral.uuid == event.peripheral.uuid
          );

          if (updatedIndex >= 0) {
            _discoveredDevices[updatedIndex] = _discoveredDevices[updatedIndex].copyWith(
                deviceConnectionState: DeviceConnectionState.connected
            );
            _devicesSubject.add(_discoveredDevices);
          }
        } catch (e) {
          // If service discovery fails, mark as disconnected
          final failedIndex = _discoveredDevices.indexWhere(
                  (d) => d.peripheral.uuid == event.peripheral.uuid
          );

          if (failedIndex >= 0) {
            _discoveredDevices[failedIndex] = _discoveredDevices[failedIndex].copyWith(
                connectionState: ConnectionState.disconnected,
                deviceConnectionState: DeviceConnectionState.disconnected,
                failedConnectionAttempts: _discoveredDevices[failedIndex].failedConnectionAttempts + 1
            );
            _devicesSubject.add(_discoveredDevices);
          }

          // Notify connection pool of completed connection
          _connectionPool.connectionCompleted(event.peripheral);
        }
      } else if (event.state == ConnectionState.disconnected) {
        // Device disconnected, clear cached services
        _deviceGattServices.remove(peripheralId);

        // Notify connection pool of completed connection
        _connectionPool.connectionCompleted(event.peripheral);

        // If we have pending messages, schedule a retry
        if (_hasMessagesFor(peripheralId)) {
          _scheduleMessageRetry(peripheralId);
        }
      }
    }
  }

  /// Utility function to get short device name for display
  String getDisplayName(BleDevice device) {
    if (device.name != null && device.name!.isNotEmpty) {
      return device.name!;
    } else {
      // Use last 4 chars of ID for readability
      final id = device.id;
      if (id.length > 4) {
        return "Device-${id.substring(id.length - 4)}";
      } else {
        return "Device-$id";
      }
    }
  }

  /// Get a message preview with appropriate length
  String getMessagePreview(String content, {int maxLength = 50}) {
    if (content.length <= maxLength) {
      return content;
    }
    return "${content.substring(0, maxLength - 3)}...";
  }

  /// Check if the app has been in the background for too long
  Future<bool> _hasBeenInBackgroundTooLong() async {
    final prefs = await SharedPreferences.getInstance();
    final backgroundTimestamp = prefs.getInt('background_timestamp');

    if (backgroundTimestamp == null) {
      return false; // App wasn't properly marked as going to background
    }

    final backgroundTime = DateTime.fromMillisecondsSinceEpoch(backgroundTimestamp);
    final currentTime = DateTime.now();
    final difference = currentTime.difference(backgroundTime);

    // Consider "too long" as more than 30 minutes
    return difference.inMinutes > 30;
  }

  Future<void> saveBackgroundTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('background_timestamp', DateTime.now().millisecondsSinceEpoch);
  }

  /// Restart BLE services after app is foregrounded
  Future<void> handleAppForeground() async {
    // Check if we need to restart services
    if (await _hasBeenInBackgroundTooLong()) {
      // Stop existing operations
      await stopScan();
      await stopAdvertising();

      // Restart services
      await startAdvertising();

      // Process any pending messages
      await _processOutgoingMessages();
    }
  }

  /// Schedule retry for messages to a specific recipient
  void _scheduleMessageRetry(String recipientId) {
    // Find all messages that need to be retried
    final messagesToRetry = _messages.where((m) =>
    m.canRetry &&
        m.senderId == _deviceId &&
        (m.recipientId == recipientId ||
            (m.ttl > 0 && m.relayPath.isNotEmpty && m.relayPath.last == recipientId))
    ).toList();

    if (messagesToRetry.isEmpty) return;

    // Calculate backoff time based on attempt count
    int maxAttempts = messagesToRetry
        .map((m) => m.attemptCount)
        .reduce(math.max);

    // Exponential backoff with jitter
    final baseDelay = initialRetryDelay.inMilliseconds;
    final maxBackoff = math.min(30, math.pow(2, maxAttempts).toInt());
    final jitter = math.Random().nextInt(1000); // Add randomness to prevent thundering herd
    final delayMs = math.min(300000, baseDelay * maxBackoff) + jitter; // Cap at 5 minutes

    // Schedule retry
    Future.delayed(Duration(milliseconds: delayMs), () {
      // Check if we're still interested in retrying
      if (_hasMessagesFor(recipientId)) {
        // Try to reconnect or rescan
        final deviceIndex = _discoveredDevices.indexWhere((d) => d.id == recipientId);
        if (deviceIndex >= 0 && _discoveredDevices[deviceIndex].canConnect) {
          _connectToDevice(_discoveredDevices[deviceIndex].peripheral);
        } else {
          // If we can't find the device, start scanning
          if (!_isScanning) {
            startScan();
          }
        }
      }
    });
  }

  /// Set up peripheral manager listeners
  void _setupPeripheralListeners() {
    // Connection state changed
    _subscriptions['peripheralConnectionStateChanged'] =
        _peripheralManager.connectionStateChanged.listen(
              (event) {
            // Handle central connection state change
            if (event.state == ConnectionState.connected) {
              debugPrint('Central connected: ${event.central.uuid}');
            } else {
              debugPrint('Central disconnected: ${event.central.uuid}');
            }
          },
          onError: (error) {
            _errorSubject.add('Peripheral connection error: $error');
          },
        );

    // Characteristic read requested
    _subscriptions['characteristicReadRequested'] =
        _peripheralManager.characteristicReadRequested.listen(
              (event) async {
            await _handleCharacteristicReadRequest(event);
          },
          onError: (error) {
            _errorSubject.add('Characteristic read error: $error');
          },
        );

    // Characteristic write requested
    _subscriptions['characteristicWriteRequested'] =
        _peripheralManager.characteristicWriteRequested.listen(
              (event) async {
            await _handleCharacteristicWriteRequest(event);
          },
          onError: (error) {
            _errorSubject.add('Characteristic write error: $error');
          },
        );
  }

  /// Handle characteristic read request
  Future<void> _handleCharacteristicReadRequest(
      GATTCharacteristicReadRequestedEventArgs  event) async {
    try {
      if (_isServiceCharacteristic(event.characteristic, deviceInfoCharacteristicUuid)) {
        // Return device info with protocol version
        final deviceInfo = jsonEncode({
          'deviceId': _deviceId,
          'protocolVersion': protocolVersion,
          'timestamp': DateTime.now().toIso8601String(),
          'supportsRelay': true, // Indicate if this device can relay messages
        });

        await _peripheralManager.respondReadRequestWithValue(
          event.request,
          value: Uint8List.fromList(utf8.encode(deviceInfo)),
        );
      } else {
        // Return error for unsupported characteristics
        await _peripheralManager.respondReadRequestWithError(
          event.request,
          error: GATTError.readNotPermitted,
        );
      }
    } catch (e) {
      _errorSubject.add('Read request error: $e');
      await _peripheralManager.respondReadRequestWithError(
        event.request,
        error: GATTError.unlikelyError,
      );
    }
  }

  /// Handle characteristic write request
  Future<void> _handleCharacteristicWriteRequest(
      GATTCharacteristicWriteRequestedEventArgs event) async {
    try {
      if (_isServiceCharacteristic(event.characteristic, messageCharacteristicUuid)) {
        // Process incoming message via peripheral role
        await _processIncomingMessage(
          null,
          event.request.value,
          central: event.central,
        );

        // Respond to the write request
        await _peripheralManager.respondWriteRequest(event.request);
      } else if (_isServiceCharacteristic(event.characteristic, ackCharacteristicUuid)) {
        // Process acknowledgment
        await _processAcknowledgment(null, event.request.value, central: event.central);
        await _peripheralManager.respondWriteRequest(event.request);
      } else {
        // Return error for unsupported characteristics
        await _peripheralManager.respondWriteRequestWithError(
          event.request,
          error: GATTError.writeNotPermitted,
        );
      }
    } catch (e) {
      _errorSubject.add('Write request error: $e');
      await _peripheralManager.respondWriteRequestWithError(
        event.request,
        error: GATTError.unlikelyError,
      );
    }
  }

  /// iOS background handler - needed for iOS background processing
  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    return true;
  }

  /// Count pending messages for display in notification
  int _countPendingMessages() {
    return _messages.where((m) =>
    m.status != MessageStatus.delivered &&
        m.status != MessageStatus.ack).length;
  }

  /// Start the background service if not already running
  Future<bool> startBackgroundService() async {
    try {
      // When running in main app, use the backgroundService reference
      if (_serviceInstance == null) {
        final isRunning = await _backgroundService.isRunning();
        if (!isRunning) {
          await _backgroundService.startService();
        }
        return true;
      }
      // When already running in background, we're already started
      return true;
    } catch (e) {
      _errorSubject.add('Failed to start background service: $e');
      return false;
    }
  }

  /// Check if background service is running
  Future<bool> isBackgroundServiceRunning() async {
    try {
      // When in main app, check the service state
      if (_serviceInstance == null) {
        return await _backgroundService.isRunning();
      }
      // If we have a service instance, we're already running
      return true;
    } catch (e) {
      _errorSubject.add('Failed to check background service state: $e');
      return false;
    }
  }

  /// Update the foreground service notification (Android only)
  Future<void> updateServiceNotification(String title, String content) async {
    try {
      // When in background service, update through the instance
      if (_serviceInstance is AndroidServiceInstance) {
        (_serviceInstance as AndroidServiceInstance).setForegroundNotificationInfo(
          title: title,
          content: content,
        );
      }
      // Otherwise, use the notification service
      else if (_serviceInstance == null) {
        final notificationService = NotificationService();
        await notificationService.initialize();
        await notificationService.updateServiceNotification(title, content);
      }
    } catch (e) {
      _errorSubject.add('Failed to update service notification: $e');
    }
  }

  /// Stop the background service (if needed)
  Future<void> stopBackgroundService() async {
    try {
      // When in main app, stop the service
      if (_serviceInstance == null) {
        final isRunning = await _backgroundService.isRunning();
        if (isRunning) {
          _backgroundService.invoke('stopService');
        }
      }
      // When in background, stop self if needed
      else {
        _serviceInstance?.stopSelf();
      }
    } catch (e) {
      _errorSubject.add('Failed to stop background service: $e');
    }
  }

  /// Get negotiated MTU size for a peripheral
  Future<int> _getNegotiatedMtu(Peripheral peripheral) async {
    try {
      // First check if we already have a cached MTU
      final deviceIndex = _discoveredDevices.indexWhere(
              (d) => d.peripheral.uuid == peripheral.uuid
      );

      // If we have a cached value, use it
      if (deviceIndex >= 0 && _discoveredDevices[deviceIndex].mtu != null) {
        return _discoveredDevices[deviceIndex].mtu!;
      }

      // Otherwise negotiate a new MTU
      int mtu = 23;  // BLE minimum

      if (Platform.isAndroid) {
        final negotiatedMtu = await _centralManager.requestMTU(
            peripheral,
            mtu: 512
        );
        mtu = negotiatedMtu;
      } else if (Platform.isIOS) {
        // iOS has a default around 185
        mtu = 185;
      } else {
        // Handle other platforms or fall back to minimum
        mtu = 23;
      }

      // Cache the MTU value
      if (deviceIndex >= 0) {
        _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
            mtu: mtu
        );
      }

      // Account for ATT overhead (3 bytes) and protocol overhead (~10 bytes)
      return math.max(20, mtu - 13);
    } catch (e) {
      _errorSubject.add('MTU negotiation failed: $e');
      _errorRecoveryManager.handleError('MTU negotiation', e);
      return 20;  // Conservative fallback
    }
  }

  /// Start scanning for BLE devices with error handling
  Future<bool> startScan({
    Duration? maxDuration,
    bool lowPowerMode = false,
  }) async {
    if (!_isInitialized) {
      _connectionStateSubject.add('Not initialized');
      return false;
    }

    if (_isScanning) {
      return true;
    }

    try {
      // Start scanning with appropriate mode
      await _centralManager.startDiscovery(
        serviceUUIDs: [UUID.fromString(serviceUuid)],
      );

      _isScanning = true;
      _connectionStateSubject.add('Scanning');
      _errorRecoveryManager.operationSucceeded();

      // If maxDuration is provided, automatically stop scanning after that duration
      if (maxDuration != null) {
        Future.delayed(maxDuration, () {
          if (_isScanning) {
            stopScan();
          }
        });
      }
      _errorRecoveryManager.operationSucceeded();
      return true;
    } catch (e) {
      final errorMsg = 'Scan error: $e';
      _connectionStateSubject.add(errorMsg);
      _errorSubject.add(errorMsg);
      _errorRecoveryManager.handleError('startScan', e);
      return false;
    }
  }

  /// Stop scanning for BLE devices
  Future<bool> stopScan() async {
    if (!_isScanning) {
      return true;
    }

    try {
      await _centralManager.stopDiscovery();
      _isScanning = false;
      _connectionStateSubject.add('Ready');
      return true;
    } catch (e) {
      final errorMsg = 'Stop scan error: $e';
      _connectionStateSubject.add(errorMsg);
      _errorSubject.add(errorMsg);
      return false;
    }
  }

  /// Start advertising as a peripheral
  Future<bool> startAdvertising() async {
    if (!_isInitialized) {
      _connectionStateSubject.add('Not initialized');
      return false;
    }

    if (_isAdvertising) {
      return true;
    }

    try {
      // Create GATT service structure
      final service = await _createGattService();

      // Add service to peripheral manager
      await _peripheralManager.addService(service);

      // Start advertising with relay capability indication
      final manufacturerData = [
        ManufacturerSpecificData(
          id: 0x01, // Use an appropriate manufacturer ID
          data: Uint8List.fromList([
            0x01, // Relay capability flag
            protocolVersion, // Protocol version
          ]),
        )
      ];

      // Start advertising
      await _peripheralManager.startAdvertising(
        Advertisement(
          name: 'BLE-Msg-$_deviceId',
          serviceUUIDs: [UUID.fromString(serviceUuid)],
          manufacturerSpecificData: manufacturerData,
        ),
      );

      _isAdvertising = true;
      _connectionStateSubject.add('Advertising');
      return true;
    } catch (e) {
      final errorMsg = 'Advertising error: $e';
      _connectionStateSubject.add(errorMsg);
      _errorSubject.add(errorMsg);
      return false;
    }
  }

  /// Stop advertising
  Future<bool> stopAdvertising() async {
    if (!_isAdvertising) {
      return true;
    }

    try {
      await _peripheralManager.stopAdvertising();
      await _peripheralManager.removeAllServices();
      _isAdvertising = false;
      _connectionStateSubject.add('Ready');
      return true;
    } catch (e) {
      final errorMsg = 'Stop advertising error: $e';
      _connectionStateSubject.add(errorMsg);
      _errorSubject.add(errorMsg);
      return false;
    }
  }

  /// Connect to a specific device
  Future<bool> connectToDevice(BleDevice device) async {
    return _connectToDevice(device.peripheral);
  }

  /// Internal connect to device with retry logic
  /// Internal connect to device with improved pooling and retry logic
  Future<bool> _connectToDevice(Peripheral peripheral) async {
    if (!_isInitialized) {
      _connectionStateSubject.add('Not initialized');
      return false;
    }

    final peripheralId = peripheral.uuid.toString();

    try {
      // Check if already connected
      final deviceIndex = _discoveredDevices.indexWhere(
              (d) => d.peripheral.uuid == peripheral.uuid
      );

      if (deviceIndex >= 0) {
        final device = _discoveredDevices[deviceIndex];

        if (device.isConnected) {
          return true; // Already connected
        }

        // Check if device is eligible for connection
        if (!device.canConnect) {
          debugPrint('Device in cooldown period, skipping connection attempt');
          return false;
        }

        // Calculate connection priority
        final priority = device.connectionPriority;

        // Queue connection instead of immediate connect
        _connectionPool.queueConnection(
            peripheral,
            priority,
                (p) async {
              try {
                // Connect to the peripheral with timeout
                await _centralManager.connect(p).timeout(
                  const Duration(seconds: 15),
                  onTimeout: () {
                    throw TimeoutException('Connection timed out');
                  },
                );

                // Update last activity timestamp
                _lastMessageActivity = DateTime.now();

                // Tell the pool we're done connecting
                _connectionPool.connectionCompleted(p);

                return true;
              } catch (e) {
                _errorSubject.add('Connection error to $peripheralId: $e');

                // Update failure count for the device
                final deviceIndex = _discoveredDevices.indexWhere(
                        (d) => d.peripheral.uuid == p.uuid
                );

                if (deviceIndex >= 0) {
                  _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
                    failedConnectionAttempts: _discoveredDevices[deviceIndex].failedConnectionAttempts + 1,
                  );
                  _devicesSubject.add(_discoveredDevices);
                }

                // Handle connection errors by scheduling retries for pending messages
                if (_hasMessagesFor(peripheralId)) {
                  _scheduleMessageRetry(peripheralId);
                }

                // Tell the pool we're done connecting
                _connectionPool.connectionCompleted(p);

                return false;
              }
            }
        );

        // For API compatibility, return true if queued, but actual connection will happen later
        return true;
      }
      return false;
    } catch (e) {
      _errorSubject.add('Connection error to $peripheralId: $e');
      return false;
    }
  }

  /// Disconnect from a specific device
  Future<bool> disconnectDevice(BleDevice device) async {
    if (!_isInitialized) {
      _connectionStateSubject.add('Not initialized');
      return false;
    }

    try {
      await _centralManager.disconnect(device.peripheral);
      return true;
    } catch (e) {
      _errorSubject.add('Disconnect error: $e');
      return false;
    }
  }

  /// Send a message to a specific device with improved queueing
  Future<bool> sendMessage(String recipientId, String content) async {
    return _stateLock.synchronized(() async {
      if (!_isInitialized) {
        _connectionStateSubject.add('Not initialized');
        return false;
      }

      final messageId = '${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(10000)}';

      final message = BleMessage(
        id: messageId,
        senderId: _deviceId,
        recipientId: recipientId,
        content: content,
        timestamp: DateTime.now(),
        status: MessageStatus.created,
      );

      // Create completer to track message delivery
      final completer = Completer<bool>();
      _outgoingMessageCompleters[messageId] = completer;

      // Add to message queue
      _messages.add(message);
      _messagesSubject.add(_messages);

      // Save messages to persistent storage
      await _saveMessages();

      // Update activity timestamp
      _lastMessageActivity = DateTime.now();

      // Try to send immediately if device is connected
      final recipientDeviceIndex = _discoveredDevices.indexWhere(
              (d) => d.id == recipientId && d.isConnected
      );

      if (recipientDeviceIndex >= 0) {
        final device = _discoveredDevices[recipientDeviceIndex];

        // Update message status
        await _updateMessageStatus(messageId, MessageStatus.pending);

        // Send the message
        _sendMessageToDevice(message, device.peripheral).then((success) {
          if (!success && !completer.isCompleted) {
            // If immediate send fails, will be picked up by retry mechanism
            _updateMessageStatus(
              messageId,
              MessageStatus.failed,
              attemptCount: 1,
              lastAttempt: DateTime.now(),
            );
          }
        }).catchError((e) {
          _errorSubject.add('Send error: $e');
          // Mark as failed to trigger retry
          _updateMessageStatus(
            messageId,
            MessageStatus.failed,
            attemptCount: 1,
            lastAttempt: DateTime.now(),
          );
        });
      } else {
        // Start scanning to find the recipient
        if (!_isScanning) {
          await startScan(maxDuration: activeScanDuration);
        }

        // Mark as pending
        await _updateMessageStatus(messageId, MessageStatus.pending);
      }

      // Set a timeout for message delivery notification
      Future.delayed(const Duration(minutes: 5), () {
        if (_outgoingMessageCompleters.containsKey(messageId) &&
            !_outgoingMessageCompleters[messageId]!.isCompleted) {
          // If still pending after 5 minutes, consider it failed
          // but don't complete the future since we'll keep retrying
          _updateMessageStatus(
            messageId,
            MessageStatus.failed,
            attemptCount: 10, // High attempt count to slow down retries
          );
        }
      });

      // Return future that will complete when message is delivered
      // or timeout after 30 seconds for UI responsiveness
      return completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => false, // Return false but don't complete the completer
      );
    });
  }

  /// Update message status with better tracking
  Future<void> _updateMessageStatus(
      String messageId,
      MessageStatus status, {
        int? attemptCount,
        DateTime? lastAttempt,
      }) async {
    return _stateLock.synchronized(() async {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index >= 0) {
        final message = _messages[index];
        final updatedMessage = message.copyWith(
          status: status,
          attemptCount: attemptCount ?? message.attemptCount,
          lastAttempt: lastAttempt ?? message.lastAttempt,
        );

        _messages[index] = updatedMessage;
        _messagesSubject.add(_messages);
        await _saveMessages();

        // If delivered or acknowledged, complete the future
        if (status == MessageStatus.delivered || status == MessageStatus.ack) {
          if (_outgoingMessageCompleters.containsKey(messageId) &&
              !_outgoingMessageCompleters[messageId]!.isCompleted) {
            _outgoingMessageCompleters[messageId]!.complete(true);
            _outgoingMessageCompleters.remove(messageId);
          }
        }
      }
    });
  }

  /// Process operations in batches to reduce radio usage
  Future<void> _batchOperations<T>(
      List<T> items,
      Future<void> Function(T item) operation) async {

    if (items.isEmpty) return;

    // Determine batch size based on length
    // Smaller batches for more items to avoid timeout
    final int batchSize = items.length > 20 ? 3 : (items.length > 10 ? 5 : 8);

    // Process in batches
    for (int i = 0; i < items.length; i += batchSize) {
      final end = math.min(i + batchSize, items.length);
      final batch = items.sublist(i, end);

      // Process this batch
      for (final item in batch) {
        try {
          await operation(item);
        } catch (e) {
          _errorSubject.add('Batch operation error: $e');
          _errorRecoveryManager.handleError('batchOperation', e);
        }
      }

      // Short delay between batches to allow radio to rest
      if (end < items.length) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Process outgoing messages with improved batching and efficiency
  Future<void> _processOutgoingMessages() async {
    return _stateLock.synchronized(() async {
    final undeliveredMessages = await compute((messages) {
      return messages.where((m) =>
        m.canRetry &&
        m.senderId == _deviceId &&
        !m.isRecentFailure
      ).toList();
    }, _messages);

      // Update activity timestamp since we have pending messages
      _lastMessageActivity = DateTime.now();

      // Sort by priority (age and attempt count)
      undeliveredMessages.sort((a, b) {
        // Prioritize recent messages with few attempts
        final aScore = a.timestamp.millisecondsSinceEpoch / 1000 - (a.attemptCount * 60);
        final bScore = b.timestamp.millisecondsSinceEpoch / 1000 - (b.attemptCount * 60);
        return bScore.compareTo(aScore); // Higher score (newer) first
      });

      // Group messages by recipient
      final messagesByRecipient = <String, List<BleMessage>>{};
      for (final message in undeliveredMessages) {
        // For direct messages
        if (message.relayPath.isEmpty) {
          if (!messagesByRecipient.containsKey(message.recipientId)) {
            messagesByRecipient[message.recipientId] = [];
          }
          messagesByRecipient[message.recipientId]!.add(message);
        }
        // For relay messages, use the next hop
        else {
          final nextHop = message.relayPath.last;
          if (!messagesByRecipient.containsKey(nextHop)) {
            messagesByRecipient[nextHop] = [];
          }
          messagesByRecipient[nextHop]!.add(message);
        }
      }

      // Find connected devices
      final connectedDevices = _discoveredDevices.where((d) => d.isConnected).toList();

      // Sort connected devices by connection priority
      connectedDevices.sort((a, b) => b.connectionPriority.compareTo(a.connectionPriority));

      // Process connected devices in batches
      await _batchOperations(connectedDevices, (device) async {
        final deviceId = device.id;
        final messages = messagesByRecipient[deviceId];

        if (messages != null && messages.isNotEmpty) {
          // Process this device's messages in batches
          await _batchOperations(messages, (message) async {
            // Update attempt count and last attempt time
            final index = _messages.indexWhere((m) => m.id == message.id);
            if (index >= 0) {
              _updateMessageStatus(
                message.id,
                MessageStatus.sending,
                attemptCount: message.attemptCount + 1,
                lastAttempt: DateTime.now(),
              );

              // Send the message
              await _sendMessageToDevice(
                _messages[index],
                device.peripheral,
              );
            }
          });
        }
      });

      // If there are still undelivered messages, try to use relay nodes
      final stillUndelivered = _messages.where((m) =>
      m.canRetry &&
          m.senderId == _deviceId &&
          m.relayPath.isEmpty &&
          !_discoveredDevices.any((d) => d.id == m.recipientId && d.isConnected)
      ).toList();

      if (stillUndelivered.isNotEmpty && connectedDevices.isNotEmpty) {
        await _tryRelayForUndeliveredMessages(stillUndelivered, connectedDevices);
      }

      // If there are still messages that need delivery, start scanning if not already
      final pendingAfterProcessing = _messages.where((m) =>
      m.canRetry &&
          m.senderId == _deviceId &&
          !m.isRecentFailure
      ).toList();

      if (pendingAfterProcessing.isNotEmpty && !_isScanning) {
        // Determine scan power based on message count and age
        final oldestPendingMessage = pendingAfterProcessing
            .map((m) => m.timestamp)
            .reduce((a, b) => a.isBefore(b) ? a : b);

        final messageAge = DateTime.now().difference(oldestPendingMessage).inMinutes;

        // Use low power scan if messages aren't urgent (over 30 min old)
        final lowPowerScan = messageAge > 30 && pendingAfterProcessing.length < 5;

        await startScan(
          maxDuration: lowPowerScan ? Duration(seconds: 10) : activeScanDuration,
          lowPowerMode: lowPowerScan,
        );
      }
    });
  }

  /// Try to use relay nodes for undelivered messages
  Future<void> _tryRelayForUndeliveredMessages(
      List<BleMessage> undeliveredMessages,
      List<BleDevice> connectedDevices,
      ) async {
    // Find messages that still need delivery and have no relay path yet
    final messagesToRelay = undeliveredMessages.where((m) =>
    m.canRetry &&
        m.relayPath.isEmpty &&
        !_discoveredDevices.any((d) => d.id == m.recipientId && d.isConnected)
    ).toList();

    if (messagesToRelay.isEmpty || connectedDevices.isEmpty) {
      return;
    }

    // Find potential relay nodes (devices that support relay)
    final relayNodes = connectedDevices.where((d) => d.supportsRelay).toList();
    if (relayNodes.isEmpty) return;

    // Sort relay nodes by RSSI (best signal first)
    relayNodes.sort((a, b) => b.rssi.compareTo(a.rssi));

    for (final message in messagesToRelay) {
      // Only relay if TTL allows
      if (message.ttl <= 0) continue;

      // Take a best relay node
      final relayNode = relayNodes.first;

      // Create a relayed version of the message
      final relayedMessage = message.copyWith(
        relayPath: [...message.relayPath, relayNode.id],
        ttl: message.ttl - 1,
      );

      // Update the message
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index >= 0) {
        _messages[index] = relayedMessage;
        _messagesSubject.add(_messages);
        await _saveMessages();

        // Try to send via relay
        await _sendMessageToDevice(relayedMessage, relayNode.peripheral);
      }
    }
  }

  /// Send a specific message to a connected device with packet fragmentation
  Future<bool> _sendMessageToDevice(BleMessage message, Peripheral peripheral) async {
    try {
      // Check if we have discovered services for this peripheral
      final peripheralId = peripheral.uuid.toString();
      final service = _deviceGattServices[peripheralId];

      if (service == null) {
        // Discover services first
        await _discoverServices(peripheral);
        return false; // Will retry after service discovery
      }

      // Find message characteristic
      final characteristic = _findCharacteristic(service, messageCharacteristicUuid);
      if (characteristic == null) {
        _errorSubject.add('Message characteristic not found');
        return false;
      }

      // Convert message to JSON and then to bytes
      final messageJson = jsonEncode(message.toJson());
      final messageBytes = Uint8List.fromList(utf8.encode(messageJson));

      // Handle message fragmentation if needed
      if (messageBytes.length > maxPacketSize) {
        return await _sendFragmentedMessage(message, messageBytes, peripheral, characteristic);
      } else {
        // Send the message in a single packet
        await _centralManager.writeCharacteristic(
          peripheral,
          characteristic,
          value: messageBytes,
          type: GATTCharacteristicWriteType.withResponse,
        );

        // Mark message as delivered
        _updateMessageStatus(message.id, MessageStatus.delivered);
        return true;
      }
    } catch (e) {
      _errorSubject.add('Failed to send message: $e');

      // Mark as failed for retry
      _updateMessageStatus(
        message.id,
        MessageStatus.failed,
        lastAttempt: DateTime.now(),
      );

      return false;
    }
  }

  /// Send a fragmented message with improved reliability
  Future<bool> _sendFragmentedMessage(
      BleMessage message,
      Uint8List messageBytes,
      Peripheral peripheral,
      GATTCharacteristic characteristic) async {

    // Get MTU for this device
    final effectiveMtu = await _getNegotiatedMtu(peripheral);

    try {
      // Calculate number of fragments needed with dynamic MTU
      final fragmentCount = (messageBytes.length / effectiveMtu).ceil();

      // Send metadata first
      final success = await _sendFragmentMetadata(
          message,
          messageBytes.length,
          fragmentCount,
          peripheral,
          characteristic
      );

      if (!success) {
        return false;
      }

      // Send all fragments
      return await _sendMessageFragments(
          message,
          messageBytes,
          fragmentCount,
          effectiveMtu,
          peripheral,
          characteristic
      );
    } catch (e) {
      _errorSubject.add('Failed to send fragmented message: $e');
      _errorRecoveryManager.handleError('sendFragmentedMessage', e);

      _updateMessageStatus(
        message.id,
        MessageStatus.failed,
        lastAttempt: DateTime.now(),
      );
      return false;
    }
  }

  Future<bool> _sendFragmentMetadata(
      BleMessage message,
      int totalSize,
      int fragmentCount,
      Peripheral peripheral,
      GATTCharacteristic characteristic) async {

    // Create metadata for fragment tracking
    final fragmentMetadata = {
      'messageId': message.id,
      'totalSize': totalSize,
      'fragmentCount': fragmentCount,
      'timestamp': DateTime.now().toIso8601String(),
      'protocol': 2,  // Protocol version for fragmentation
    };

    try {
      // Send metadata
      final metadataBytes = Uint8List.fromList(utf8.encode(jsonEncode(fragmentMetadata)));
      await _centralManager.writeCharacteristic(
        peripheral,
        characteristic,
        value: metadataBytes,
        type: GATTCharacteristicWriteType.withResponse,
      );

      // Small delay after metadata
      await Future.delayed(const Duration(milliseconds: 50));
      return true;
    } catch (e) {
      _errorSubject.add('Failed to send fragment metadata: $e');
      return false;
    }
  }

  Future<bool> _sendMessageFragments(
      BleMessage message,
      Uint8List messageBytes,
      int fragmentCount,
      int effectiveMtu,
      Peripheral peripheral,
      GATTCharacteristic characteristic) async {

    // Track which fragments have been acknowledged
    final fragmentsAcknowledged = List.filled(fragmentCount, false);
    final fragmentRetries = List.filled(fragmentCount, 0);
    final peripheralId = peripheral.uuid.toString();

    for (int i = 0; i < fragmentCount; i++) {
      // Calculate fragment boundaries using dynamic MTU
      final start = i * effectiveMtu;
      final end = math.min((i + 1) * effectiveMtu, messageBytes.length);
      final fragmentData = messageBytes.sublist(start, end);

      final fragmentPacket = _createFragmentPacket(message.id, i, fragmentCount, fragmentData);

      // Send with retries
      final fragmentSent = await _sendSingleFragment(
          peripheral,
          characteristic,
          fragmentPacket,
          i,
          fragmentRetries
      );

      if (fragmentSent) {
        fragmentsAcknowledged[i] = true;
      }

      // Check connection state before continuing
      final deviceIndex = _discoveredDevices.indexWhere(
              (d) => d.id == peripheralId && d.isConnected
      );

      if (deviceIndex < 0) {
        throw Exception('Device disconnected during fragmented send');
      }

      // Adaptive delay between fragments based on MTU size
      // Smaller MTU needs more time between packets
      if (i < fragmentCount - 1) {
        final delay = math.max(50, 150 - effectiveMtu ~/ 4);
        await Future.delayed(Duration(milliseconds: delay));
      }
    }

    // Check if all fragments were sent
    final allFragmentsSent = !fragmentsAcknowledged.contains(false);

    if (allFragmentsSent) {
      _updateMessageStatus(message.id, MessageStatus.delivered);
      return true;
    } else {
      // Find which fragments failed
      final failedFragments = <int>[];
      for (int i = 0; i < fragmentsAcknowledged.length; i++) {
        if (!fragmentsAcknowledged[i]) {
          failedFragments.add(i);
        }
      }

      _errorSubject.add('Failed to send fragments: ${failedFragments.join(', ')}');
      _updateMessageStatus(
        message.id,
        MessageStatus.failed,
        lastAttempt: DateTime.now(),
      );
      return false;
    }
  }

  Uint8List _createFragmentPacket(String messageId, int index, int count, Uint8List data) {
    // Create fragment header (keep it small)
    final fragmentHeader = {
      'id': messageId,
      'i': index,  // Fragment index
      'c': count,  // Total count
    };

    // Combine header and data
    final headerBytes = Uint8List.fromList(utf8.encode(jsonEncode(fragmentHeader)));

    // Ensure header is not too large
    if (headerBytes.length > 20) {
      throw Exception('Fragment header too large - optimize header size');
    }

    // Create packet with one byte header size prefix
    final packetBytes = Uint8List(1 + headerBytes.length + data.length);
    packetBytes[0] = headerBytes.length;
    packetBytes.setRange(1, 1 + headerBytes.length, headerBytes);
    packetBytes.setRange(1 + headerBytes.length, packetBytes.length, data);

    return packetBytes;
  }

  Future<bool> _sendSingleFragment(
      Peripheral peripheral,
      GATTCharacteristic characteristic,
      Uint8List packetBytes,
      int fragmentIndex,
      List<int> fragmentRetries) async {

    bool fragmentSent = false;

    while (!fragmentSent && fragmentRetries[fragmentIndex] < 3) {
      try {
        await _centralManager.writeCharacteristic(
          peripheral,
          characteristic,
          value: packetBytes,
          type: GATTCharacteristicWriteType.withResponse,
        );
        fragmentSent = true;
        _errorRecoveryManager.operationSucceeded();
      } catch (e) {
        fragmentRetries[fragmentIndex]++;
        if (fragmentRetries[fragmentIndex] >= 3) {
          _errorRecoveryManager.handleError('fragment write', e);
          return false;
        }
        await Future.delayed(Duration(milliseconds: 200 * fragmentRetries[fragmentIndex]));
      }
    }

    return fragmentSent;
  }


  /// Process an incoming message with enhanced fragment handling
  Future<void> _processIncomingMessage(
      Peripheral? peripheral,
      Uint8List value, {
        Central? central,
      }) async {
    return _stateLock.synchronized(() async {
      try {
        // Check if it's a protocol v2 fragment (prefixed with header size byte)
        if (value.length > 2 && value[0] < 30) {  // Header should be reasonably small
          final headerSize = value[0];

          // If header size is valid, extract and process header
          if (headerSize > 0 && value.length > headerSize + 1) {
            final headerBytes = value.sublist(1, 1 + headerSize);
            try {
              final headerJson = utf8.decode(headerBytes);
              final header = jsonDecode(headerJson) as Map<String, dynamic>;

              // Check if it has fragment indicators
              if ((header.containsKey('i') || header.containsKey('fragmentIndex')) &&
                  (header.containsKey('c') || header.containsKey('fragmentCount'))) {

                await _processMessageFragment(
                  header,
                  value.sublist(1 + headerSize),
                  peripheral,
                  central,
                );
                return;
              }

              // Check if it's a fragment metadata message
              if (header.containsKey('protocol') && header['protocol'] == 2 &&
                  header.containsKey('fragmentCount')) {
                // Store metadata for this message for future fragment assembly
                final messageId = header['messageId'];
                if (!_incomingPackets.containsKey(messageId)) {
                  _incomingPackets[messageId] = List.generate(
                    header['fragmentCount'],
                        (i) => <String, dynamic>{
                      'received': false,
                      'timestamp': DateTime.now(),
                    },
                  );
                }
                return;
              }
            } catch (e) {
              // Not valid JSON in header, continue to check older protocol
            }
          }
        }

        // Check if it's an old protocol fragment (2-byte header size)
        if (value.length > 2) {
          final headerSize = value[0] | (value[1] << 8);

          // If header size is valid, check for fragment
          if (headerSize > 0 && headerSize < 100 && value.length > headerSize + 2) {
            final headerBytes = value.sublist(2, 2 + headerSize);
            try {
              final headerJson = utf8.decode(headerBytes);
              final header = jsonDecode(headerJson) as Map<String, dynamic>;

              // If it's a fragment, process it
              if (header.containsKey('isFragment') && header['isFragment'] == true) {
                await _processMessageFragment(
                  header,
                  value.sublist(2 + headerSize),
                  peripheral,
                  central,
                );
                return;
              }
            } catch (e) {
              // Not valid JSON, try to process as a regular message
            }
          }
        }

        // Not a fragment, process normally
        await _processRegularMessage(value, peripheral, central);
      } catch (e) {
        _errorSubject.add('Failed to process incoming message: $e');
        _errorRecoveryManager.handleError('processIncomingMessage', e);
      }
    });
  }

  /// Process a message fragment with improved reassembly
  Future<void> _processMessageFragment(
      Map<String, dynamic> header,
      Uint8List fragmentData,
      Peripheral? peripheral,
      Central? central) async {

    // Extract fragment information - support both verbose and compact formats
    final messageId = header['messageId'] ?? header['id'] as String;
    final fragmentIndex = header['fragmentIndex'] ?? header['i'] as int;
    final fragmentCount = header['fragmentCount'] ?? header['c'] as int;

    // Create entry for this message if it doesn't exist
    if (!_incomingPackets.containsKey(messageId)) {
      _incomingPackets[messageId] = List.generate(
        fragmentCount,
            (i) => <String, dynamic>{
          'received': false,
          'timestamp': DateTime.now(),
        },
      );
    }

    // Store this fragment
    _incomingPackets[messageId]![fragmentIndex] = {
      'received': true,
      'data': fragmentData,
      'timestamp': DateTime.now(),
    };

    // Check if all fragments received
    bool complete = true;
    List<int> missingFragments = [];

    for (int i = 0; i < _incomingPackets[messageId]!.length; i++) {
      if (_incomingPackets[messageId]![i]['received'] != true) {
        complete = false;
        missingFragments.add(i);
      }
    }

    // If complete, reassemble and process
    if (complete) {
      // Calculate total size
      int totalSize = 0;
      for (final fragment in _incomingPackets[messageId]!) {
        totalSize += (fragment['data'] as Uint8List).length;
      }

      // Combine fragments
      final completeData = Uint8List(totalSize);
      int offset = 0;
      for (int i = 0; i < fragmentCount; i++) {
        final fragmentData = _incomingPackets[messageId]![i]['data'] as Uint8List;
        completeData.setRange(offset, offset + fragmentData.length, fragmentData);
        offset += fragmentData.length;
      }

      // Process the complete message
      await _processRegularMessage(completeData, peripheral, central);

      // Clean up
      _incomingPackets.remove(messageId);
    }
    // If peripheral is available, could potentially request missing fragments
    else if (peripheral != null && fragmentIndex == fragmentCount - 1) {
      debugPrint('Message incomplete, missing fragments: ${missingFragments.join(', ')}');
      // Missing fragment handling could be implemented here
    }
  }

  /// Process a regular (non-fragmented) message
  Future<void> _processRegularMessage(
      Uint8List value,
      Peripheral? peripheral,
      Central? central,
      ) async {
    return _stateLock.synchronized(() async {
      // Decode the message
      final messageJson = utf8.decode(value);
      final messageData = jsonDecode(messageJson) as Map<String, dynamic>;
      final message = BleMessage.fromJson(messageData);

      // Update activity timestamp
      _lastMessageActivity = DateTime.now();

      // Handle different message routing scenarios

      // Case 1: Message is for us
      if (message.recipientId == _deviceId) {
        // Add to our messages if not already present
        final existingIndex = _messages.indexWhere((m) => m.id == message.id);
        if (existingIndex < 0) {
          _messages.add(message);
          _messagesSubject.add(_messages);
          await _saveMessages();

          // Show notification for new message
          _showMessageNotification(message);
        }

        // Send acknowledgment
        await _sendAcknowledgment(message, peripheral, central);
      }
      // Case 2: Message is relayed through us
      else if (message.relayPath.contains(_deviceId)) {
        // Check if we're the last relay point
        if (message.relayPath.last == _deviceId) {
          // Final relay - try to deliver to recipient
          await _relayMessageToFinalRecipient(message);
        }
        // We're an intermediate relay point
        else {
          // Find next relay in path
          final ourIndex = message.relayPath.indexOf(_deviceId);
          if (ourIndex < message.relayPath.length - 1) {
            final nextRelayId = message.relayPath[ourIndex + 1];
            await _relayMessageToNextHop(message, nextRelayId);
          }
        }
      }
      // Case 3: We can help relay a message to someone else
      else if (message.ttl > 0 && message.senderId != _deviceId) {
        // Store message if we haven't seen it
        final existingIndex = _messages.indexWhere((m) => m.id == message.id);
        if (existingIndex < 0) {
          // Add our ID to relay path
          final updatedMessage = message.copyWith(
            relayPath: [...message.relayPath, _deviceId],
            ttl: message.ttl - 1,
          );

          _messages.add(updatedMessage);
          _messagesSubject.add(_messages);
          await _saveMessages();

          // Try to find recipient or next relay
          await _findAndRelayMessage(updatedMessage);
        }
      }
    });
  }

  /// Try to relay a message to its final recipient
  Future<void> _relayMessageToFinalRecipient(BleMessage message) async {
    // Find if recipient is connected or nearby
    final recipientIndex = _discoveredDevices
        .indexWhere((d) => d.id == message.recipientId);

    if (recipientIndex >= 0) {
      final recipientDevice = _discoveredDevices[recipientIndex];

      // Connect if not already connected
      if (!recipientDevice.isConnected) {
        final connected = await _connectToDevice(recipientDevice.peripheral);
        if (!connected) {
          // Will retry later through normal processing
          return;
        }
      }

      // Try to deliver the message
      await _sendMessageToDevice(message, recipientDevice.peripheral);
    }
    // Otherwise will be picked up by normal message processing for retry
  }

  /// Relay a message to next hop in path
  Future<void> _relayMessageToNextHop(BleMessage message, String nextHopId) async {
    // Find if next hop is connected or nearby
    final nextHopIndex = _discoveredDevices
        .indexWhere((d) => d.id == nextHopId);

    if (nextHopIndex >= 0) {
      final nextHopDevice = _discoveredDevices[nextHopIndex];

      // Connect if not already connected
      if (!nextHopDevice.isConnected) {
        final connected = await _connectToDevice(nextHopDevice.peripheral);
        if (!connected) {
          // Will retry later through normal processing
          return;
        }
      }

      // Try to deliver the message
      await _sendMessageToDevice(message, nextHopDevice.peripheral);
    }
    // Otherwise will be picked up by normal message processing for retry
  }

  /// Find appropriate device to relay message
  Future<void> _findAndRelayMessage(BleMessage message) async {
    // First try direct delivery if recipient is nearby
    final recipientIndex = _discoveredDevices
        .indexWhere((d) => d.id == message.recipientId);

    if (recipientIndex >= 0) {
      final recipientDevice = _discoveredDevices[recipientIndex];

      // Connect if not already connected
      if (!recipientDevice.isConnected) {
        final connected = await _connectToDevice(recipientDevice.peripheral);
        if (connected) {
          // Try to deliver the message directly
          await _sendMessageToDevice(message, recipientDevice.peripheral);
          return;
        }
      } else {
        // Already connected, send directly
        await _sendMessageToDevice(message, recipientDevice.peripheral);
        return;
      }
    }

    // If direct delivery not possible, find best relay node
    final potentialRelays = _discoveredDevices
        .where((d) =>
    d.supportsRelay &&
        !message.relayPath.contains(d.id) &&
        d.isConnected)
        .toList();

    if (potentialRelays.isNotEmpty) {
      // Sort by connection priority
      potentialRelays.sort((a, b) => b.connectionPriority.compareTo(a.connectionPriority));

      // Try best relay
      await _sendMessageToDevice(message, potentialRelays.first.peripheral);
    }
    // Otherwise will be picked up by normal message processing
  }

  /// Send an acknowledgment for a received message
  Future<void> _sendAcknowledgment(
      BleMessage message,
      Peripheral? peripheral,
      Central? central,
      ) async {
    try {
      // Prepare acknowledgment data
      final ackData = {
        'messageId': message.id,
        'recipientId': message.senderId,
        'timestamp': DateTime.now().toIso8601String(),
        'isAck': true,
      };

      final ackBytes = Uint8List.fromList(utf8.encode(jsonEncode(ackData)));

      // Send acknowledgment to peripheral or central
      if (peripheral != null) {
        // Check if we have discovered services
        final peripheralId = peripheral.uuid.toString();
        final service = _deviceGattServices[peripheralId];

        if (service == null) {
          // Discover services first
          await _discoverServices(peripheral);
          return; // Will retry later
        }

        // Find ack characteristic
        final characteristic = _findCharacteristic(service, ackCharacteristicUuid);
        if (characteristic == null) {
          _errorSubject.add('ACK characteristic not found');
          return;
        }

        // Send ack
        await _centralManager.writeCharacteristic(
          peripheral,
          characteristic,
          value: ackBytes,
          type: GATTCharacteristicWriteType.withResponse,
        );
      }
      // Send to central if that's where message came from
      else if (central != null) {
        // Get ACK characteristic from our service
        final ackCharacteristic = await _getAckCharacteristic();
        if (ackCharacteristic != null) {
          // Notify central of acknowledgment
          await _peripheralManager.notifyCharacteristic(
            central,
            ackCharacteristic,
            value: ackBytes,
          );
        }
      }
    } catch (e) {
      _errorSubject.add('Failed to send acknowledgment: $e');
    }
  }

  /// Get ACK characteristic from our service
  Future<GATTCharacteristic?> _getAckCharacteristic() async {
    if (_ackCharacteristic != null) return _ackCharacteristic;

    try {
      // Only create if not available
      final service = await _createGattService();

      // Find characteristics matching our UUID
      final matchingCharacteristics = service.characteristics
          .where((c) => c.uuid.toString() == ackCharacteristicUuid)
          .toList();

      if (matchingCharacteristics.isNotEmpty) {
        _ackCharacteristic = matchingCharacteristics.first;
        return _ackCharacteristic;
      } else {
        return null;
      }
    } catch (e) {
      _errorSubject.add('Failed to get ACK characteristic: $e');
      return null;
    }
  }

  /// Process an acknowledgment message
  Future<void> _processAcknowledgment(
      Peripheral? peripheral,
      Uint8List value, {
        Central? central,
      }) async {
    try {
      // Decode the acknowledgment
      final ackJson = utf8.decode(value);
      final ackData = jsonDecode(ackJson) as Map<String, dynamic>;

      // Validate this is actually an ACK
      if (!(ackData['isAck'] == true)) {
        return;
      }

      final messageId = ackData['messageId'] as String;

      // Find the original message
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index >= 0) {
        // Mark message as acknowledged
        _updateMessageStatus(_messages[index].id, MessageStatus.ack);
      }
    } catch (e) {
      _errorSubject.add('Failed to process acknowledgment: $e');
    }
  }

  /// Show a notification for a new message
  void _showMessageNotification(BleMessage message) {
    try {
      // Use the NotificationService which doesn't rely on WidgetsFlutterBinding
      // and avoids conflicts with the BLE plugin's ConnectionState
      NotificationService().showNotification(
        'New BLE Message',
        _buildMessagePreview(message.content),
        id: message.hashCode,
        payload: message.id,
      );

      debugPrint('New message: ${message.content}');
    } catch (e) {
      debugPrint('Failed to show notification: $e');
    }
  }

  /// Build a safe preview of the message content
  String _buildMessagePreview(String content) {
    // Limit preview length
    if (content.length > 100) {
      return '${content.substring(0, 97)}...';
    }
    return content;
  }

  /// Discover GATT services for a peripheral with retry logic
  Future<void> _discoverServices(Peripheral peripheral) async {
    try {
      final services = await _centralManager.discoverGATT(peripheral)
          .timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Service discovery timed out'),
      );

      // Find our service
      final service = services.firstWhere(
            (s) => s.uuid.toString() == serviceUuid,
        orElse: () => throw Exception('Service not found'),
      );

      // Cache the service
      _deviceGattServices[peripheral.uuid.toString()] = service;

      // Subscribe to message characteristic notifications
      final messageCharacteristic = _findCharacteristic(service, messageCharacteristicUuid);
      if (messageCharacteristic != null) {
        await _centralManager.setCharacteristicNotifyState(
          peripheral,
          messageCharacteristic,
          state: true,
        );
      }

      // Subscribe to acknowledgment characteristic notifications
      final ackCharacteristic = _findCharacteristic(service, ackCharacteristicUuid);
      if (ackCharacteristic != null) {
        await _centralManager.setCharacteristicNotifyState(
          peripheral,
          ackCharacteristic,
          state: true,
        );
      }

      // Try to send any pending messages to this device
      await _processOutgoingMessages();

      // Service discovery successful - the device is now fully connected
      return;
    } catch (e) {
      _errorSubject.add('Failed to discover services: $e');

      // Update device connection failure count
      final deviceIndex = _discoveredDevices.indexWhere(
              (d) => d.peripheral.uuid == peripheral.uuid
      );

      if (deviceIndex >= 0) {
        // Increment failure count
        _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
          failedConnectionAttempts: _discoveredDevices[deviceIndex].failedConnectionAttempts + 1,
          connectionState: ConnectionState.disconnected,
        );
        _devicesSubject.add(_discoveredDevices);
      }

      // Try to disconnect to cleanup
      try {
        await _centralManager.disconnect(peripheral);
      } catch (_) {
        // Ignore disconnect errors
      }

      // Rethrow to let the connection handler know service discovery failed
      rethrow;
    }
  }

  /// Create a GATT service for the peripheral role with all required characteristics
  Future<GATTService> _createGattService() async {
    // Create device info characteristic
    final deviceInfoCharacteristic = GATTCharacteristic.mutable(
      uuid: UUID.fromString(deviceInfoCharacteristicUuid),
      properties: [
        GATTCharacteristicProperty.read,
      ],
      permissions: [
        GATTCharacteristicPermission.read,
      ],
      descriptors: [],
    );

    // Create message characteristic
    final messageCharacteristic = GATTCharacteristic.mutable(
      uuid: UUID.fromString(messageCharacteristicUuid),
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.notify,
      ],
      permissions: [
        GATTCharacteristicPermission.write,
      ],
      descriptors: [],
    );

    // Create acknowledgment characteristic
    final ackCharacteristic = GATTCharacteristic.mutable(
      uuid: UUID.fromString(ackCharacteristicUuid),
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.notify,
      ],
      permissions: [
        GATTCharacteristicPermission.write,
      ],
      descriptors: [],
    );

    // Create service
    return GATTService(
      uuid: UUID.fromString(serviceUuid),
      isPrimary: true,
      includedServices: [],
      characteristics: [
        deviceInfoCharacteristic,
        messageCharacteristic,
        ackCharacteristic,
      ],
    );
  }

  /// Helper method to check if a characteristic matches a UUID
  bool _isServiceCharacteristic(GATTCharacteristic characteristic, String uuidString) {
    return characteristic.uuid.toString() == uuidString;
  }

  /// Find a characteristic by UUID in a service
  GATTCharacteristic? _findCharacteristic(GATTService service, String uuidString) {
    try {
      return service.characteristics.firstWhere(
            (c) => c.uuid.toString() == uuidString,
      );
    } catch (e) {
      return null;
    }
  }

  /// Check if we have messages for a specific device
  bool _hasMessagesFor(String deviceId) {
    // Check for direct messages
    final hasDirectMessages = _messages.any((m) =>
    m.canRetry &&
        m.senderId == _deviceId &&
        m.recipientId == deviceId
    );

    if (hasDirectMessages) return true;

    // Check for relay messages where this device is the next hop
    final hasRelayMessages = _messages.any((m) =>
    m.canRetry &&
        m.senderId == _deviceId &&
        m.relayPath.isNotEmpty &&
        m.relayPath.last == deviceId
    );

    return hasRelayMessages;
  }

  /// Load messages from persistent storage
  Future<void> _loadMessages() async {
    return _stateLock.synchronized(() async {
      try {
        // First try to load from SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final messagesJson = prefs.getStringList('ble_messages');

        if (messagesJson != null && messagesJson.isNotEmpty) {
          _messages = messagesJson
              .map((json) => BleMessage.fromJson(jsonDecode(json)))
              .toList();

          _messagesSubject.add(_messages);
        } else {
          // If not in SharedPreferences, try file-based storage
          await _loadMessagesFromFile();
        }
      } catch (e) {
        _errorSubject.add('Failed to load messages from SharedPreferences: $e');
        // Try backup storage
        await _loadMessagesFromFile();
      }
    });
  }

  // Add this function to the BleService class
  Future<void> ensureDirectoryExists(String path) async {
    try {
      final directory = Directory(path);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
    } catch (e) {
      _errorSubject.add('Failed to create directory: $e');
    }
  }

  Future<String> getMessageStoragePath() async {
    try {
      // For background isolates, use getTemporaryDirectory instead which is safer
      final directory = await getTemporaryDirectory();
      final messagePath = path.join(directory.path, 'ble_messages');

      // Create the directory if it doesn't exist
      final messageDir = Directory(messagePath);
      if (!await messageDir.exists()) {
        await messageDir.create(recursive: true);
      }

      return messagePath;
    } catch (e) {
      _errorSubject.add('Failed to get storage path: $e');
      // Fallback to app data directory
      return '.';
    }
  }

// This function creates a file-based storage that's more reliable
// than SharedPreferences for background operations
  Future<void> _saveMessagesToFile() async {
    try {
      final storagePath = await getMessageStoragePath();
      final file = File(path.join(storagePath, 'messages.json'));

      // Convert messages to JSON
      final jsonData = jsonEncode(_messages.map((m) => m.toJson()).toList());

      // Write to file
      await file.writeAsString(jsonData, flush: true);
    } catch (e) {
      _errorSubject.add('Failed to save messages to file: $e');
    }
  }

// And the corresponding load function
  Future<void> _loadMessagesFromFile() async {
    try {
      final storagePath = await getMessageStoragePath();
      final file = File(path.join(storagePath, 'messages.json'));

      if (await file.exists()) {
        final jsonData = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(jsonData);

        _messages = decoded.map((json) => BleMessage.fromJson(json)).toList();
        _messagesSubject.add(_messages);
      }
    } catch (e) {
      _errorSubject.add('Failed to load messages from file: $e');
      // Continue with empty messages list
      _messages = [];
    }
  }

  /// Save messages to persistent storage with cleanup of old delivered messages
  Future<void> _saveMessages() async {
    return _stateLock.synchronized(() async {
      try {
        // Clean up old delivered messages first (keep max 100 delivered messages)
        final deliveredMessages = _messages.where((m) =>
        m.status == MessageStatus.delivered ||
            m.status == MessageStatus.ack
        ).toList();

        // Sort by timestamp (newest first)
        deliveredMessages.sort((a, b) => b.timestamp.compareTo(a.timestamp));

        // Remove excess delivered messages
        if (deliveredMessages.length > 100) {
          final messagesToRemove = deliveredMessages.sublist(100);
          for (final messageToRemove in messagesToRemove) {
            _messages.removeWhere((m) => m.id == messageToRemove.id);
          }
        }

        // Also remove messages older than 30 days
        final cutoffDate = DateTime.now().subtract(const Duration(days: 30));
        _messages.removeWhere((m) =>
        (m.status == MessageStatus.delivered || m.status == MessageStatus.ack) &&
            m.timestamp.isBefore(cutoffDate)
        );

        // Remove failed messages that are very old (7 days)
        final oldFailedCutoff = DateTime.now().subtract(const Duration(days: 7));
        _messages.removeWhere((m) =>
        m.status == MessageStatus.failed &&
            m.timestamp.isBefore(oldFailedCutoff)
        );

        // Update UI
        _messagesSubject.add(_messages);

        final appDir = await getApplicationDocumentsDirectory();
        await ensureDirectoryExists(appDir.path);

        // First try to save with SharedPreferences
        try {
          final prefs = await SharedPreferences.getInstance();
          final messagesJson = _messages
              .map((m) => jsonEncode(m.toJson()))
              .toList();

          await prefs.setStringList('ble_messages', messagesJson);
        } catch (e) {
          _errorSubject.add('SharedPreferences save failed: $e');
          // Fall back to file-based storage
          await _saveMessagesToFile();
        }
      } catch (e) {
        _errorSubject.add('Failed to save messages: $e');
      }
    });
  }

  /// Get all undelivered messages
  List<BleMessage> getUndeliveredMessages() {
    return _messages.where((m) =>
    m.status != MessageStatus.delivered &&
        m.status != MessageStatus.ack
    ).toList();
  }

  /// Delete a message
  Future<bool> deleteMessage(String messageId) async {
    return _stateLock.synchronized(() async {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index >= 0) {
        _messages.removeAt(index);
        _messagesSubject.add(_messages);
        await _saveMessages();
        return true;
      }
      return false;
    });
  }

  /// Mark a message as read
  Future<bool> markMessageAsRead(String messageId) async {
    return _stateLock.synchronized(() async {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index >= 0) {
        final message = _messages[index];
        // Add metadata for read status if not present
        Map<String, dynamic> metadata = message.metadata ?? {};
        metadata['read'] = true;
        metadata['readAt'] = DateTime.now().toIso8601String();

        _messages[index] = message.copyWith(metadata: metadata);
        _messagesSubject.add(_messages);
        await _saveMessages();
        return true;
      }
      return false;
    });
  }

  /// Cleanup resources
  void dispose() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();

    _adaptiveScanTimer?.cancel();
    _messageProcessingTimer?.cancel();

    _devicesSubject.close();
    _messagesSubject.close();
    _connectionStateSubject.close();
    _errorSubject.close();

    stopScan();
    stopAdvertising();
  }

  /// Manually trigger a full retry of all pending messages
  Future<void> retryAllPendingMessages() async {
    // Reset recent failure flags by updating lastAttempt
    final messagesToRetry = _messages.where((m) => m.canRetry).toList();

    for (final message in messagesToRetry) {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index >= 0) {
        // Reset attempt count to give it fresh retry chances
        _updateMessageStatus(
          message.id,
          MessageStatus.pending,
          attemptCount: 0,
          lastAttempt: null,
        );
      }
    }

    // Process messages immediately
    await _processOutgoingMessages();

    // Start scanning if needed
    if (!_isScanning && messagesToRetry.isNotEmpty) {
      await startScan(maxDuration: activeScanDuration);
    }
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  final _initLock = Lock();

  // Initialize notifications without depending on WidgetsFlutterBinding
  Future<void> initialize() async {
    // Use lock to prevent concurrent initialization
    return _initLock.synchronized(() async {
      if (_isInitialized) return;

      try {
        // Define notification channels
        const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
          'ble_service_foreground',
          'BLE Messaging Service',
          description: 'Background service for BLE messaging',
          importance: Importance.high,
        );

        const AndroidNotificationChannel messagesChannel = AndroidNotificationChannel(
          'ble_messages',
          'BLE Messages',
          description: 'Notifications for BLE messages',
          importance: Importance.high,
        );

        // Platform-specific initialization without binding dependencies
        final initSettings = InitializationSettings(
          android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: const DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: true,
            requestSoundPermission: true,
          ),
        );

        // Initialize the plugin with error handling
        await _notificationsPlugin.initialize(
          initSettings,
          onDidReceiveNotificationResponse: (NotificationResponse details) {
            debugPrint('Notification tapped: ${details.payload}');
          },
        );

        // Create notification channels for Android
        if (Platform.isAndroid) {
          final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
          _notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

          if (androidPlugin != null) {
            await androidPlugin.createNotificationChannel(serviceChannel);
            await androidPlugin.createNotificationChannel(messagesChannel);

            // Request permissions with proper error handling
            try {
              final bool? granted = await androidPlugin.requestNotificationsPermission();
              debugPrint('Notification permission granted: $granted');
            } catch (e) {
              debugPrint('Failed to request notification permission: $e');
            }

            // Check and request exact alarm permissions
            try {
              final bool? canScheduleExact = await androidPlugin.canScheduleExactNotifications();
              debugPrint('Can schedule exact notifications: $canScheduleExact');

              if (canScheduleExact == false) {
                final bool? exactAlarmGranted = await androidPlugin.requestExactAlarmsPermission();
                debugPrint('Exact alarm permission granted: $exactAlarmGranted');
              }
            } catch (e) {
              debugPrint('Failed to check/request exact alarm permissions: $e');
            }
          }
        }

        _isInitialized = true;
        debugPrint('Notification service initialized successfully');
      } catch (e) {
        debugPrint('Failed to initialize notification service: $e');
      }
    });
  }

  // Show a notification with robust error handling
  Future<void> showNotification(String title, String body, {int id = 0, String? payload}) async {
    try {
      // Ensure initialized first
      await initialize();

      await _notificationsPlugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: const AndroidNotificationDetails(
            'ble_messages',
            'BLE Messages',
            channelDescription: 'Notifications for BLE messages',
            importance: Importance.high,
            priority: Priority.high,
            showWhen: true,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('Failed to show notification: $e');
    }
  }

  // Method specifically for updating a foreground service notification
  Future<void> updateServiceNotification(String title, String content, {int id = 888}) async {
    try {
      // Ensure initialized first
      await initialize();

      await _notificationsPlugin.show(
        id,
        title,
        content,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'ble_service_foreground',
            'BLE Messaging Service',
            channelDescription: 'Background service for BLE messaging',
            importance: Importance.high,
            ongoing: true, // This is a persistent notification
            showWhen: false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Failed to update service notification: $e');
    }
  }
}