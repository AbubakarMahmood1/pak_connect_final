import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:math' as math;


import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
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
  late final MessageStatus status;
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

  int get priority {
    // Check if explicit priority is set in metadata
    if (metadata != null && metadata!.containsKey('priority')) {
      final priorityStr = metadata!['priority'];
      if (priorityStr == 'high') return 2;
      if (priorityStr == 'low') return 0;
    }

    // Default to normal priority (1)
    return 1;
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
  final Map<String, dynamic>? metadata;

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
    this.metadata,
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
      metadata: {},
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
    Map<String, dynamic>? metadata,
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
      metadata: metadata ?? this.metadata,
    );
  }

  String get id => peripheral.uuid.toString();

  bool get isConnected => deviceConnectionState == DeviceConnectionState.connected;

  // Determine if device is eligible for connection attempt
  bool get canConnect {
    // Don't try to connect if already connected
    if (isConnected) return false;

    // Don't connect if already in connecting state
    if (deviceConnectionState == DeviceConnectionState.connecting) return false;

    // For failed connection attempts, implement a more nuanced backoff
    if (failedConnectionAttempts > 0) {
      final now = DateTime.now();
      if (lastConnected != null) {
        // Calculate backoff time based on attempt count and success rate
        int backoffSeconds;

        // Get connection success rate from the resilient manager
        final successRate = ResilientConnectionManager().getConnectionSuccessRate(id);

        // Adjust backoff based on success rate
        final rateAdjustment = (1.0 - successRate) * 2.0; // Higher failure rate = longer backoff

        // For first 3 failures, retry with short backoff
        if (failedConnectionAttempts <= 3) {
          backoffSeconds = (15 * failedConnectionAttempts * (1.0 + rateAdjustment)).toInt();
        } else {
          // After 3 failures, use exponential backoff up to a maximum
          final expBackoff = math.pow(2, failedConnectionAttempts - 3).toInt() * 30 * (1.0 + rateAdjustment);
          backoffSeconds = math.min(expBackoff.toInt(), 600); // Cap at 10 minutes
        }

        // Check if we've waited long enough
        if (now.difference(lastConnected!).inSeconds < backoffSeconds) {
          return false;
        }
      }
    }

    // Signal strength based filtering
    // Only connect to devices with decent signal
    if (rssi < -50) {
      return false; // Signal too weak
    }

    return true;
  }

  // Calculate connection priority (higher is better)
  int get connectionPriority {
    int priority = 0;

    // Stronger signal gets higher priority
    priority += math.max(0, (rssi + 100)) * 2;  // Double the weight of signal strength

    // Recently seen devices get higher priority
    final freshness = DateTime.now().difference(lastSeen).inSeconds;
    priority += math.max(0, 300 - freshness);

    // Penalize devices that frequently fail connection, but not too severely
    int failurePenalty = 0;
    if (failedConnectionAttempts > 0) {
      failurePenalty = math.min(50 * failedConnectionAttempts, 200);
    }
    priority -= failurePenalty;

    // Major bonus for devices that support relay
    if (supportsRelay) priority += 300;

    // Bonus for devices we've successfully connected to before
    if (lastConnected != null) priority += 100;

    // Extra bonus for devices with our service
    if (deviceConnectionState == DeviceConnectionState.connected) priority += 500;

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

  // Add to ConnectionPool class
  void retryFailedConnections() {
    if (_activeConnections.length >= maxConcurrentConnections) return;

    final now = DateTime.now();
    final retriableRequests = _pendingConnections.where((req) {
      // Check if this request is eligible for retry
      return now.difference(req.timestamp).inSeconds > 30;
    }).toList();

    if (retriableRequests.isNotEmpty) {
      debugPrint('🔄 Retrying ${retriableRequests.length} connection requests');
      _processQueue();
    }
  }

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

/// Manages coordination between main app and background service for BLE initialization
class BleInitializationCoordinator {
  static final BleInitializationCoordinator _instance = BleInitializationCoordinator._internal();
  factory BleInitializationCoordinator() => _instance;
  BleInitializationCoordinator._internal();

  // Shared mutex for initialization synchronization
  final _initMutex = Lock();

  // State tracking
  bool _isInitializing = false;
  bool _isInitialized = false;
  bool _isBackgroundService = false; // Now used in methods
  late var _completer = Completer<bool>();

  // Get initialization context
  bool get isBackgroundService => _isBackgroundService;
  bool get isInitialized => _isInitialized;
  bool get isInitializing => _isInitializing;

  // Initialize with context awareness
  Future<bool> initializeBle({
    required BleService service,
    bool isBackgroundService = false,
  }) async {
    debugPrint('🔄 BleInitializationCoordinator: init called (background=$isBackgroundService, initialized=$_isInitialized)');

    // Check if already initialized before acquiring the lock
    if (_isInitialized && service._isInitialized) {
      debugPrint('✅ BLE service already initialized, returning success');
      return true;
    }

    // Create a local completer for this specific initialization attempt
    final localCompleter = Completer<bool>();

    // Acquire the lock to check/update shared state
    _initMutex.synchronized(() async {
      // If initialized while we were waiting for lock, return success
      if (_isInitialized) {
        debugPrint('✅ BLE became initialized while waiting for lock');
        localCompleter.complete(true);
        return;
      }

      // If another initialization is in progress, mark this one to wait
      if (_isInitializing) {
        debugPrint('⏳ BLE initialization already in progress (background=$_isBackgroundService), this attempt will wait');
        // Don't complete the completer yet, we'll wait for the other initialization

        // Set up a listener for the other initialization
        if (!_completer.isCompleted) {
          _completer.future.then((success) {
            debugPrint('🔄 Waiting initialization notified of completion: $success');
            localCompleter.complete(success);
          }).catchError((e) {
            localCompleter.completeError(e);
          });
        } else {
          // If _completer is completed but _isInitializing is still true, something's wrong
          debugPrint('⚠️ Inconsistent state: _completer completed but _isInitializing true');
          _isInitializing = false; // Fix the inconsistency
          localCompleter.complete(false);
        }
        return;
      }

      // We're the first one to start initialization
      debugPrint('🔄 Starting new BLE initialization (background=$isBackgroundService)');
      _isInitializing = true;
      _isBackgroundService = isBackgroundService;

      // Create a new completer for others to wait on
      if (_completer.isCompleted) {
        // If previous completer completed, create a new one
        _completer = Completer<bool>();
      }
    });

    // If localCompleter was completed in the synchronized block, just return
    if (localCompleter.isCompleted) {
      return localCompleter.future;
    }

    // Otherwise, we're the one doing the initialization
    try {
      // Record initialization context
      await _saveInitializationContext(isBackgroundService);

      // Perform actual initialization
      final success = await service.initialize();

      // Update shared state inside mutex
      await _initMutex.synchronized(() {
        if (success) {
          _isInitialized = true;
          debugPrint('✅ BLE service initialization completed successfully (background=$_isBackgroundService)');
        } else {
          debugPrint('❌ BLE service initialization failed (background=$_isBackgroundService)');
        }

        // Complete both this completer and the shared one
        if (!_completer.isCompleted) {
          _completer.complete(success);
        }

        _isInitializing = false;
      });

      localCompleter.complete(success);
      return success;
    } catch (e) {
      debugPrint('❌ Error during BLE initialization (background=$_isBackgroundService): $e');

      // Update shared state inside mutex
      await _initMutex.synchronized(() {
        if (!_completer.isCompleted) {
          _completer.completeError(e);
        }
        _isInitializing = false;
      });

      localCompleter.completeError(e);
      return false;
    }
  }

  // Add a method that uses the _isBackgroundService field for diagnostic reports
  Map<String, dynamic> getInitializationState() {
    return {
      'isInitialized': _isInitialized,
      'isInitializing': _isInitializing,
      'initializedInBackground': _isBackgroundService,
      'completerIsComplete': _completer.isCompleted,
    };
  }

  // Save initialization context to shared prefs to coordinate between main/background
  Future<void> _saveInitializationContext(bool isBackgroundService) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ble_initialized', true);
      await prefs.setBool('ble_initialized_in_background', isBackgroundService);
      await prefs.setInt('ble_initialization_time', DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('⚠️ Failed to save initialization context: $e');
    }
  }

  // Check previously saved initialization context
  Future<Map<String, dynamic>> getInitializationContext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isInitialized = prefs.getBool('ble_initialized') ?? false;
      final inBackground = prefs.getBool('ble_initialized_in_background') ?? false;
      final timestamp = prefs.getInt('ble_initialization_time') ?? 0;

      return {
        'initialized': isInitialized,
        'inBackground': inBackground,
        'timestamp': timestamp,
        'age': DateTime.now().millisecondsSinceEpoch - timestamp,
        'currentContext': {
          'isInitialized': _isInitialized,
          'isBackgroundService': _isBackgroundService
        }
      };
    } catch (e) {
      debugPrint('⚠️ Failed to get initialization context: $e');
      return {
        'initialized': false,
        'inBackground': false,
        'timestamp': 0,
        'age': 0,
        'currentContext': {
          'isInitialized': _isInitialized,
          'isBackgroundService': _isBackgroundService
        }
      };
    }
  }

  // Reset initialization state (for testing or recovery)
  Future<void> reset() async {
    return _initMutex.synchronized(() async {
      _isInitializing = false;
      _isInitialized = false;
      // Keep _isBackgroundService as is for diagnostic purposes

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('ble_initialized');
      await prefs.remove('ble_initialized_in_background');
      await prefs.remove('ble_initialization_time');
    });
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
    _resilientConnectionManager = ResilientConnectionManager();
    _errorRecoveryManager = ErrorRecoveryManager(this);
    _stabilityMonitor = ConnectionStabilityMonitor();
  }

  // Constants for service/characteristic UUIDs
  static const String serviceUuid = "5f7bc8be-e3c2-4c78-8abd-ab2ad5b8f55e";
  static const String messageCharacteristicUuid = "23ba23c7-4bae-4b7b-a0e3-d9577342501e";
  static const String deviceInfoCharacteristicUuid = "9c0e63a7-843d-4c1b-b8c6-7a9b472e39a2";
  static const String ackCharacteristicUuid = "6e7d5cd8-b36f-4f54-8282-b5e2a98e2d93";

  // Protocol version
  static const int protocolVersion = 1;

  static const int customManufacturerId = 0xFFFF;

  // Max packet size for BLE transmission
  static const int maxPacketSize = 512; // Most BLE implementations limit MTU

  late final ResilientConnectionManager _resilientConnectionManager;
  bool _isJniDetached = false;
  Timer? _jniHealthCheckTimer;

  late var _jniStatusSubject = BehaviorSubject<bool>.seeded(true);
  Stream<bool> get jniConnectionStatus => _jniStatusSubject.stream;

  final BleErrorMetrics errorMetrics = BleErrorMetrics();
  final MessageQueueHealth messageQueueHealth = MessageQueueHealth();

  // Constants for adaptive scanning
  static const Duration minScanInterval = Duration(minutes: 2);
  static const Duration maxScanInterval = Duration(minutes: 30);
  static const Duration activeScanDuration = Duration(seconds: 20);

  // Retry constants
  static const int maxRetryAttempts = 10;
  static const Duration initialRetryDelay = Duration(seconds: 5);
  int? _consecutiveFailures;
  int _consecutiveScanFailures = 0;

  DateTime _lastDeduplicationTime = DateTime.now().subtract(const Duration(minutes: 1));
  int _lastDeviceCount = 0;

  late final ConnectionStabilityMonitor _stabilityMonitor;

  // Status and management fields
  late final String _deviceId;
  final _stateLock = Lock();
  late final ErrorRecoveryManager _errorRecoveryManager;
  bool _isInitialized = false;
  bool _isScanning = false;
  bool _isAdvertising = false;
  DateTime _lastMessageActivity = DateTime.now();
  final _initMutex = Lock();
  bool _initializationInProgress = false;

  late Map<String, Lock> _locks = {};

  final Set<String> _discoveryInProgress = {};

  // Managers
  final CentralManager _centralManager = CentralManager();
  final PeripheralManager _peripheralManager = PeripheralManager();
  final ConnectionPool _connectionPool = ConnectionPool();


  // Stream controllers with better error handling
  late var _devicesSubject = BehaviorSubject<List<BleDevice>>.seeded([]);
  late var _messagesSubject = BehaviorSubject<List<BleMessage>>.seeded([]);
  late var _connectionStateSubject = BehaviorSubject<String>.seeded('Not Initialized');
  late var _errorSubject = PublishSubject<String>();

  late FlutterBackgroundService _backgroundService;
  ServiceInstance? _serviceInstance;

  // Storage
  List<BleDevice> _discoveredDevices = [];
  List<BleMessage> _messages = [];
  final Map<String, StreamSubscription> _subscriptions = {};
  late Map<String, GATTService?> _deviceGattServices = {};

  // Message packet tracking for fragmented messages
  final Map<String, List<Map<String, dynamic>>> _incomingPackets = {};
  final Map<String, Completer<bool>> _outgoingMessageCompleters = {};

  // Adaptive scanning parameters
  Timer? _adaptiveScanTimer;
  Timer? _messageProcessingTimer;
  Timer? _deviceUpdateDebouncer;
  Timer? _retryTimer;

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
  DateTime? get timestamp => null;

  get index => null;
  get status => null;
  get senderId => null;

  // BLE characteristics
  GATTCharacteristic? _ackCharacteristic;
  bool _pendingDeviceListUpdate = false;

  Future<bool> markAsInitialized() async {
    if (_isInitialized) {
      debugPrint('✅ BLE service already fully initialized');
      return true;
    }

    debugPrint('🔄 Performing full external initialization of BLE service');

    try {
      // 1. Initialize device ID
      final prefs = await SharedPreferences.getInstance();
      _deviceId = prefs.getString('device_id') ?? _generateSecureDeviceId();
      await prefs.setString('device_id', _deviceId);
      debugPrint('📱 External init - Device ID: $_deviceId');

      // 2. Initialize stream controllers if needed
      _devicesSubject = _devicesSubject;
      _messagesSubject = _messagesSubject;
      _connectionStateSubject = _connectionStateSubject;
      _errorSubject = _errorSubject;
      _jniStatusSubject = _jniStatusSubject;

      // 3. Initialize collections
      _discoveredDevices = _discoveredDevices;
      _messages = _messages;
      _deviceGattServices = _deviceGattServices;
      _locks = _locks;

      // 4. Load saved data if needed
      await _loadMessages();

      // 5. Start essential timers
      _startMessageProcessingTimer();
      _setupAdaptiveScanning();
      _setupJniHealthCheck();

      _isInitialized = true;
      _connectionStateSubject.add('Ready (External Init)');
      debugPrint('✅ BLE service externally initialized successfully');

      return true;
    } catch (e, stack) {
      debugPrint('❌ External initialization failed: $e');
      debugPrint('❌ Stack trace: $stack');
      return false;
    }
  }

  /// Initialize the BLE service with robust error handling
  Future<bool> initialize() async {
    return _initMutex.synchronized(() async {
    debugPrint('🔄 BleService.initialize() called, isInitialized=$_isInitialized, inProgress=$_initializationInProgress');

    if (_isInitialized) {
      debugPrint('⚠️ BleService already initialized, returning early');
      return true;
    }

    if (_initializationInProgress) {
      debugPrint('⚠️ BleService initialization already in progress, waiting...');
      // Wait for the other initialization to complete
      for (int i = 0; i < 30; i++) { // Wait up to 30 seconds
        await Future.delayed(Duration(seconds: 1));
        if (_isInitialized) return true;
      }
      debugPrint('⚠️ Timed out waiting for other initialization');
      return false;
    }

    _initializationInProgress = true;

    initializePeriodicCleanup();

    try {
      _connectionStateSubject.add('Initializing...');
      debugPrint('BLE Service initializing...');

      // Generate or retrieve device ID
      final prefs = await SharedPreferences.getInstance();
      _deviceId = prefs.getString('device_id') ?? _generateSecureDeviceId();
      await prefs.setString('device_id', _deviceId);
      debugPrint('Device ID: $_deviceId');

      // Attempt to request all permissions directly, ignoring permission_handler errors
      if (Platform.isAndroid) {
        debugPrint('Requesting Android permissions directly...');
        try {
          // Request location permissions first (required for BLE on Android)
          await Permission.location.request();
          await Permission.locationWhenInUse.request();
          await Permission.locationAlways.request();

          final androidInfo = await DeviceInfoPlugin().androidInfo;
          if (androidInfo.version.sdkInt >= 33) { // Android 13+
            debugPrint('Android 13+ detected, requesting nearby devices permission');
            await Permission.nearbyWifiDevices.request();

            // Then request standard BLE permissions
            await Permission.bluetoothScan.request();
            await Permission.bluetoothConnect.request();
            await Permission.bluetoothAdvertise.request();
          } else if (androidInfo.version.sdkInt >= 31) { // Android 12
            debugPrint('Android 12 detected, requesting specific BLE permissions');
            await Permission.bluetoothScan.request();
            await Permission.bluetoothConnect.request();
            await Permission.bluetoothAdvertise.request();
          } else {
            // For older Android versions
            await Permission.bluetooth.request();
          }

          // Log permission status for debugging
          if (androidInfo.version.sdkInt >= 31) {
            debugPrint('BT Scan status: ${await Permission.bluetoothScan.status}');
            debugPrint('BT Connect status: ${await Permission.bluetoothConnect.status}');
            debugPrint('BT Advertise status: ${await Permission.bluetoothAdvertise.status}');
          } else {
            debugPrint('BT status: ${await Permission.bluetooth.status}');
          }
          debugPrint('Location status: ${await Permission.locationWhenInUse.status}');
        } catch (e) {
          // Log but continue - permission_handler might have issues but the operations may still work
          debugPrint('Permission request error: $e');
          debugPrint('Proceeding with BLE operations despite permission warning...');
        }
      }

      // Set up BLE listeners with error handling
      _setupCentralListeners();
      _setupPeripheralListeners();

      // Wait for poweredOn state with better error handling
      debugPrint('Waiting for Bluetooth to be powered on...');
      final bluetoothReady = await _waitForBluetoothPoweredOn();
      debugPrint('Bluetooth state: ${_centralManager.state}');

      if (!bluetoothReady) {
        debugPrint('Bluetooth not ready, but continuing anyway...');
        // We'll continue anyway since we've seen the GATT server can register
      }

      // Load cached messages
      await _loadMessages();

      // Start message processing timer
      _startMessageProcessingTimer();

      // Setup adaptive scanning
      _setupAdaptiveScanning();

      _setupJniHealthCheck();

      _connectionStateSubject.add('Ready');
      debugPrint('BLE service initialized successfully');

      // Start background tasks (continue even if there are errors)
      try {
        debugPrint('Starting BLE advertising...');
        await startAdvertising();
      } catch (e) {
        debugPrint('Error starting advertising: $e');
      }

      // Start initial scan
      try {
        debugPrint('Starting initial BLE scan...');
        await startScan(maxDuration: const Duration(seconds: 30));
      } catch (e) {
        debugPrint('Error starting scan: $e');
      }

      _isInitialized = true;
      _initializationInProgress = false;
      return true;
    } catch (e) {
      debugPrint('❌ BLE service initialization failed: $e');
      _isInitialized = false;
      return false;
    } finally {
      _initializationInProgress = false;
    }
    });
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
    debugPrint('Starting Bluetooth power state check: current state=${_centralManager.state}');
    if (_centralManager.state == BluetoothLowEnergyState.poweredOn) {
      debugPrint('Bluetooth already powered on, proceeding');
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

  void _setupJniHealthCheck() {
    _jniHealthCheckTimer?.cancel();
    _jniHealthCheckTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkJniHealth();
    });
  }

  Future<void> _checkJniHealth() async {
    try {

      await Future.value(_centralManager.state);

      if (_isJniDetached) {
        debugPrint('🔄 JNI connection recovered, reinitializing BLE');
        _isJniDetached = false;
        _jniStatusSubject.add(true);
        await _reinitializeBleAfterDetachment();
      }

      // If we get here, JNI is working
      if (_isJniDetached) {
        debugPrint('🔄 JNI connection restored, reinitializing BLE');
        _isJniDetached = false;
        // Reinitialize BLE subsystems
        _jniStatusSubject.add(true); // Update JNI status
        await _reinitializeBleAfterDetachment();
      }
    } catch (e) {
      if (!_isJniDetached) {
        debugPrint('⚠️ JNI detachment detected: $e');
        _isJniDetached = true;
        _jniStatusSubject.add(false); // Update JNI status
      }
    }
  }

  Future<T> withTimeout<T>(Future<T> operation, Duration timeout, T defaultValue, String operationName) async {
    try {
      return await operation.timeout(timeout, onTimeout: () {
        debugPrint('⏱️ Operation timed out: $operationName');
        return defaultValue;
      });
    } catch (e) {
      debugPrint('❌ Operation failed: $operationName - $e');
      return defaultValue;
    }
  }

  Future<bool> _enableNotificationsWithRetry(
      Peripheral peripheral,
      GATTCharacteristic characteristic,
      {int maxRetries = 5, int baseDelayMs = 500}) async {

    for (int i = 0; i < maxRetries; i++) {
      try {
        await Future.delayed(Duration(milliseconds: baseDelayMs * (i + 1)));
        await _centralManager.setCharacteristicNotifyState(
          peripheral,
          characteristic,
          state: true,
        ).timeout(Duration(seconds: 5), onTimeout: () {
          throw TimeoutException('Notification enabling timed out');
        });
        return true;
      } catch (e) {
        debugPrint('⚠️ Notification enabling attempt ${i+1} failed: $e');
        if (i == maxRetries - 1) return false;
      }
    }
    return false;
  }

  Future<void> _reinitializeBleAfterDetachment() async {
    try {
      // Stop ongoing operations
      try {
        await stopScan();
      } catch (_) {}

      try {
        await stopAdvertising();
      } catch (_) {}

      // Clear in-progress operations
      _discoveryInProgress.clear();
      _connectionPool._activeConnections.clear();
      _deviceGattServices.clear();
      _resilientConnectionManager.reset();

      // Add a brief delay for system stabilization
      await Future.delayed(const Duration(seconds: 1));

      // Restart core functionality
      await startAdvertising();
      await startScan(maxDuration: const Duration(seconds: 30));

      debugPrint('✅ BLE reinitialized successfully after JNI detachment');
    } catch (e) {
      debugPrint('❌ Failed to reinitialize BLE after JNI detachment: $e');
    }
  }

  Future<bool> forceReinitializeBle() async {
    debugPrint('🔄 Force reinitializing BLE subsystems');

    // Reset state flags
    _isJniDetached = false;
    _jniStatusSubject.add(true);

    try {
      // Stop all current operations
      await stopScan();
      await stopAdvertising();

      // Disconnect all devices
      final connectedDevices = _discoveredDevices
          .where((d) => d.isConnected)
          .toList();

      for (final device in connectedDevices) {
        try {
          await _centralManager.disconnect(device.peripheral);
        } catch (_) {
          // Ignore errors during cleanup
        }
      }

      // Clear all caches
      _deviceGattServices.clear();
      _discoveryInProgress.clear();
      _connectionPool._activeConnections.clear();

      // Safely clear pending connections in connection pool
      // Checking if the field is accessible, otherwise skip
      try {
        _connectionPool._pendingConnections.clear();
            } catch (_) {
        // Skip if field structure has changed
      }

      _resilientConnectionManager.reset();

      // Wait for system cleanup
      await Future.delayed(const Duration(seconds: 2));

      // Restart core functionality
      await startAdvertising();
      await startScan(maxDuration: const Duration(seconds: 30));

      debugPrint('✅ BLE reinitialized successfully');
      return true;
    } catch (e) {
      debugPrint('❌ Failed to reinitialize BLE: $e');
      return false;
    }
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
    debugPrint('⏰ Starting message processing timer: running every 10 seconds');
    _messageProcessingTimer = Timer.periodic(
      const Duration(seconds: 10),
          (timer) {
        debugPrint('⏰ Message processing timer fired');
        _processOutgoingMessages();
      },
    );
  }

  /// Set up central manager listeners with error handling
  void _setupCentralListeners() {
    // Discovered device
    _subscriptions['discovered'] = _centralManager.discovered.listen(
          (event) {
        // Process the device without excessive logging
        _handleDiscoveredDevice(event);
      },
      onError: (error) {
        _errorSubject.add('Discovery error: $error');
      },
    );

    // Connection state changed
    _subscriptions['connectionStateChanged'] = _centralManager.connectionStateChanged.listen(
          (event) {
        // Log only connection events
        if (event.state == ConnectionState.connected) {
          debugPrint('🔌 Device connected: ${event.peripheral.uuid}');
        } else if (event.state == ConnectionState.disconnected) {
          debugPrint('🔌 Device disconnected: ${event.peripheral.uuid}');
        }
        _handleConnectionStateChanged(event);
      },
      onError: (error) {
        _errorSubject.add('Connection state error: $error');
      },
    );

    // Characteristic notification
    _subscriptions['characteristicNotified'] = _centralManager.characteristicNotified.listen(
          (event) {
        // Log message-related events
        if (_isServiceCharacteristic(event.characteristic, messageCharacteristicUuid)) {
          debugPrint('📩 Message received from: ${event.peripheral.uuid}');
          _processIncomingMessage(event.peripheral, event.value);
        }
        // Process acknowledgment
        else if (_isServiceCharacteristic(event.characteristic, ackCharacteristicUuid)) {
          debugPrint('✅ Acknowledgment received from: ${event.peripheral.uuid}');
          _processAcknowledgment(event.peripheral, event.value);
        }
      },
      onError: (error) {
        _errorSubject.add('Notification error: $error');
      },
    );
  }

  bool isPakConnectDevice(Advertisement advertisement) {
    // Check name pattern first (fastest check)
    if (advertisement.name != null && advertisement.name!.startsWith('Pak-Msg-')) {
      return true;
    }

    // Check service UUID
    for (var uuid in advertisement.serviceUUIDs) {
      if (uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
        return true;
      }
    }

    // Check manufacturer data
    for (var mfg in advertisement.manufacturerSpecificData) {
      if (mfg.id == customManufacturerId && mfg.data.isNotEmpty && mfg.data[0] == 0x01) {
        return true;
      }
    }

    return false;
  }

  /// Handle discovered device event
  void _handleDiscoveredDevice(DiscoveredEventArgs event) {
    _stateLock.synchronized(() async {
      try {
        final peripheral = event.peripheral;
        final rssi = event.rssi;
        final advertisement = event.advertisement;

        // Skip our own device
        if (peripheral.uuid.toString() == _deviceId) {
          return;
        }

        // Check if this is a PakConnect device
        final isPakDevice = isPakConnectDevice(advertisement);

        // Only process PakConnect devices
        if (!isPakDevice) {
          return;
        }

        // Extract device identifier - using more reliable identifiers
        // Try to use MAC address if available, otherwise use UUID
        final deviceId = peripheral.uuid.toString();

        // Use the device name as a secondary identifier for deduplication
        final deviceName = advertisement.name;

        // Find if we already have this device by ID
        int existingIndex = _discoveredDevices.indexWhere((d) => d.id == deviceId);

        // If not found by ID but has a name, try to find by name (helps with duplicate peripherals)
        if (existingIndex < 0 && deviceName != null && deviceName.isNotEmpty) {
          existingIndex = _discoveredDevices.indexWhere(
                  (d) => d.name == deviceName && d.name != null && d.name!.startsWith('Pak-Msg-')
          );
        }

        bool deviceListChanged = false;

        if (existingIndex >= 0) {
          // Update existing device with new info
          _discoveredDevices[existingIndex] = _discoveredDevices[existingIndex].copyWith(
            peripheral: peripheral, // Update peripheral reference
            rssi: rssi,
            name: deviceName ?? _discoveredDevices[existingIndex].name,
            lastSeen: DateTime.now(),
            supportsRelay: true,
          );
          deviceListChanged = true;
        } else {
          // Add as a new device
          final newDevice = BleDevice.fromPeripheral(
            peripheral,
            rssi,
            advertisement,
          ).copyWith(
            supportsRelay: true,
          );
          _discoveredDevices.add(newDevice);
          deviceListChanged = true;
        }

        // Update UI if needed
        if (deviceListChanged) {
          _pendingDeviceListUpdate = true;
        }

        // Debounce UI updates
        // Debounce UI updates
        _deviceUpdateDebouncer?.cancel();
        _deviceUpdateDebouncer = Timer(const Duration(milliseconds: 300), () {
          if (_pendingDeviceListUpdate) {
            // Only deduplicate if needed
            final now = DateTime.now();
            final deviceCount = _discoveredDevices.length;

            if (now.difference(_lastDeduplicationTime).inSeconds >= 2 &&
                (deviceCount != _lastDeviceCount || deviceCount > 1)) {

              debugPrint('🧹 Starting device deduplication: $deviceCount devices');
              _deduplicateDevices();
              _lastDeduplicationTime = now;
              _lastDeviceCount = deviceCount;
            }

            _devicesSubject.add(_discoveredDevices);
            _pendingDeviceListUpdate = false;
          }
        });

        // Automatically connect to PakConnect devices if needed
        if (_shouldConnectToDevice(deviceId)) {
          _connectToDevice(peripheral);
        }
      } catch (e) {
        debugPrint('Error handling discovered device: $e');
      }
    });
  }

// New helper method to remove duplicate devices
  // Replace the existing _deduplicateDevices method with this one
  void _deduplicateDevices() {
    if (_discoveredDevices.isEmpty) return;

    debugPrint('🧹 Starting device deduplication: ${_discoveredDevices.length} devices');

    // Step 1: Sort by most recently seen first (to prioritize newer data)
    _discoveredDevices.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    // Step 2: Create lookup maps for different identification methods
    final Map<String, BleDevice> byExactId = {};
    final Map<String, List<BleDevice>> byMacAddressRoot = {};
    final Map<String, List<BleDevice>> byPakNameId = {};

    // Step 3: Identify duplicates with different strategies
    for (final device in _discoveredDevices) {
      final deviceId = device.id;
      final deviceName = device.name ?? '';

      // Extract ID from name (if it's a Pak-Msg device)
      String? nameExtractedId;
      if (deviceName.startsWith('Pak-Msg-') && deviceName.length > 8) {
        nameExtractedId = deviceName.substring(8);
      }

      // Add to byExactId map (last seen device with this exact ID wins)
      byExactId[deviceId] = device;

      // Add to MAC address root map if applicable
      if (deviceId.contains('-')) {
        // Extract the MAC portion of a UUID-formatted ID
        final macPortion = deviceId.split('-').last.toLowerCase();
        if (macPortion.length >= 8) {
          if (!byMacAddressRoot.containsKey(macPortion)) {
            byMacAddressRoot[macPortion] = [];
          }
          byMacAddressRoot[macPortion]!.add(device);
        }
      }

      // Add to name-based map if it's a Pak-Msg device
      if (nameExtractedId != null && nameExtractedId.isNotEmpty) {
        if (!byPakNameId.containsKey(nameExtractedId)) {
          byPakNameId[nameExtractedId] = [];
        }
        byPakNameId[nameExtractedId]!.add(device);
      }
    }

    // Step 4: Start with all devices in the byExactId map (already deduped by ID)
    final deduplicatedDevices = byExactId.values.toList();

    // Step 5: Now handle cases where the same device appears with different IDs

    // 5a. Check MAC address duplicates
    final processedMacIds = <String>{};
    byMacAddressRoot.forEach((macRoot, devices) {
      if (devices.length > 1 && !processedMacIds.contains(macRoot)) {
        // Multiple devices with same MAC root, need to pick the best one

        // First, give preference to connected devices
        final connectedDevices = devices.where((d) => d.isConnected).toList();

        if (connectedDevices.isNotEmpty) {
          // Keep the most recently seen connected device
          connectedDevices.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
          final bestDevice = connectedDevices.first;

          // Remove all but this device that share the same MAC root
          for (var device in devices) {
            if (device.id != bestDevice.id) {
              deduplicatedDevices.removeWhere((d) => d.id == device.id);
              debugPrint('🧹 Removed MAC duplicate: ${device.id} in favor of ${bestDevice.id}');
            }
          }
        } else {
          // No connected devices, choose the one with best signal strength
          devices.sort((a, b) => b.rssi.compareTo(a.rssi));
          final bestDevice = devices.first;

          // Remove all but this device that share the same MAC root
          for (var device in devices) {
            if (device.id != bestDevice.id) {
              deduplicatedDevices.removeWhere((d) => d.id == device.id);
              debugPrint('🧹 Removed MAC duplicate: ${device.id} in favor of ${bestDevice.id} (better signal)');
            }
          }
        }

        processedMacIds.add(macRoot);
      }
    });

    // 5b. Check name-extracted ID duplicates
    final processedNameIds = <String>{};
    byPakNameId.forEach((nameId, devices) {
      if (devices.length > 1 && !processedNameIds.contains(nameId)) {
        // Multiple devices with same name ID, need to pick the best one

        // First, give preference to devices with both matching name and MAC address
        var bestDevice = devices.first;
        bool foundBestMatch = false;

        for (var device in devices) {
          final deviceId = device.id;
          if (deviceId.contains(nameId) || (deviceId.contains('-') && deviceId.split('-').last.contains(nameId))) {
            // This device has the name ID in its device ID - strong indicator it's the right one
            bestDevice = device;
            foundBestMatch = true;
            break;
          }
        }

        if (!foundBestMatch) {
          // If no perfect match, prefer connected or better signal
          final connectedDevices = devices.where((d) => d.isConnected).toList();

          if (connectedDevices.isNotEmpty) {
            bestDevice = connectedDevices.first;
          } else {
            // Sort by signal strength
            devices.sort((a, b) => b.rssi.compareTo(a.rssi));
            bestDevice = devices.first;
          }
        }

        // Remove duplicates, keeping only the best device
        for (var device in devices) {
          if (device.id != bestDevice.id) {
            deduplicatedDevices.removeWhere((d) => d.id == device.id);
            debugPrint('🧹 Removed name-based duplicate: ${device.id} in favor of ${bestDevice.id}');
          }
        }

        processedNameIds.add(nameId);
      }
    });

    // Step 6: Log results and update the list
    final removedCount = _discoveredDevices.length - deduplicatedDevices.length;
    debugPrint('🧹 Deduplication complete: Removed $removedCount devices, kept ${deduplicatedDevices.length}');

    _discoveredDevices = deduplicatedDevices;
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

  Future<bool> _isDeviceConnected(Peripheral peripheral) async {
    try {
      final deviceIndex = _discoveredDevices.indexWhere(
              (d) => d.peripheral.uuid == peripheral.uuid
      );

      if (deviceIndex < 0) return false;

      return _discoveredDevices[deviceIndex].connectionState ==
          ConnectionState.connected;
    } catch (e) {
      return false;
    }
  }

  void _handleConnectionStateChanged(PeripheralConnectionStateChangedEventArgs event) async {
    try {
    final peripheralId = event.peripheral.uuid.toString();
    debugPrint('🔌 Connection state changed for device: ${event.peripheral.uuid}, state: ${event.state}');

    if (_isJniDetached) {
      debugPrint('⚠️ JNI is detached, cannot process connection state change');
      // Schedule a JNI health check sooner
      Future.delayed(Duration(seconds: 1), () => _checkJniHealth());
      return;
    }

    _stabilityMonitor.recordConnectionEvent(peripheralId, event.state == ConnectionState.connected);

    // Find the device index
    final index = _discoveredDevices.indexWhere(
            (d) => d.peripheral.uuid == event.peripheral.uuid
    );

    if (index >= 0) {
      _discoveredDevices[index] = _discoveredDevices[index].copyWith(
          connectionState: event.state,
          deviceConnectionState: event.state == ConnectionState.connected ?
          DeviceConnectionState.connecting :
          DeviceConnectionState.disconnected
      );
      _devicesSubject.add(_discoveredDevices);
    }

    // If disconnected, immediately update state and clean up
    if (event.state == ConnectionState.disconnected) {
      // Clear discovery in progress flag
      _discoveryInProgress.remove(peripheralId);

      // Remove from GATT services cache
      _deviceGattServices.remove(peripheralId);

      // Notify connection pool
      _connectionPool.connectionCompleted(event.peripheral);

      // Update device state immediately
      if (index >= 0) {
        _discoveredDevices[index] = _discoveredDevices[index].copyWith(
            connectionState: ConnectionState.disconnected,
            deviceConnectionState: DeviceConnectionState.disconnected
        );
        _devicesSubject.add(_discoveredDevices);
      }

      // Schedule retry if needed
      if (_hasMessagesFor(peripheralId)) {
        _scheduleMessageRetry(peripheralId);
      }
      return;
    }

    if (index >= 0) {
      // Update connection state and analytics
      final now = DateTime.now();
      final currentDevice = _discoveredDevices[index];

      // When the device connects, mark it as connecting until services are discovered
      final newDeviceConnectionState = event.state == ConnectionState.connected ?
      DeviceConnectionState.connecting :
      DeviceConnectionState.disconnected;

      debugPrint('🔌 Updating device connection state to: $newDeviceConnectionState');

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
      debugPrint('🔌 Updated device list published');

      // If connected, discover services
      if (event.state == ConnectionState.connected) {
        // CRITICAL: Check if discovery is already in progress for this device
        if (_discoveryInProgress.contains(peripheralId)) {
          debugPrint('⚠️ Service discovery already in progress for: $peripheralId, skipping duplicate');
          return;
        }

        if (_discoveredDevices[index].deviceConnectionState != DeviceConnectionState.connected) {
          _discoveredDevices[index] = _discoveredDevices[index].copyWith(
              deviceConnectionState: DeviceConnectionState.connecting
          );
        }

        // Mark discovery as in progress
        _discoveryInProgress.add(peripheralId);

        try {
          await _discoverServices(event.peripheral);

          // Now update to fully connected state after services discovered
          final updatedIndex = _discoveredDevices.indexWhere(
                  (d) => d.peripheral.uuid == event.peripheral.uuid
          );

          if (updatedIndex >= 0) {
            debugPrint('🔌 Updating to fully connected state after service discovery');
            _discoveredDevices[updatedIndex] = _discoveredDevices[updatedIndex].copyWith(
                deviceConnectionState: DeviceConnectionState.connected
            );
            _devicesSubject.add(_discoveredDevices);

            // CRITICAL ADDITION: Immediately try to process any pending messages
            // for this device now that it's fully connected
            debugPrint('🔌 Device now fully connected - checking for pending messages');
            _processOutgoingMessages();
          }
        } catch (e) {
          debugPrint('❌ Service discovery failed: $e');
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
        } finally {
          // Always clear the discovery in progress flag, even if an error occurred
          _discoveryInProgress.remove(peripheralId);
        }
      }
    }
  } catch (e) {
  debugPrint('❌ Error handling connection state change: $e');
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
    if (!_isInitialized || _deviceId.isEmpty) {
      debugPrint('⚠️ BLE service not fully initialized for foreground handling');

      // Try to fix it
      try {
        await markAsInitialized(); // This will now properly initialize deviceId
      } catch (e) {
        debugPrint('❌ Failed to initialize on foreground: $e');
        return;
      }
    }
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

    final isUnstable = _stabilityMonitor.isConnectionUnstable(recipientId);

    // Exponential backoff with jitter
    final baseDelay = initialRetryDelay.inMilliseconds;
    final maxBackoff = math.min(30, math.pow(2, maxAttempts).toInt());
    final jitter = math.Random().nextInt(1000);
    final stabilityMultiplier = isUnstable ? 2.0 : 1.0;
    final delayMs = (math.min(300000, baseDelay * maxBackoff) + jitter) * stabilityMultiplier.toInt();

    if (isUnstable) {
      debugPrint('⚠️ Using extended backoff (${stabilityMultiplier}x) for unstable device: $recipientId');
    }

    // Schedule retry with the calculated delay
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
  Future<int> _getNegotiatedMtu(Peripheral peripheral, {int defaultMtu = 23, int attempt = 1}) async {
    try {
      // First check device cache
      final deviceIndex = _discoveredDevices.indexWhere(
              (d) => d.peripheral.uuid == peripheral.uuid
      );

      if (deviceIndex >= 0 && _discoveredDevices[deviceIndex].mtu != null) {
        return _discoveredDevices[deviceIndex].mtu!;
      }

      // Default MTU values by platform
      int mtu = defaultMtu; // BLE minimum

      if (Platform.isAndroid) {
        try {
          debugPrint('🔄 Requesting MTU negotiation (attempt $attempt)...');
          final negotiatedMtu = await _centralManager.requestMTU(
              peripheral,
              mtu: 512
          ).timeout(const Duration(seconds: 5), onTimeout: () {
            debugPrint('⏱️ MTU negotiation timed out');
            throw TimeoutException('MTU negotiation timed out');
          });

          debugPrint('✅ MTU negotiation successful: $negotiatedMtu');
          mtu = negotiatedMtu;
        } catch (e) {
          debugPrint('⚠️ MTU negotiation failed: $e');

          // Retry with a smaller MTU if this is not the last attempt
          if (attempt < 3) {
            debugPrint('🔄 Retrying with smaller MTU request...');
            await Future.delayed(Duration(milliseconds: 200 * attempt));
            // Request progressively smaller MTU values on retries
            return _getNegotiatedMtu(
                peripheral,
                defaultMtu: defaultMtu,
                attempt: attempt + 1
            );
          }

          mtu = defaultMtu; // Fallback to minimum
        }
      } else if (Platform.isIOS) {
        // iOS typically has higher default MTU
        mtu = 185;
      }

      // Cache the value for future use
      if (deviceIndex >= 0) {
        _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
            mtu: mtu
        );
      }

      return mtu;
    } catch (e) {
      debugPrint('Error getting MTU: $e');
      return defaultMtu; // Absolute fallback to BLE minimum
    }
  }

  Future<bool> recoverBluetoothScanner() async {
    debugPrint('🔄 Attempting to recover BluetoothLeScanner');

    try {
      // First try stopping any ongoing scans
      if (_isScanning) {
        try {
          await _centralManager.stopDiscovery();
          _isScanning = false;
        } catch (e) {
          // Ignore errors during cleanup
          debugPrint('⚠️ Error stopping scan during recovery: $e');
        }
      }

      // Wait a moment to let system stabilize
      await Future.delayed(const Duration(seconds: 2));

      // Check bluetooth state
      if (_centralManager.state != BluetoothLowEnergyState.poweredOn) {
        debugPrint('⚠️ Bluetooth not powered on during recovery, current state: ${_centralManager.state}');
        return false;
      }

      // Try a simple scan operation to test the scanner
      try {
        await _centralManager.startDiscovery();
        await Future.delayed(const Duration(seconds: 1));
        await _centralManager.stopDiscovery();
        debugPrint('✅ Scanner recovery successful');
        return true;
      } catch (e) {
        debugPrint('❌ Scanner test failed during recovery: $e');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Scanner recovery failed: $e');
      return false;
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

    if (_centralManager.state != BluetoothLowEnergyState.poweredOn) {
      debugPrint('⚠️ Cannot start scan: Bluetooth is not powered on (Current state: ${_centralManager.state})');

      // Try to force a state check and wait
      try {
        // Wait for bluetooth to power on with timeout
        final completer = Completer<bool>();
        late StreamSubscription subscription;

        subscription = _centralManager.stateChanged.listen((event) {
          if (event.state == BluetoothLowEnergyState.poweredOn) {
            if (!completer.isCompleted) {
              completer.complete(true);
            }
            subscription.cancel();
          }
        });

        // Set a timeout
        Future.delayed(const Duration(seconds: 5), () {
          if (!completer.isCompleted) {
            completer.complete(false);
            subscription.cancel();
          }
        });

        final success = await completer.future;
        if (!success) {
          debugPrint('⚠️ Timed out waiting for Bluetooth to power on');
          return false;
        }
      } catch (e) {
        debugPrint('⚠️ Error waiting for Bluetooth state: $e');
        return false;
      }
    }

    try {
      debugPrint('Starting PakConnect-specific scan...');

      // Method 1: Try service UUID specific scan first (most efficient)
      try {
        debugPrint('Attempting scan with service UUID filter: $serviceUuid');
        await _centralManager.startDiscovery(
          serviceUUIDs: [UUID.fromString(serviceUuid)],
        );
        debugPrint('Service UUID filtered scan started successfully');
        _resetScanFailureCounter();
      } catch (e) {
        debugPrint('Service UUID filtered scan failed: $e');

        // Record the scan failure in metrics
        errorMetrics.recordScanFailure();

        // Check if this is a bluetoothLeScanner null issue
        if (e.toString().contains('bluetoothLeScanner must not be null')) {
          debugPrint('⚠️ BluetoothLeScanner is null, attempting to recover...');

          // Wait briefly to allow system to stabilize
          await Future.delayed(const Duration(seconds: 2));

          // Try to reset BLE subsystem if this is a recurring issue
          if (_consecutiveScanFailures > 2) {
            debugPrint('🔄 Multiple scan failures detected, attempting BLE reset');
            await forceReinitializeBle();
            _consecutiveScanFailures = 0;
          } else {
            _consecutiveScanFailures = (_consecutiveScanFailures) + 1;
          }
        }

        // Fall back to general scan
        debugPrint('Falling back to general scan');
        try {
          await _centralManager.startDiscovery();
          debugPrint('General scan started successfully');
          _resetScanFailureCounter();
        } catch (fallbackError) {
          debugPrint('❌ Even general scan failed: $fallbackError');

          // Record another scan failure
          errorMetrics.recordScanFailure();

          // Return failure
          final errorMsg = 'Both scan methods failed: $e, fallback: $fallbackError';
          _connectionStateSubject.add(errorMsg);
          _errorSubject.add(errorMsg);
          return false;
        }
      }

      _isScanning = true;
      _connectionStateSubject.add('Scanning for PakConnect devices');
      debugPrint('Scanning for PakConnect devices...');

      // Auto-stop scanning after specified duration to save battery
      if (maxDuration != null) {
        debugPrint('Scan will auto-stop after ${maxDuration.inSeconds} seconds');
        Future.delayed(maxDuration, () {
          if (_isScanning) {
            debugPrint('Auto-stopping scan after timeout');
            stopScan();
          }
        });
      }

      return true;
    } catch (e) {
      final errorMsg = 'PakConnect scan error: $e';
      _connectionStateSubject.add(errorMsg);
      _errorSubject.add(errorMsg);
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
      debugPrint('📱 ADVERTISING TEST: Scanning for our own advertisement using system API');
      try {
        // Use the plugin to scan for nearby devices
        final devices = await _centralManager.retrieveConnectedPeripherals();
        debugPrint('📱 Connected peripherals: ${devices.length}');
        for (var device in devices) {
          debugPrint('  - ${device.uuid}');
        }
      } catch (e) {
        debugPrint('❌ Could not retrieve peripherals: $e');
      }
    }

    try {
      // Create GATT service structure
      debugPrint('Creating GATT service for advertising...');
      final service = await _createGattService();

      // Add service to peripheral manager
      debugPrint('Adding service to peripheral manager...');
      await _peripheralManager.addService(service);

      // Start advertising with relay capability indication
      final deviceIdSuffix = _deviceId.substring(0, math.min(_deviceId.length, 8));
      //final advertisementName = 'Pak-Msg-${_deviceId.substring(0, math.min(_deviceId.length, 8))}';
      final advertisementName = 'Pak-Msg-$deviceIdSuffix';
      debugPrint('Starting advertisement as: $advertisementName');

      // Start advertising with relay capability indication
      final manufacturerData = [
        ManufacturerSpecificData(
          id: customManufacturerId,
          data: Uint8List.fromList([
            0x01, // Relay capability flag
            protocolVersion,// Protocol version
          ]),
        )
      ];

      // Start advertising
      await _peripheralManager.startAdvertising(
        Advertisement(
          name: advertisementName,
          serviceUUIDs: [UUID.fromString(serviceUuid)],
          manufacturerSpecificData: manufacturerData,
        ),
      );

      _isAdvertising = true;
      debugPrint('Advertising started successfully');
      _connectionStateSubject.add('Advertising');
      debugPrint('Starting advertisement as: Pak-Msg-$_deviceId');
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

  // Add this to BleService
  Future<void> dumpDeviceState(BleDevice device) async {
    debugPrint('=== DEVICE STATE DUMP ===');
    debugPrint('Device ID: ${device.id}');
    debugPrint('Name: ${device.name ?? "Unknown"}');
    debugPrint('RSSI: ${device.rssi}');
    debugPrint('Connection State: ${device.connectionState}');
    debugPrint('Device Connection State: ${device.deviceConnectionState}');
    debugPrint('Last Seen: ${device.lastSeen}');
    debugPrint('Supports Relay: ${device.supportsRelay}');
    debugPrint('Failed Attempts: ${device.failedConnectionAttempts}');
    debugPrint('Can Connect: ${device.canConnect}');
    debugPrint('========================');
  }

  /// Connect to a specific device
  Future<bool> connectToDevice(BleDevice device) async {
    return _connectToDevice(device.peripheral);
  }

  /// Internal connect to device with improved pooling and retry logic
  Future<bool> _connectToDevice(Peripheral peripheral) async {
    final peripheralId = peripheral.uuid.toString();

    // Check if we're dealing with JNI detachment
    if (_isJniDetached) {
      debugPrint('⚠️ Cannot connect: JNI is currently detached');
      return false;
    }

    // Use resilient connection manager
    if (!_resilientConnectionManager.canAttemptConnection(peripheralId)) {
      debugPrint('⚠️ Skipping connection attempt to $peripheralId (in cooldown)');
      return false;
    }

    _resilientConnectionManager.markConnectionAttemptStarted(peripheralId);

    return _stateLock.synchronized(() async {
      try {
        // Ensure proper status updates
        _connectionStateSubject.add('Connecting to device...');

        // Find device in our tracking list before connection attempt
        final deviceIndexBefore = _discoveredDevices.indexWhere(
                (d) => d.peripheral.uuid == peripheral.uuid
        );

        if (deviceIndexBefore >= 0) {
          // Update state to connecting in our tracking
          _discoveredDevices[deviceIndexBefore] = _discoveredDevices[deviceIndexBefore].copyWith(
              deviceConnectionState: DeviceConnectionState.connecting
          );
          _devicesSubject.add(_discoveredDevices);
        }

        // Explicitly create a connection request with timeout
        await _centralManager.connect(peripheral).timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              debugPrint('⚠️ Connection timed out for device: $peripheralId');
              throw TimeoutException('Connection timed out');
            }
        );

        // Wait a short time for connection events to propagate
        await Future.delayed(const Duration(milliseconds: 500));

        // Update activity timestamp
        _lastMessageActivity = DateTime.now();

        _resilientConnectionManager.markConnectionAttemptSucceeded(peripheralId);
        debugPrint('✅ Connect call successful for device: $peripheralId');

        return true;
      } catch (e) {
        debugPrint('❌ Connection error: $e');
        errorMetrics.recordConnectionFailure(peripheralId);

        // Update failure count and status
        final deviceIndex = _discoveredDevices.indexWhere(
                (d) => d.peripheral.uuid == peripheral.uuid
        );

        if (deviceIndex >= 0) {
          _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
            failedConnectionAttempts: _discoveredDevices[deviceIndex].failedConnectionAttempts + 1,
            deviceConnectionState: DeviceConnectionState.disconnected,
          );
          _devicesSubject.add(_discoveredDevices);
        }

        // Clean up resources after failure
        await _releaseConnectionResources(peripheral);

        _resilientConnectionManager.markConnectionAttemptFailed(peripheralId);
        return false;
      }
    });
  }

// New helper method to clean up resources after connection failures
  Future<void> _releaseConnectionResources(Peripheral peripheral) async {
    final peripheralId = peripheral.uuid.toString();

    try {
      // Try to force disconnect to clean up resources
      await _centralManager.disconnect(peripheral);
    } catch (e) {
      // Log but don't propagate errors during cleanup
      debugPrint('Disconnect during cleanup failed: $e');
    }

    // Clear discovery in progress flag
    _discoveryInProgress.remove(peripheralId);

    // Notify connection pool
    _connectionPool.connectionCompleted(peripheral);

    // Clear any cached GATT services
    _deviceGattServices.remove(peripheralId);
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
    debugPrint('💬 BleService.sendMessage called: to=$recipientId, content=$content');

    // Log all discovered devices for debugging
    debugPrint('💬 Current discovered devices:');
    for (final device in _discoveredDevices) {
      debugPrint('   - ID: ${device.id}, Name: ${device.name ?? "Unknown"}, Connected: ${device.isConnected}, Connection state: ${device.deviceConnectionState}');
    }

    // INSTEAD OF USING THE LOCK, WHICH MIGHT BE CAUSING DEADLOCK
    try {
      if (!_isInitialized) {
        debugPrint('❌ BleService not initialized');
        _connectionStateSubject.add('Not initialized');
        return false;
      }

      final messageId = '${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(10000)}';
      debugPrint('💬 Creating message with ID: $messageId');
      messageQueueHealth.recordMessageSent();

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
      debugPrint('💬 Message added to queue: $messageId');

      // Save messages to persistent storage
      await _saveMessages();
      debugPrint('💬 After saving messages, checking if device is connected...');

      // Update activity timestamp
      _lastMessageActivity = DateTime.now();

      final device = findDeviceByAnyId(recipientId);

      if (device != null) {
        debugPrint('💬 Found device: ${device.name}, isConnected: ${device.isConnected}, state: ${device.deviceConnectionState}');

        if (device.isConnected) {
          debugPrint('💬 Device is connected, will try direct send');

          // Mark as pending immediately
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index >= 0) {
            _messages[index] = _messages[index].copyWith(
                status: MessageStatus.pending
            );
          }

          // Immediately try to get the cached service
          final service = _deviceGattServices[device.id];
          if (service != null) {
            debugPrint('💬 Found cached GATT service, looking for characteristic');

            // Find message characteristic
            final characteristic = _findCharacteristic(service, messageCharacteristicUuid);
            if (characteristic != null) {
              debugPrint('💬 Found message characteristic, preparing message for direct transmission');

              try {
                // Convert message to JSON and then to bytes
                final messageJson = jsonEncode(message.toJson());
                debugPrint('💬 Message JSON: ${messageJson.substring(0, math.min(messageJson.length, 100))}');
                final messageBytes = Uint8List.fromList(utf8.encode(messageJson));

                debugPrint('💬 DIRECT WRITE ATTEMPT: About to write ${messageBytes.length} bytes');
                try {
                  // Direct write to characteristic - this is the critical step!
                  await _centralManager.writeCharacteristic(
                    device.peripheral,
                    characteristic,
                    value: messageBytes,
                    type: GATTCharacteristicWriteType.withResponse,
                  );
                  debugPrint('💬 DIRECT WRITE SUCCESSFUL! ✅');

                  final deliveryTime = DateTime.now().difference(message.timestamp);
                  messageQueueHealth.recordDeliverySuccess(deliveryTime);

                  // Update message status
                  final index = _messages.indexWhere((m) => m.id == message.id);
                  if (index >= 0) {
                    _messages[index] = _messages[index].copyWith(
                        status: MessageStatus.delivered
                    );
                    _messagesSubject.add(_messages);
                    await _saveMessages();
                  }
                  _messagesSubject.add(_messages);
                  await _saveMessages();

                  // Complete the future
                  if (!completer.isCompleted) {
                    completer.complete(true);
                  }

                  return true;
                } catch (writeError) {
                  debugPrint('❌ Direct write failed: $writeError');
                  messageQueueHealth.recordDeliveryFailure();

                  // Try without response as fallback
                  try {
                    debugPrint('💬 Attempting write without response as fallback');
                    await _centralManager.writeCharacteristic(
                      device.peripheral,
                      characteristic,
                      value: messageBytes,
                      type: GATTCharacteristicWriteType.withoutResponse,
                    );
                    debugPrint('💬 Fallback write SUCCESSFUL! ✅');

                    // Update message status
                    final index = _messages.indexWhere((m) => m.id == message.id);
                    if (index >= 0) {
                      _messages[index] = _messages[index].copyWith(
                          status: MessageStatus.delivered
                      );
                      _messagesSubject.add(_messages);
                      await _saveMessages();

                      // Complete the future
                      if (!completer.isCompleted) {
                        completer.complete(true);
                      }
                    }

                    return true;
                  } catch (fallbackError) {
                    debugPrint('❌ Fallback write also failed: $fallbackError');
                    messageQueueHealth.recordDeliveryFailure();
                  }
                }
              } catch (e) {
                debugPrint('❌ Error preparing message: $e');
              }
            } else {
              debugPrint('❌ Message characteristic not found in the service!');
            }
          } else {
            debugPrint('❌ No cached GATT service found for the device');
          }
        } else {
          debugPrint('❌ Device found but not connected, state: ${device.deviceConnectionState}');
        }
      } else {
        debugPrint('❌ Device not found using improved lookup');
      }

      // If we get here, the immediate send failed or wasn't possible
      debugPrint('💬 Direct send not successful, will use normal message queue');

      // Mark as pending for the message processor to pick up
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index >= 0) {
        _messages[index] = _messages[index].copyWith(
            status: MessageStatus.pending
        );
      }
      _messagesSubject.add(_messages);
      await _saveMessages();

      // Force immediate message processing
      _processOutgoingMessages();

      // Set a timeout
      Future.delayed(const Duration(seconds: 30), () {
        if (!completer.isCompleted) {
          debugPrint('💬 Message delivery timed out after 30 seconds');
          completer.complete(false);
        }
      });

      return completer.future;
    } catch (e) {
      debugPrint('❌ Error in sendMessage: $e');
      return false;
    }
  }

// Add this method to the BleService class
  Future<bool> sendMessageDirect(String recipientId, String content) async {
    try {
      // Find device with more aggressive lookup
      BleDevice? device = findDeviceByAnyId(recipientId);

      if (device == null) {
        debugPrint('📱 Device not found, starting scan to find it');
        await startScan(maxDuration: Duration(seconds: 10));

        // Wait for scan results
        await Future.delayed(Duration(seconds: 3));
        device = findDeviceByAnyId(recipientId);

        if (device == null) {
          debugPrint('📱 Device still not found after scanning');
          return false;
        }
      }

      // Connect if not already connected
      if (!device.isConnected) {
        final connected = await _connectToDevice(device.peripheral);
        if (!connected) {
          debugPrint('📱 Failed to connect to device');
          return false;
        }

        // Give time for service discovery
        await Future.delayed(Duration(milliseconds: 500));
      }

      // Get cached service or discover
      GATTService? service = _deviceGattServices[device.id];
      if (service == null) {
        try {
          await _discoverServices(device.peripheral);
          service = _deviceGattServices[device.id];

          if (service == null) {
            throw Exception("Service discovery succeeded but service not found");
          }
        } catch (e) {
          debugPrint('📱 Service discovery failed: $e');
          return false;
        }
      }

      // Find characteristic and send
      final messageChar = service.characteristics.firstWhere(
              (c) => c.uuid.toString().toLowerCase() == messageCharacteristicUuid.toLowerCase(),
          orElse: () => throw Exception("Message characteristic not found")
      );

      // Create message
      final message = {
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'senderId': _deviceId,
        'recipientId': recipientId,
        'content': content,
        'timestamp': DateTime.now().toIso8601String()
      };

      final messageJson = jsonEncode(message);
      final messageBytes = Uint8List.fromList(utf8.encode(messageJson));

      // Try with response first
      try {
        await _centralManager.writeCharacteristic(
            device.peripheral,
            messageChar,
            value: messageBytes,
            type: GATTCharacteristicWriteType.withResponse
        ).timeout(Duration(seconds: 10));

        return true;
      } catch (e) {
        debugPrint('📱 Write with response failed, trying without response: $e');

        // Try without response as fallback
        await _centralManager.writeCharacteristic(
            device.peripheral,
            messageChar,
            value: messageBytes,
            type: GATTCharacteristicWriteType.withoutResponse
        ).timeout(Duration(seconds: 5));

        return true;
      }
    } catch (e) {
      debugPrint('📱 Direct send failed with error: $e');
      return false;
    }
  }

  /// Update message status with better tracking
  Future<void> _updateMessageStatus(
      String messageId,
      MessageStatus status, {
        int? attemptCount,
        DateTime? lastAttempt,
      }) async {
    debugPrint('🔄 _updateMessageStatus called for message: $messageId, status: $status');

    return _stateLock.synchronized(() async {
      try {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index >= 0) {
          debugPrint('✅ Message found at index $index');
          final message = _messages[index];
          final updatedMessage = message.copyWith(
            status: status,
            attemptCount: attemptCount ?? message.attemptCount,
            lastAttempt: lastAttempt ?? message.lastAttempt,
          );

          _messages[index] = updatedMessage;
          _messagesSubject.add(_messages);
          await _saveMessages();
          debugPrint('✅ Message status updated successfully to: $status');

          // If delivered or acknowledged, complete the future
          if (status == MessageStatus.delivered || status == MessageStatus.ack) {
            if (_outgoingMessageCompleters.containsKey(messageId) &&
                !_outgoingMessageCompleters[messageId]!.isCompleted) {
              _outgoingMessageCompleters[messageId]!.complete(true);
              _outgoingMessageCompleters.remove(messageId);
              debugPrint('✅ Message completer completed with success');
            }
          }
        } else {
          debugPrint('❌ Message not found with ID: $messageId');
        }
      } catch (e, stack) {
        debugPrint('❌ Error updating message status: $e');
        debugPrint('❌ Stack trace: $stack');
      }
    });
  }

  /// Process operations in batches to reduce radio usage
  Future<void> _batchOperations<T>(List<T> items, Future<void> Function(T item) operation) async {
    final batchSize = 5; // Configurable batch size

    for (int i = 0; i < items.length; i += batchSize) {
      final end = math.min(i + batchSize, items.length);
      final batch = items.sublist(i, end);

      // Process each item in the batch
      for (final item in batch) {
        try {
          await operation(item);
        } catch (e, stackTrace) {
          debugPrint('Batch operation error for item: $e');
          debugPrint('Stack trace: $stackTrace');
          // Continue with next item, don't fail the whole batch
        }
      }

      // Small delay between batches to avoid blocking UI thread
      if (end < items.length) {
        await Future.delayed(Duration(milliseconds: 10));
      }
    }
  }

  Future<bool> _isValidRecipient(String recipientId) async {
    // Check if this matches any contact's BLE device ID
    final foundInContacts = InMemoryStore.contacts.any((c) =>
    c.bleDeviceId == recipientId
    );

    // If not found in contacts, this message might be orphaned
    return foundInContacts;
  }

  /// Process outgoing messages with improved batching and efficiency
  Future<void> _processOutgoingMessages() async {
    return _stateLock.synchronized(() async {
      try {
        debugPrint('🔄 _processOutgoingMessages started');

        if (_deviceId.isEmpty) {
          debugPrint('⚠️ Device ID not initialized, cannot process messages');
          return;
        }

        final messagesToRemove = <String>[];
        for (final message in _messages) {
          if (message.senderId == _deviceId &&
              message.status != MessageStatus.delivered &&
              message.status != MessageStatus.ack) {
            // Check if recipient still exists
            final isValid = await _isValidRecipient(message.recipientId);
            if (!isValid) {
              messagesToRemove.add(message.id);
            }
          }
        }

        // Remove orphaned messages
        if (messagesToRemove.isNotEmpty) {
          _messages.removeWhere((m) => messagesToRemove.contains(m.id));
          _messagesSubject.add(_messages);
          await _saveMessages();
          debugPrint('🧹 Removed ${messagesToRemove.length} orphaned messages');
        }

        // Update activity timestamp since we have pending messages
        _lastMessageActivity = DateTime.now();

        // Get messages that need processing - using HYBRID approach
        debugPrint('🔍 Getting retriable messages');
        final undeliveredMessages = await _getRetriableMessagesHybrid();
        _sortMessagesByPriority(undeliveredMessages);
        debugPrint('📋 Found ${undeliveredMessages.length} undelivered messages');
        messageQueueHealth.updatePendingCount(undeliveredMessages.length);

        // Skip processing if no messages match criteria
        if (undeliveredMessages.isEmpty) {
          debugPrint('✓ No messages to process, exiting');
          return;
        }

        // Group messages by recipient
        final messagesByRecipient = _groupMessagesByRecipient(undeliveredMessages);
        debugPrint('📊 Messages grouped by ${messagesByRecipient.length} recipients');

        // Find connected devices
        final connectedDevices = _discoveredDevices.where((d) => d.isConnected).toList();
        debugPrint('🔌 Found ${connectedDevices.length} connected devices');

        if (connectedDevices.isEmpty) {
          debugPrint('❌ No connected devices found for sending messages');
          await _startScanIfNeeded();
          return;
        }

        // Sort connected devices by connection priority
        connectedDevices.sort((a, b) =>
            (b.connectionPriority).compareTo(a.connectionPriority));

        // Log the connected devices for debugging
        for (int i = 0; i < connectedDevices.length; i++) {
          debugPrint('  Device $i: ${connectedDevices[i].id}, name: ${connectedDevices[i].name ?? "unknown"}');
        }

        // Process connected devices in batches
        debugPrint('🔄 Processing messages for connected devices');
        await _batchOperations(connectedDevices, (device) async {
          final deviceId = device.id;
          if (deviceId.isEmpty) {
            debugPrint('⚠️ Device has null or empty ID, skipping');
            return;
          }

          debugPrint('📱 Processing device: $deviceId');
          final deviceMessages = messagesByRecipient[deviceId];

          if (deviceMessages != null && deviceMessages.isNotEmpty) {
            debugPrint('📨 Found ${deviceMessages.length} messages for device: $deviceId');
            // Process this device's messages in batches
            await _batchOperations(deviceMessages, (message) async {
              debugPrint('🔄 Processing message ${message.id} for device: $deviceId');
              await _sendSingleMessage(message, device);
            });
          } else {
            debugPrint('ℹ️ No messages for device: $deviceId');
          }
        });

        // Handle relay for messages that couldn't be delivered directly
        debugPrint('🔄 Handling undelivered messages');
        await _handleUndeliveredMessages();

        // Start scanning if needed for remaining messages
        debugPrint('🔍 Checking if scan needed');
        await _startScanIfNeeded();

        // Reset retry counter after successful processing
        _resetRetryCounter();
        debugPrint('✅ _processOutgoingMessages completed');
      } catch (e, stackTrace) {
        debugPrint('❌ Error in _processOutgoingMessages: $e');
        debugPrint('❌ Stack trace: $stackTrace');
        _scheduleRetry();
      }
    });
  }

  static BleMessage createHighPriorityMessage({
    required String id,
    required String senderId,
    required String recipientId,
    required String content,
    required DateTime timestamp,
  }) {
    return BleMessage(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      content: content,
      timestamp: timestamp,
      status: MessageStatus.created,
      metadata: {'priority': 'high'},
    );
  }

  Future<List<BleMessage>> _getRetriableMessagesHybrid() async {
    final deviceId = _deviceId;
    if (deviceId.isEmpty) {
      debugPrint('⚠️ Device ID not initialized, returning empty message list');
      return [];
    }
    final now = DateTime.now();

    // Check if we have enough messages to benefit from isolate processing
    // This threshold can be adjusted based on your device performance needs
    final largeMessageThreshold = 50;

    if (_messages.length > largeMessageThreshold) {
      try {
        // For large batches, use compute() with serialized data

        // 1. Convert messages to JSON for isolate-safe processing
        final jsonMessages = _messages.map((m) => m.toJson()).toList();

        // 2. Process in isolate using compute() with serializable data only
        final filteredMessageIds = await compute(_filterMessagesInIsolate, {
          'messages': jsonMessages,
          'deviceId': deviceId,
          'now': now.toIso8601String() // Send current time as ISO string
        });

        // 3. Get the actual message objects back using the filtered IDs
        final filteredMessages = _messages
            .where((m) => filteredMessageIds.contains(m.id))
            .toList();

        // 4. Sort by priority (needed as the isolate doesn't preserve order)
        _sortMessagesByPriority(filteredMessages);

        return filteredMessages;
      } catch (e, stackTrace) {
        // If isolate processing fails for any reason, fall back to direct processing
        debugPrint('Isolate processing failed: $e');
        debugPrint('Stack trace: $stackTrace');
        debugPrint('Falling back to direct message filtering');
        return _getRetriableMessagesDirect();
      }
    } else {
      // For smaller batches, use direct processing
      return _getRetriableMessagesDirect();
    }
  }

  List<BleMessage> _getRetriableMessagesDirect() {
    final now = DateTime.now();
    final deviceId = _deviceId;

    // Filter messages that can be retried
    final retriableMessages = _messages.where((m) {
      // Check if message is retriable
      final canRetry = m.status == MessageStatus.failed ||
          m.status == MessageStatus.sending ||
          m.status == MessageStatus.pending;

      // Check if message is from this device
      final isFromThisDevice = m.senderId == deviceId;

      // Check backoff period based on attempt count
      bool isInBackoffPeriod = false;
      if (m.lastAttempt != null && m.attemptCount > 0) {
        final backoffSeconds = math.min(30 * m.attemptCount, 300);
        isInBackoffPeriod = now.difference(m.lastAttempt!).inSeconds < backoffSeconds;
      }

      return canRetry && isFromThisDevice && !isInBackoffPeriod;
    }).toList();

    // Sort by priority
    _sortMessagesByPriority(retriableMessages);

    return retriableMessages;
  }

  static List<String> _filterMessagesInIsolate(Map<String, dynamic> data) {
    try {
      final List<dynamic> rawMessages = data['messages'] as List<dynamic>;
      final List<Map<String, dynamic>> messages = rawMessages
          .cast<Map<String, dynamic>>();

      final String deviceId = data['deviceId'] as String;
      final DateTime now = DateTime.parse(data['now'] as String);

      // Filter messages that can be retried
      return messages.where((json) {
        // Extract status for filtering
        final statusStr = json['status'] as String? ?? 'MessageStatus.created';
        final canRetry = statusStr == 'MessageStatus.failed' ||
            statusStr == 'MessageStatus.sending' ||
            statusStr == 'MessageStatus.pending';

        // Check sender ID
        final senderId = json['senderId'] as String? ?? '';
        final isFromThisDevice = senderId == deviceId;

        // Calculate isRecentFailure
        bool isInBackoffPeriod = false;
        if (json['lastAttempt'] != null) {
          try {
            final lastAttempt = DateTime.parse(json['lastAttempt'] as String);
            final attemptCount = (json['attemptCount'] as num?)?.toInt() ?? 0;
            final backoffSeconds = math.min(30 * attemptCount, 300);
            isInBackoffPeriod = now.difference(lastAttempt).inSeconds < backoffSeconds;
          } catch (e) {
            // If datetime parsing fails, assume it's not a recent failure
            isInBackoffPeriod = false;
          }
        }

        // Apply all filter conditions
        return canRetry && isFromThisDevice && !isInBackoffPeriod;
      }).map((json) => json['id'] as String? ?? '').where((id) => id.isNotEmpty).toList();
    } catch (e) {
      // Return empty list on error
      return <String>[];
    }
  }

  void _sortMessagesByPriority(List<BleMessage> messages) {
    if (messages.isEmpty) return;

    messages.sort((a, b) {
      try {
        // Compare priority first (higher priority first)
        if (a.priority != b.priority) {
          return b.priority.compareTo(a.priority);
        }

        // Then use the timestamp and attempt count calculation
        final aScore = a.timestamp.millisecondsSinceEpoch / 1000 - ((a.attemptCount) * 60);
        final bScore = b.timestamp.millisecondsSinceEpoch / 1000 - ((b.attemptCount) * 60);
        return bScore.compareTo(aScore); // Higher score (newer) first
      } catch (e) {
        debugPrint('Error comparing messages for sorting: $e');
        return 0; // Neutral sort result on error
      }
    });
  }

  Future<List<BleMessage>> _getRetriableMessages() async {
    final now = DateTime.now();
    final deviceId = _deviceId;

    // Filter messages that can be retried
    final retriableMessages = _messages.where((m) {
      // Check if message is retriable
      final canRetry = m.status == MessageStatus.failed ||
          m.status == MessageStatus.sending ||
          m.status == MessageStatus.pending;

      // Check if message is from this device
      final isFromThisDevice = m.senderId == deviceId;

      // Check backoff period based on attempt count
      bool isInBackoffPeriod = false;
      if (m.lastAttempt != null && m.attemptCount > 0) {
        final backoffSeconds = math.min(30 * m.attemptCount, 300);
        isInBackoffPeriod = now.difference(m.lastAttempt!).inSeconds < backoffSeconds;
      }

      return canRetry && isFromThisDevice && !isInBackoffPeriod;
    }).toList();

    // Sort by priority (newer messages with fewer attempts get higher priority)
    retriableMessages.sort((a, b) {
      try {
        final aScore = a.timestamp.millisecondsSinceEpoch / 1000 - ((a.attemptCount) * 60);
        final bScore = b.timestamp.millisecondsSinceEpoch / 1000 - ((b.attemptCount) * 60);
        return bScore.compareTo(aScore); // Higher score (newer) first
      } catch (e) {
        debugPrint('Error comparing messages for sorting: $e');
        return 0; // Neutral sort result on error
      }
    });

    return retriableMessages;
  }

  Map<String, List<BleMessage>> _groupMessagesByRecipient(List<BleMessage> messages) {
    final messagesByRecipient = <String, List<BleMessage>>{};

    for (final message in messages) {
      try {
        String? recipientId;

        // For direct messages
        if (message.relayPath.isEmpty) {
          recipientId = message.recipientId;
        }
        // For relay messages, use the next hop
        else if (message.relayPath.isNotEmpty) {
          recipientId = message.relayPath.last;
        }

        // Skip if no valid recipient
        if (recipientId == null || recipientId.isEmpty) {
          debugPrint('Message ${message.id} has no valid recipient, skipping');
          continue;
        }

        // Add to map, creating list if needed
        if (!messagesByRecipient.containsKey(recipientId)) {
          messagesByRecipient[recipientId] = [];
        }
        messagesByRecipient[recipientId]!.add(message);
      } catch (e, stackTrace) {
        debugPrint('Error grouping message ${message.id}: $e');
        debugPrint('Stack trace: $stackTrace');
        // Skip message if grouping fails
        continue;
      }
    }

    return messagesByRecipient;
  }

  Future<void> _sendSingleMessage(BleMessage message, BleDevice device) async {
    debugPrint('🔄 _sendSingleMessage starting for message ${message.id} to device ${device.id}');
    try {
      // Update attempt count and last attempt time
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index >= 0) {
        final currentAttemptCount = message.attemptCount;
        debugPrint('📊 Current attempt count: $currentAttemptCount for message ${message.id}');

        debugPrint('🔄 Updating message status to SENDING');
        await _updateMessageStatus(
          message.id,
          MessageStatus.sending,
          attemptCount: currentAttemptCount + 1,
          lastAttempt: DateTime.now(),
        );

        // Send the message
        debugPrint('📨 Calling _sendMessageToDevice for message ${message.id}');
        final success = await _sendMessageToDevice(
          _messages[index],
          device.peripheral,
        );

        if (success) {
          debugPrint('✅ Message ${message.id} delivered successfully!');
          await _updateMessageStatus(message.id, MessageStatus.delivered);
          _errorRecoveryManager.operationSucceeded();
        } else {
          debugPrint('❌ Message ${message.id} delivery failed');
          await _updateMessageStatus(message.id, MessageStatus.failed);
          // Record error metrics
          debugPrint('⚠️ BLE message send failure: messageId=${message.id}, deviceId=${device.id}');
        }
      } else {
        debugPrint('❌ Message ${message.id} not found in queue');
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Error sending message ${message.id} to device ${device.id}: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      // Mark as failed for retry
      await _updateMessageStatus(message.id, MessageStatus.failed);

      // Record error metrics
      debugPrint('⚠️ BLE single message send failure: messageId=${message.id}, deviceId=${device.id}, attemptCount=${(message.attemptCount) + 1}');
    }
    debugPrint('🔄 _sendSingleMessage completed for message ${message.id}');
  }

  Future<void> _handleUndeliveredMessages() async {
    try {
      // Find messages that need relay
      final stillUndelivered = _messages.where((m) {
        if (!_isMessageRetriable(m) || m.senderId != _deviceId) return false;
        if (m.relayPath.isNotEmpty) return false;

        final recipientId = m.recipientId;
        if (recipientId.isEmpty) return false;

        // Check if recipient is connected
        return !_discoveredDevices.any((d) =>
        d.id == recipientId && d.isConnected == true);
      }).toList();

      // Find connected devices that can be used as relays
      final connectedDevices = _discoveredDevices.where((d) =>
      d.isConnected == true && d.supportsRelay == true).toList();

      if (stillUndelivered.isNotEmpty && connectedDevices.isNotEmpty) {
        await _tryRelayForUndeliveredMessages(stillUndelivered, connectedDevices);
      }
    } catch (e, stackTrace) {
      debugPrint('Error handling undelivered messages: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  /// Try to use relay nodes for undelivered messages
  Future<void> _tryRelayForUndeliveredMessages(
      List<BleMessage> messages, List<BleDevice> relayDevices) async {
    // Sort relay devices by signal strength and ability
    relayDevices.sort((a, b) {
      // Prioritize devices with better signal
      if ((a.rssi - b.rssi).abs() > 10) {
        return b.rssi.compareTo(a.rssi);
      }

      // If signal is similar, consider other factors
      return b.connectionPriority.compareTo(a.connectionPriority);
    });

    // Only use top 3 relay devices to avoid flooding network
    final topRelays = relayDevices.take(3).toList();

    for (final message in messages) {
      // Skip messages that have no TTL left
      if (message.ttl <= 0) continue;

      // Pick best relay for this message
      final relay = topRelays.first;

      // Create a relayed version of the message
      final relayedMessage = message.copyWith(
        relayPath: [...message.relayPath, relay.id],
        ttl: message.ttl - 1,
      );

      // Update the message in our queue
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index >= 0) {
        _messages[index] = relayedMessage;
        _messagesSubject.add(_messages);
        await _saveMessages();

        // Try to send via relay
        await _sendMessageToDevice(relayedMessage, relay.peripheral);
      }
    }
  }

  Future<void> _startScanIfNeeded() async {
    try {
      // Check if there are still pending messages
      final pendingMessages = await _getRetriableMessages();

      if (pendingMessages.isNotEmpty && !_isScanning) {
        // Determine scan parameters based on message urgency
        final scanParameters = _determineScanParameters(pendingMessages);

        await startScan(
          maxDuration: scanParameters.duration,
          lowPowerMode: scanParameters.lowPower,
        );
      }
    } catch (e, stackTrace) {
      debugPrint('Error starting BLE scan: $e');
      debugPrint('Stack trace: $stackTrace');

      // Fall back to standard scan
      if (!_isScanning) {
        try {
          await startScan();
          debugPrint('Started fallback scan after failure');
        } catch (fallbackError) {
          debugPrint('Even fallback scan failed: $fallbackError');
          // Schedule retry with delay
          _scheduleRetry();
        }
      }
    }
  }

  void _scheduleRetry() {
    _consecutiveFailures = (_consecutiveFailures ?? 0) + 1;

    // Calculate delay with exponential backoff
    final delaySeconds = math.min(
        5 * math.pow(1.5, _consecutiveFailures ?? 1).toInt(),
        60 // Cap at 1 minute
    );

    debugPrint('Scheduling retry attempt $_consecutiveFailures in $delaySeconds seconds');

    // Cancel existing retry if any
    _retryTimer?.cancel();

    // Schedule new retry
    _retryTimer = Timer(Duration(seconds: delaySeconds), () {
      _processOutgoingMessages();
    });
  }
  void _resetRetryCounter() {
    if (_consecutiveFailures != null && _consecutiveFailures! > 0) {
      debugPrint('Resetting retry counter from $_consecutiveFailures to 0');
      _consecutiveFailures = 0;
    }
  }
  void _resetScanFailureCounter() {
    if (_consecutiveScanFailures > 0) {
      debugPrint('Resetting scan failure counter from $_consecutiveScanFailures to 0');
      _consecutiveScanFailures = 0;
    }
  }
  bool _isMessageRetriable(BleMessage message) {
    return message.status == MessageStatus.failed ||
        message.status == MessageStatus.sending ||
        message.status == MessageStatus.pending;
  }

  /// Normalize device ID to a consistent format
  String normalizeDeviceId(String deviceId) {
    // If empty, return empty
    if (deviceId.isEmpty) return deviceId;

    // If it's already a UUID with dashes, return as is
    if (deviceId.contains('-') && deviceId.length >= 36) return deviceId;

    // If it's a MAC address with colons, convert to canonical UUID format
    if (deviceId.contains(':')) {
      return '00000000-0000-0000-0000-${deviceId.replaceAll(':', '').toLowerCase()}';
    }

    // If it's just a short ID (like from a Pak-Msg name), pad it
    if (deviceId.length < 32) {
      // Make sure we have at least 12 characters for the device part of the UUID
      String paddedId = deviceId.padRight(12, '0').substring(0, 12);
      return '00000000-0000-0000-0000-$paddedId';
    }

    // If it's a 32-character hex string without dashes, add them
    if (deviceId.length == 32) {
      return '${deviceId.substring(0, 8)}-${deviceId.substring(8, 12)}-${deviceId.substring(12, 16)}-${deviceId.substring(16, 20)}-${deviceId.substring(20)}';
    }

    // Default case - return as is
    return deviceId;
  }

  Map<String, String> _extractDeviceIds() {
    Map<String, String> result = {};

    for (var device in _discoveredDevices) {
      // Store device ID mapping
      result[device.id] = device.id;

      // Check if we have extracted a remote ID from device info
      if (device.metadata != null && device.metadata!.containsKey('remoteDeviceId')) {
        final remoteId = device.metadata!['remoteDeviceId'] as String;
        if (remoteId.isNotEmpty) {
          result[remoteId] = device.id;
          debugPrint('📱 Mapped remote ID $remoteId to device ${device.id}');
        }
      }

      // Check if we have a Pak-Msg name with embedded ID
      if (device.name != null && device.name!.startsWith('Pak-Msg-')) {
        final nameId = device.name!.substring(8);
        if (nameId.isNotEmpty) {
          result[nameId] = device.id;
          debugPrint('📱 Mapped name ID $nameId to device ${device.id}');
        }
      }
    }

    return result;
  }

  // Add this method to your BleService class
  BleDevice? findDeviceByAnyId(String targetId) {
    debugPrint('🔍 Searching for device: $targetId');

    // Get all possible device ID mappings
    final idMap = _extractDeviceIds();

    // First try exact match using mappings
    if (idMap.containsKey(targetId)) {
      final actualDeviceId = idMap[targetId]!;
      final deviceIndex = _discoveredDevices.indexWhere((d) => d.id == actualDeviceId);
      if (deviceIndex >= 0) {
        debugPrint('✅ Found device by exact ID match via mapping');
        return _discoveredDevices[deviceIndex];
      }
    }

    // Try partial match
    final shortTargetId = targetId.substring(0, math.min(targetId.length, 8));
    for (var entry in idMap.entries) {
      if (entry.key.contains(shortTargetId) || shortTargetId.contains(entry.key)) {
        final actualDeviceId = entry.value;
        final deviceIndex = _discoveredDevices.indexWhere((d) => d.id == actualDeviceId);
        if (deviceIndex >= 0) {
          debugPrint('✅ Found device by partial ID match: ${entry.key}');
          return _discoveredDevices[deviceIndex];
        }
      }
    }


    debugPrint('🔍 Available devices:');
    for (var device in _discoveredDevices) {
      debugPrint('  - ID: ${device.id}, Name: ${device.name ?? "Unknown"}');
    }

    if (targetId.isEmpty) return null;

    debugPrint('🔍 Searching for device with ID: $targetId');

    // Try exact match first (most reliable)
    int deviceIndex = _discoveredDevices.indexWhere((d) => d.id == targetId);
    if (deviceIndex >= 0) {
      debugPrint('✅ Found device by exact ID match');
      return _discoveredDevices[deviceIndex];
    }

    // Check if any device's name contains the target ID (for "Pak-Msg-XXXXXXXX" pattern)
    deviceIndex = _discoveredDevices.indexWhere(
            (d) => d.name != null && d.name!.contains(targetId.substring(0, math.min(8, targetId.length)))
    );

    if (deviceIndex >= 0) {
      debugPrint('✅ Found device by name containing target ID: ${_discoveredDevices[deviceIndex].name}');
      return _discoveredDevices[deviceIndex];
    }

    // Try MAC address format without dashes
    if (targetId.contains('-')) {
      String macFormat = targetId.replaceAll('-', '').toLowerCase();
      deviceIndex = _discoveredDevices.indexWhere((d) =>
          d.id.replaceAll('-', '').toLowerCase().contains(macFormat.substring(0, math.min(8, macFormat.length)))
      );

      if (deviceIndex >= 0) {
        debugPrint('✅ Found device by MAC address format match');
        return _discoveredDevices[deviceIndex];
      }
    }

    // Check for any device whose name has the format "Pak-Msg-XXXXXXXX"
    // where XXXXXXXX might be derived from the targetId
    for (int i = 0; i < _discoveredDevices.length; i++) {
      final device = _discoveredDevices[i];
      if (device.name != null && device.name!.startsWith('Pak-Msg-')) {
        final nameId = device.name!.substring(8); // Extract ID part after "Pak-Msg-"
        if (targetId.contains(nameId) || nameId.contains(targetId.substring(0, math.min(8, targetId.length)))) {
          debugPrint('✅ Found device by Pak-Msg name pattern match: ${device.name}');
          return device;
        }
      }
    }

    // As a last resort, try any partial match
    for (int i = 0; i < _discoveredDevices.length; i++) {
      final device = _discoveredDevices[i];
      if ((device.id.contains(targetId.substring(0, math.min(8, targetId.length)))) ||
          (device.name != null &&
              device.name!.contains(targetId.substring(0, math.min(8, targetId.length))))) {
        debugPrint('✅ Found device by partial ID/name match: ${device.name ?? device.id}');
        return device;
      }
    }

    debugPrint('❌ No matching device found for ID: $targetId');
    return null;
  }

  bool messageRequiresUrgentDelivery(BleMessage message) {
    // Consider a message urgent if:
    // 1. It has high priority metadata
    if (message.metadata != null &&
        message.metadata!.containsKey('priority') &&
        message.metadata!['priority'] == 'high') {
      return true;
    }

    // 2. It's to an emergency contact
    try {
      final recipientContact = InMemoryStore.contacts.firstWhere(
            (c) => c.username == message.recipientId || c.bleDeviceId == message.recipientId,
      );
      return recipientContact.isEmergency;
    } catch (_) {
      // Contact not found, default to non-urgent
    }

    // 3. It has failed too many times already
    if (message.attemptCount > 5) {
      return true;
    }

    // Default to non-urgent
    return false;
  }

  ScanParameters _determineScanParameters(List<BleMessage> pendingMessages) {
    try {
      if (pendingMessages.isEmpty) {
        return ScanParameters(Duration(seconds: 30), false);
      }

      // Check for any urgent messages
      final hasUrgentMessages = pendingMessages.any((m) => messageRequiresUrgentDelivery(m));

      // Find the oldest pending message
      DateTime? oldestTimestamp;
      for (final message in pendingMessages) {
        if (oldestTimestamp == null || message.timestamp.isBefore(oldestTimestamp)) {
          oldestTimestamp = message.timestamp;
        }
      }

      if (oldestTimestamp == null) {
        return ScanParameters(Duration(seconds: 30), false);
      }

      final messageAge = DateTime.now().difference(oldestTimestamp).inMinutes;

      // More aggressive scanning for urgent messages
      if (hasUrgentMessages) {
        return ScanParameters(Duration(seconds: 45), false); // Longer scan, full power
      }

      // Use low power scan if messages aren't urgent (over 30 min old)
      final lowPowerScan = messageAge > 30 && pendingMessages.length < 5;

      // Define scan duration based on urgency
      final scanDuration = lowPowerScan
          ? Duration(seconds: 10)
          : (messageAge < 5 ? Duration(seconds: 40) : activeScanDuration);

      return ScanParameters(scanDuration, lowPowerScan);
    } catch (e) {
      debugPrint('Error determining scan parameters: $e');
      // Default to standard scan parameters
      return ScanParameters(Duration(seconds: 30), false);
    }
  }

  // Add to your BleService class
  Future<bool> sendMessageWithRetry(String recipientId, String content, {int maxRetries = 3}) async {
    debugPrint('📤 Attempting to send message to $recipientId with retries');

    // First, normalize the recipient ID
    final normalizedId = normalizeDeviceId(recipientId);

    // Try direct send first
    try {
      final success = await sendMessage(normalizedId, content);
      if (success) return true;
    } catch (e) {
      debugPrint('⚠️ Initial send attempt failed: $e');
    }

    // If we're here, direct send failed. Find the device
    final device = findDeviceByAnyId(normalizedId);
    if (device == null) {
      debugPrint('❌ Device not found for ID: $normalizedId');

      // Queue the message anyway for future delivery
      final message = BleMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(10000)}',
        senderId: _deviceId,
        recipientId: normalizedId,
        content: content,
        timestamp: DateTime.now(),
        status: MessageStatus.pending,
      );

      _messages.add(message);
      _messagesSubject.add(_messages);
      await _saveMessages();

      return false;
    }

    // If device exists but not connected, try to connect and send
    if (!device.isConnected) {
      debugPrint('🔄 Device found but not connected. Attempting connection...');

      // Try to connect
      final connected = await connectToDevice(device);
      if (!connected) {
        debugPrint('❌ Failed to connect to device');

        // Queue the message anyway
        final message = BleMessage(
          id: '${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(10000)}',
          senderId: _deviceId,
          recipientId: normalizedId,
          content: content,
          timestamp: DateTime.now(),
          status: MessageStatus.pending,
        );

        _messages.add(message);
        _messagesSubject.add(_messages);
        await _saveMessages();

        return false;
      }

      // Successfully connected, now try to send
      debugPrint('✅ Connected successfully, attempting to send message');

      // Small delay to ensure services are discovered
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Attempt retries
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        debugPrint('🔄 Send attempt ${attempt + 1}/$maxRetries');
        final success = await sendMessage(normalizedId, content);
        if (success) {
          debugPrint('✅ Message sent successfully on attempt ${attempt + 1}');
          return true;
        }

        // Wait before retrying
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      } catch (e) {
        debugPrint('⚠️ Send attempt ${attempt + 1} failed: $e');
        // Wait before retrying
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }

    debugPrint('❌ All send attempts failed');
    return false;
  }

  /// Send a specific message to a connected device with packet fragmentation
  Future<bool> _sendMessageToDevice(BleMessage message, Peripheral peripheral) async {
    debugPrint('🔄 _sendMessageToDevice started. Message ID: ${message.id}');
    debugPrint('🔄 Target peripheral ID: ${peripheral.uuid}, message recipient: ${message.recipientId}');


    if (_isJniDetached) {
      debugPrint('⚠️ Cannot send message: JNI is currently detached');
      return false;
    }

    try {
      // Check if we have discovered services for this peripheral
      final peripheralId = peripheral.uuid.toString();
      GATTService? service = _deviceGattServices[peripheralId];

      debugPrint('🔍 Checking GATT service for device: $peripheralId');

      if (service == null) {
        debugPrint('❌ No GATT service found for device: $peripheralId, will discover services first');
        // Discover services first
        try {
          await _discoverServices(peripheral);
          service = _deviceGattServices[peripheralId];

          // If service is still null after discovery, fail
          if (service == null) {
            debugPrint('❌ Service discovery succeeded but no service was cached');
            return false;
          }
        } catch (e) {
          debugPrint('❌ Service discovery failed during message send: $e');
          return false;
        }
      }

      // Find message characteristic
      final characteristic = _findCharacteristic(service, messageCharacteristicUuid);
      if (characteristic == null) {
        debugPrint('❌ Message characteristic not found for device: $peripheralId');
        debugPrint('Available characteristics:');
        for (var char in service.characteristics) {
          debugPrint('  - ${char.uuid}');
        }
        return false;
      }

      debugPrint('✅ Found message characteristic: ${characteristic.uuid}');

      // Convert message to JSON and then to bytes
      final messageJson = jsonEncode(message.toJson());
      debugPrint('📦 Message JSON: ${messageJson.substring(0, math.min(messageJson.length, 100))}...');

      final messageBytes = Uint8List.fromList(utf8.encode(messageJson));
      debugPrint('📦 Prepared message payload: ${messageBytes.length} bytes');

      // Get negotiated MTU size for this device
      final mtu = await _getNegotiatedMtu(peripheral);
      final effectiveSize = math.max(20, mtu - 3); // Account for ATT overhead
      debugPrint('ℹ️ Using MTU size: $mtu, effective payload size: $effectiveSize');

      // Handle message fragmentation if needed
      if (messageBytes.length > effectiveSize) {
        debugPrint('🧩 Message too large for MTU, using fragmentation');
        return await _sendFragmentedMessage(message, messageBytes, peripheral, characteristic, effectiveSize);
      } else {
        // Send the message in a single packet with multiple retry attempts
        return await _retryWriteOperation(
            peripheral: peripheral,
            characteristic: characteristic,
            value: messageBytes,
            maxRetries: 3
        );
      }
    } catch (e, stack) {
      debugPrint('❌ Failed to send message: $e');
      errorMetrics.recordWriteFailure(peripheral.uuid.toString());
      debugPrint('❌ Stack trace: $stack');
      return false;
    }
  }

  Future<bool> _retryWriteOperation({
    required Peripheral peripheral,
    required GATTCharacteristic characteristic,
    required Uint8List value,
    int maxRetries = 3
  }) async {
    int attempts = 0;
    while (attempts < maxRetries) {
      attempts++;
      debugPrint('📨 Write attempt $attempts/$maxRetries with ${value.length} bytes');

      // Log characteristic details
      debugPrint('📨 Characteristic UUID: ${characteristic.uuid}, properties: ${characteristic.properties}');

      try {
        // First try with response using timeout
        await withTimeout(
            _centralManager.writeCharacteristic(
              peripheral,
              characteristic,
              value: value,
              type: GATTCharacteristicWriteType.withResponse,
            ),
            const Duration(seconds: 10),
            null,  // Changed from false to null since we're not returning a value
            'writeCharacteristic'
        );

        // If we get here without exception, the write was successful
        debugPrint('✅ Message sent successfully on attempt $attempts');
        return true;

      } catch (e) {
        debugPrint('❌ Write attempt $attempts failed: $e');
        errorMetrics.recordWriteFailure(peripheral.uuid.toString());

        // For the last attempt, try without response
        if (attempts == maxRetries) {
          try {
            debugPrint('⚠️ Trying final attempt with withoutResponse type');
            await withTimeout(
                _centralManager.writeCharacteristic(
                  peripheral,
                  characteristic,
                  value: value,
                  type: GATTCharacteristicWriteType.withoutResponse,
                ),
                const Duration(seconds: 5),
                null,  // Changed from false to null
                'writeCharacteristicWithoutResponse'
            );

            // If we get here, the final attempt succeeded
            debugPrint('✅ Message sent successfully on final attempt using withoutResponse');
            return true;
          } catch (fallbackError) {
            debugPrint('❌ Even final attempt failed: $fallbackError');
            errorMetrics.recordWriteFailure(peripheral.uuid.toString());
            return false;
          }
        }

        // Add a small delay between attempts
        await Future.delayed(Duration(milliseconds: 300 * attempts));
      }
    }

    return false;
  }

  /// Send a fragmented message with improved reliability
  Future<bool> _sendFragmentedMessage(
      BleMessage message,
      Uint8List messageBytes,
      Peripheral peripheral,
      GATTCharacteristic characteristic,
      int fragmentSize) async {
    try {
      // Calculate number of fragments needed
      final fragmentCount = (messageBytes.length / fragmentSize).ceil();
      debugPrint('Sending fragmented message: ${message.id}, fragments: $fragmentCount');

      // First send metadata about the fragmented message
      final metadataJson = jsonEncode({
        'messageId': message.id,
        'fragmentCount': fragmentCount,
        'totalSize': messageBytes.length,
        'isFragmentMetadata': true,
      });

      final metadataBytes = Uint8List.fromList(utf8.encode(metadataJson));
      await _centralManager.writeCharacteristic(
        peripheral,
        characteristic,
        value: metadataBytes,
        type: GATTCharacteristicWriteType.withResponse,
      );

      // Small delay between metadata and first fragment
      await Future.delayed(Duration(milliseconds: 50));

      // Send each fragment
      for (int i = 0; i < fragmentCount; i++) {
        // Calculate fragment boundaries
        final start = i * fragmentSize;
        final end = math.min(start + fragmentSize, messageBytes.length);
        final fragmentData = messageBytes.sublist(start, end);

        // Create fragment header
        final fragmentHeader = {
          'messageId': message.id,
          'fragmentIndex': i,
          'fragmentCount': fragmentCount,
          'isFragment': true,
        };

        final headerJson = jsonEncode(fragmentHeader);
        final headerBytes = Uint8List.fromList(utf8.encode(headerJson));

        // Create composite packet with header size, header, and data
        final packetBytes = Uint8List(2 + headerBytes.length + fragmentData.length);
        packetBytes[0] = headerBytes.length & 0xFF;
        packetBytes[1] = (headerBytes.length >> 8) & 0xFF;
        packetBytes.setRange(2, 2 + headerBytes.length, headerBytes);
        packetBytes.setRange(2 + headerBytes.length, packetBytes.length, fragmentData);

        // Send the fragment
        await _centralManager.writeCharacteristic(
          peripheral,
          characteristic,
          value: packetBytes,
          type: GATTCharacteristicWriteType.withResponse,
        );

        // Small delay between fragments - adaptive based on fragment size
        if (i < fragmentCount - 1) {
          final delay = math.max(20, math.min(100, fragmentSize ~/ 5));
          await Future.delayed(Duration(milliseconds: delay));
        }
      }

      return true;
    } catch (e, stackTrace) {
      debugPrint('Failed to send fragmented message: $e');
      debugPrint('Stack trace: $stackTrace');
      return false;
    }
  }

  /// Process an incoming message with enhanced fragment handling
  Future<void> _processIncomingMessage(
      Peripheral? peripheral,
      Uint8List value, {
        Central? central,
      }) async {
    return _stateLock.synchronized(() async {
      debugPrint('📩 Processing incoming message of ${value.length} bytes');
      try {
        // Add diagnostic logging for packet analysis
        final hexData = value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        debugPrint('📦 Raw packet data (hex): ${hexData.substring(0, math.min(hexData.length, 100))}...');

        // Try to decode directly as a complete message first (most common case)
        try {
          final messageJson = utf8.decode(value, allowMalformed: true);
          debugPrint('🔄 Attempting to decode as complete JSON message');

          try {
            final messageData = jsonDecode(messageJson) as Map<String, dynamic>;
            // If we reached here, it's valid JSON
            debugPrint('✅ Successfully decoded as complete message JSON');

            // Check if this is a fragment metadata message
            if (messageData.containsKey('isFragmentMetadata') && messageData['isFragmentMetadata'] == true) {
              debugPrint('📝 Received fragment metadata message: ${messageJson.substring(0, math.min(messageJson.length, 100))}');

              // Store metadata for reassembly
              final messageId = messageData['messageId'] as String;
              final fragmentCount = messageData['fragmentCount'] as int;

              if (!_incomingPackets.containsKey(messageId)) {
                _incomingPackets[messageId] = List.generate(
                  fragmentCount,
                      (i) => <String, dynamic>{
                    'received': false,
                    'timestamp': DateTime.now(),
                  },
                );
                debugPrint('📋 Created fragment tracking for message $messageId with $fragmentCount fragments');
              }
              return;
            }

            // If it's a regular message, not a fragment
            if (!messageData.containsKey('isFragment') || messageData['isFragment'] != true) {
              debugPrint('📩 Processing as regular (non-fragmented) message');
              await _processRegularMessage(value, peripheral, central);
              return;
            }

            // Find the fragment data portion - extract after the header
            final headerBytes = utf8.encode(jsonEncode(messageData));
            final fragmentData = value.sublist(headerBytes.length);

            await _processMessageFragment(
              messageData,
              fragmentData,
              peripheral,
              central,
            );
            return;
          } catch (jsonError) {
            debugPrint('⚠️ JSON parsing failed, checking for binary format: $jsonError');
          }
        } catch (decodeError) {
          debugPrint('⚠️ UTF-8 decoding failed, likely binary format: $decodeError');
        }

        // Check if it's a binary format with 2-byte header size
        if (value.length > 2) {
          final headerSize = value[0] | (value[1] << 8);

          // Validate header size is reasonable (prevents invalid parsing)
          if (headerSize > 0 && headerSize < 1000 && value.length > headerSize + 2) {
            try {
              final headerBytes = value.sublist(2, 2 + headerSize);
              final headerJson = utf8.decode(headerBytes);

              try {
                final header = jsonDecode(headerJson) as Map<String, dynamic>;
                debugPrint('🔍 Decoded binary format header: ${headerJson.substring(0, math.min(headerJson.length, 100))}');

                // Handle fragment
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
                debugPrint('⚠️ Binary header JSON parsing failed: $e');
              }
            } catch (e) {
              debugPrint('⚠️ Binary header decoding failed: $e');
            }
          }
        }

        // If all parsing attempts fail, try as a regular message one last time
        debugPrint('⚠️ Message format not recognized, attempting to process as regular message');
        await _processRegularMessage(value, peripheral, central);
      } catch (e, stack) {
        debugPrint('❌ Error processing incoming message: $e');
        debugPrint('Stack trace: $stack');
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
      debugPrint('🔄 Decoding regular message payload');
      final messageJson = utf8.decode(value);
      debugPrint('📄 Decoded message JSON: ${messageJson.substring(0, math.min(messageJson.length, 50))}...');
      final messageData = jsonDecode(messageJson) as Map<String, dynamic>;
      final message = BleMessage.fromJson(messageData);

      debugPrint('✅ Successfully decoded message: ${message.id} from: ${message.senderId} to: ${message.recipientId}');
      // Update activity timestamp
      _lastMessageActivity = DateTime.now();

      // Handle different message routing scenarios

      // Case 1: Message is for us
      if (message.recipientId == _deviceId) {
        debugPrint('📬 Message is for us! Adding to message store');
        // Add to our messages if not already present
        final existingIndex = _messages.indexWhere((m) => m.id == message.id);
        if (existingIndex < 0) {
          _messages.add(message);
          _messagesSubject.add(_messages);
          await _saveMessages();

          // Show notification for new message
          _showMessageNotification(message);

          InMemoryStore.handleMessageFromUnknownContact(
            message.senderId,
            message.content,
            false, // Not sent by us
          );
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

  bool get needsAcknowledgment {
    return status == MessageStatus.delivered &&
        senderId == _deviceId && // Only track ACKs for messages we sent
        DateTime.now().difference(timestamp!).inMinutes < 60; // Don't need ACKs for very old messages
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
      debugPrint('📩 Received ACK: $ackJson');

      final ackData = jsonDecode(ackJson) as Map<String, dynamic>;

      // Validate this is actually an ACK
      if (!(ackData['isAck'] == true)) {
        debugPrint('⚠️ Invalid ACK format');
        return;
      }

      final messageId = ackData['messageId'] as String;
      debugPrint('✅ Processing ACK for message: $messageId');

      // Find the original message
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index >= 0) {
        // Mark message as acknowledged
        debugPrint('✅ Found message to ACK, updating status');
        await _updateMessageStatus(_messages[index].id, MessageStatus.ack);

        // Store metrics about delivery time
        final deliveryTime = DateTime.now().difference(_messages[index].timestamp);
        debugPrint('📊 Message delivery time: ${deliveryTime.inSeconds} seconds');

        // Complete any pending future
        if (_outgoingMessageCompleters.containsKey(messageId) &&
            !_outgoingMessageCompleters[messageId]!.isCompleted) {
          _outgoingMessageCompleters[messageId]!.complete(true);
          _outgoingMessageCompleters.remove(messageId);
        }
      } else {
        debugPrint('⚠️ Received ACK for unknown message: $messageId');
      }
    } catch (e) {
      debugPrint('❌ Failed to process acknowledgment: $e');
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

  void initializePeriodicCleanup() {
    // Clean up every 5 minutes
    Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanupMessageMaps();
    });
  }

  void _cleanupMessageMaps() {
    final now = DateTime.now();

    // Clean up incoming packets map (remove entries older than 10 minutes)
    final incomingPacketsToRemove = <String>[];
    _incomingPackets.forEach((messageId, fragments) {
      // Check if any fragment has a timestamp
      final hasTimestamp = fragments.any((f) => f.containsKey('timestamp'));
      if (hasTimestamp) {
        final timestamp = fragments.firstWhere(
              (f) => f.containsKey('timestamp'),
          orElse: () => {'timestamp': now},
        )['timestamp'] as DateTime;

        if (now.difference(timestamp).inMinutes > 10) {
          incomingPacketsToRemove.add(messageId);
        }
      } else {
        // If no timestamp, assume it's old and remove it
        incomingPacketsToRemove.add(messageId);
      }
    });

    for (final id in incomingPacketsToRemove) {
      _incomingPackets.remove(id);
    }

    // Clean up message completers map
    final completersToRemove = <String>[];
    _outgoingMessageCompleters.forEach((messageId, completer) {
      // If completer is not completed but no message exists, complete it
      final messageExists = _messages.any((m) => m.id == messageId);
      if (!messageExists && !completer.isCompleted) {
        completer.complete(false);
        completersToRemove.add(messageId);
      }

      // Also look for very old completers (older than 30 minutes)
      final message = _messages.firstWhere(
            (m) => m.id == messageId,
        orElse: () => BleMessage(
          id: messageId,
          senderId: _deviceId,
          recipientId: '',
          content: '',
          timestamp: now.subtract(const Duration(hours: 1)),
        ),
      );

      if (now.difference(message.timestamp).inMinutes > 30 && !completer.isCompleted) {
        completer.complete(false);
        completersToRemove.add(messageId);
      }
    });

    for (final id in completersToRemove) {
      _outgoingMessageCompleters.remove(id);
    }

    // Log cleanup results
    if (incomingPacketsToRemove.isNotEmpty || completersToRemove.isNotEmpty) {
      debugPrint('🧹 Cleaned up ${incomingPacketsToRemove.length} incoming packets and ${completersToRemove.length} completers');
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

  Future<List<GATTService>> _discoverServicesWithRetry(Peripheral peripheral, {int attempt = 1, int maxAttempts = 5}) async {
    try {
      return await _centralManager.discoverGATT(peripheral)
          .timeout(Duration(seconds: 15 + (attempt * 10)));
    } catch (e) {
      if (attempt < maxAttempts) {
        debugPrint('⚠️ Service discovery attempt $attempt failed, retrying in ${attempt * 2}s');
        await Future.delayed(Duration(seconds: attempt * 2));
        return _discoverServicesWithRetry(peripheral, attempt: attempt + 1, maxAttempts: maxAttempts);
      }
      rethrow;
    }
  }

  /// Discover services for a peripheral with enhanced logging and error handling
  /// Discover services for a peripheral with enhanced logging and error handling
  Future<void> _discoverServices(Peripheral peripheral) async {
    final peripheralId = peripheral.uuid.toString();
    debugPrint('🔍 DISCOVERY CHECK: peripheralId=$peripheralId, inProgress=${_discoveryInProgress.contains(peripheralId)}');

    // Create a mutex lock for this specific device if needed
    final lockKey = 'discover_$peripheralId';
    if (!_locks.containsKey(lockKey)) {
      _locks[lockKey] = Lock();
    }

    // Use synchronization to prevent concurrent discovery on the same device
    return _locks[lockKey]!.synchronized(() async {
      // Check again after acquiring the lock
      if (_discoveryInProgress.contains(peripheralId)) {
        debugPrint('⚠️ Service discovery already in progress for device: $peripheralId, skipping duplicate');
        return;
      }

      // Mark discovery as in progress
      _discoveryInProgress.add(peripheralId);

      try {
        debugPrint('🔍 Starting service discovery for device: $peripheralId');

        // Log connection state before discovery
        final deviceIndex = _discoveredDevices.indexWhere((d) => d.id == peripheralId);
        if (deviceIndex >= 0) {
          final deviceState = _discoveredDevices[deviceIndex].deviceConnectionState;
          debugPrint('🔌 Current device connection state: $deviceState');
        }

        // Track discovery start time for performance monitoring
        final startTime = DateTime.now();

        // Use increased timeout for better reliability
        final services = await _discoverServicesWithRetry(peripheral);

        // Calculate and log discovery duration
        final duration = DateTime.now().difference(startTime);
        debugPrint('🔍 Discovered ${services.length} services in ${duration.inMilliseconds}ms for device $peripheralId');

        // Log each service UUID for debugging
        if (services.isNotEmpty) {
          debugPrint('🔍 Service UUIDs:');
          for (final service in services) {
            debugPrint('   - ${service.uuid}');
          }
        }

        // Deduplicate services with the same UUID (handles protocol quirks)
        final Map<String, GATTService> uniqueServices = {};
        for (final service in services) {
          final serviceUuidString = service.uuid.toString();
          if (!uniqueServices.containsKey(serviceUuidString) ||
              service.characteristics.length > uniqueServices[serviceUuidString]!.characteristics.length) {
            uniqueServices[serviceUuidString] = service;
          }
        }

        final deduplicatedServices = uniqueServices.values.toList();
        debugPrint('🧹 Deduplicated to ${deduplicatedServices.length} unique services');

        // Log all discovered services and characteristics in a tree structure
        debugPrint('📊 Service hierarchy:');
        for (var i = 0; i < deduplicatedServices.length; i++) {
          final service = deduplicatedServices[i];
          debugPrint('   └─ Service[$i]: ${service.uuid}');

          for (var j = 0; j < service.characteristics.length; j++) {
            final characteristic = service.characteristics[j];
            final props = characteristic.properties.map((p) => p.toString().split('.').last).join(', ');
            debugPrint('      └─ Char[$j]: ${characteristic.uuid} (Props: $props)');

            // Log descriptors if any
            if (characteristic.descriptors.isNotEmpty) {
              for (var k = 0; k < characteristic.descriptors.length; k++) {
                final descriptor = characteristic.descriptors[k];
                debugPrint('         └─ Desc[$k]: ${descriptor.uuid}');
              }
            }
          }
        }

        // Find our target service
        GATTService? service;
        try {
          service = deduplicatedServices.firstWhere(
                (s) => s.uuid.toString().toLowerCase() == serviceUuid.toLowerCase(),
          );
          debugPrint('✅ Found our target service: $serviceUuid');
        } catch (e) {
          debugPrint('❌ Our service UUID not found: $serviceUuid');
          throw Exception('Target service not found');
        }

        // Cache the service for future use
        _deviceGattServices[peripheralId] = service;

        // Subscribe to message characteristic notifications
        final messageCharacteristic = _findCharacteristic(service, messageCharacteristicUuid);
        if (messageCharacteristic != null) {
          debugPrint('✅ Found message characteristic: ${messageCharacteristic.uuid}');

          // Check if the characteristic supports notifications
          final hasNotifyProperty = messageCharacteristic.properties.contains(GATTCharacteristicProperty.notify);
          final hasIndicateProperty = messageCharacteristic.properties.contains(GATTCharacteristicProperty.indicate);

          debugPrint('📊 Message characteristic properties:');
          debugPrint('   - Supports notify: $hasNotifyProperty');
          debugPrint('   - Supports indicate: $hasIndicateProperty');
          debugPrint('   - All properties: ${messageCharacteristic.properties.map((p) => p.toString().split('.').last).join(', ')}');

          // Check if characteristic has descriptors that control notifications
          final notificationDescriptors = messageCharacteristic.descriptors.where((d) {
            // Client Characteristic Configuration descriptor UUID
            return d.uuid.toString().toLowerCase() == '00002902-0000-1000-8000-00805f9b34fb';
          }).toList();

          debugPrint('📊 Found ${notificationDescriptors.length} notification control descriptors');

          if (!hasNotifyProperty && !hasIndicateProperty) {
            debugPrint('⚠️ Message characteristic doesn\'t support notifications or indications');
            // Try to continue anyway
          }

          try {
            debugPrint('🔔 Enabling notifications for message characteristic...');
            final notifyStartTime = DateTime.now();

            // Add delay before enabling notifications
            debugPrint('⏱️ Adding short delay before enabling notifications...');
            await Future.delayed(const Duration(milliseconds: 500));

            final notificationsEnabled = await _enableNotificationsWithRetry(
                peripheral,
                messageCharacteristic
            );

            if (!notificationsEnabled) {
              debugPrint('⚠️ Could not enable notifications, but continuing anyway');
            }

            final notifyDuration = DateTime.now().difference(notifyStartTime);
            debugPrint('✅ Successfully enabled notifications in ${notifyDuration.inMilliseconds}ms');

            // Try to verify notification status by reading the descriptor if present
            if (notificationDescriptors.isNotEmpty) {
              try {
                debugPrint('🔍 Checking notification status via descriptor...');
                final descriptorValue = await _centralManager.readDescriptor(
                    peripheral,
                    notificationDescriptors.first
                );

                // The first byte will be 0x01 for notifications enabled or 0x02 for indications
                if (descriptorValue.isNotEmpty) {
                  final enabled = descriptorValue[0] > 0;
                  debugPrint('📊 Notification status from descriptor: ${enabled ? "Enabled" : "Disabled"} (value: 0x${descriptorValue[0].toRadixString(16)})');
                }
              } catch (descriptorError) {
                debugPrint('⚠️ Failed to read notification descriptor: $descriptorError');
                // Non-fatal, continue anyway
              }
            }
          } catch (e) {
            debugPrint('⚠️ Failed to enable notifications for message characteristic: $e');

            // Try to diagnose the issue
            if (e.toString().contains('GATT_INVALID_ATTRIBUTE_LENGTH')) {
              debugPrint('🔍 DIAGNOSIS: This appears to be an attribute length issue');
              debugPrint('   Workaround: This might be fixable by adjusting the MTU');

              try {
                debugPrint('🔄 Attempting MTU negotiation...');
                final mtu = await _centralManager.requestMTU(peripheral, mtu: 512);
                debugPrint('✅ MTU negotiation successful: $mtu');

                // Try notification setup again after MTU change
                try {
                  debugPrint('🔄 Retrying notification setup after MTU change...');
                  final notificationsEnabled = await _enableNotificationsWithRetry(
                      peripheral,
                      messageCharacteristic
                  );

                  if (!notificationsEnabled) {
                    debugPrint('⚠️ Could not enable notifications, but continuing anyway');
                  }
                  debugPrint('✅ Notification setup succeeded on retry!');
                } catch (retryError) {
                  debugPrint('⚠️ Notification setup still failed after MTU change: $retryError');
                  // Continue anyway
                }
              } catch (mtuError) {
                debugPrint('⚠️ MTU negotiation failed: $mtuError');
              }
            } else if (e.toString().contains('GATT_INSUFFICIENT_AUTHENTICATION')) {
              debugPrint('🔍 DIAGNOSIS: Device requires authentication or bonding');
              // Authentication handling would go here in a production app
            } else if (e.toString().contains('GATT_BUSY')) {
              debugPrint('🔍 DIAGNOSIS: GATT stack is busy. The system should retry automatically');
            }

            // Continue anyway since we might still be able to write
          }
        } else {
          debugPrint('❌ Message characteristic not found: $messageCharacteristicUuid');
          debugPrint('   Available characteristics:');
          for (final characteristic in service.characteristics) {
            debugPrint('   - ${characteristic.uuid}');
          }
          throw Exception('Message characteristic not found');
        }

        // Subscribe to acknowledgment characteristic notifications
        final ackCharacteristic = _findCharacteristic(service, ackCharacteristicUuid);
        if (ackCharacteristic != null) {
          debugPrint('✅ Found ack characteristic: ${ackCharacteristic.uuid}');

          // Check if the characteristic supports notifications
          final hasNotifyProperty = ackCharacteristic.properties.contains(GATTCharacteristicProperty.notify);
          final hasIndicateProperty = ackCharacteristic.properties.contains(GATTCharacteristicProperty.indicate);

          debugPrint('📊 Ack characteristic properties:');
          debugPrint('   - Supports notify: $hasNotifyProperty');
          debugPrint('   - Supports indicate: $hasIndicateProperty');
          debugPrint('   - All properties: ${ackCharacteristic.properties.map((p) => p.toString().split('.').last).join(', ')}');

          try {
            debugPrint('🔔 Enabling notifications for ack characteristic...');
            final notifyStartTime = DateTime.now();

            final notificationsEnabled = await _enableNotificationsWithRetry(
                peripheral,
                messageCharacteristic
            );

            if (!notificationsEnabled) {
              debugPrint('⚠️ Could not enable notifications, but continuing anyway');
            }

            final notifyDuration = DateTime.now().difference(notifyStartTime);
            debugPrint('✅ Successfully enabled ack notifications in ${notifyDuration.inMilliseconds}ms');
          } catch (e) {
            debugPrint('⚠️ Failed to enable notifications for ack characteristic: $e');
            // Continue anyway since we might still be able to write
          }
        } else {
          debugPrint('⚠️ Ack characteristic not found: $ackCharacteristicUuid');
          debugPrint('   This is non-fatal, but acknowledgments will not work');
          // This is non-fatal, continue anyway
        }

        // Try to read device info if available
        final deviceInfoCharacteristic = _findCharacteristic(service, deviceInfoCharacteristicUuid);
        if (deviceInfoCharacteristic != null) {
          debugPrint('🔍 Found device info characteristic, attempting to read');
          try {
            if (!await _isDeviceConnected(peripheral)) {
              debugPrint('⚠️ Device disconnected before reading characteristic, aborting');
              throw Exception('Device not connected');
            }

            final deviceInfoData = await _centralManager.readCharacteristic(
              peripheral,
              deviceInfoCharacteristic,
            );

            // Add defensive handling for potentially corrupted data
            try {
              String deviceInfoString = utf8.decode(deviceInfoData, allowMalformed: true);
              deviceInfoString = deviceInfoString.substring(0, math.min(deviceInfoString.length, 200)); // Truncate if too long

              debugPrint('📱 Device info (raw): $deviceInfoString');

              // Check if it's valid JSON
              if (deviceInfoString.startsWith('{') && deviceInfoString.contains('}')) {
                final endIndex = deviceInfoString.indexOf('}') + 1;
                final validJson = deviceInfoString.substring(0, endIndex);

                debugPrint('📱 Parsed device info: $validJson');

                try {
                  final deviceInfo = jsonDecode(validJson);

                  // Extract device ID
                  if (deviceInfo.containsKey('deviceId')) {
                    final remoteDeviceId = deviceInfo['deviceId'] as String;
                    debugPrint('📱 Remote device ID: $remoteDeviceId');

                    // Update device in discovered devices list
                    final deviceIndex = _discoveredDevices.indexWhere((d) => d.id == peripheralId);
                    if (deviceIndex >= 0) {
                      // Create new metadata map or use existing
                      final deviceMetadata = _discoveredDevices[deviceIndex].metadata ?? {};
                      deviceMetadata['remoteDeviceId'] = remoteDeviceId;

                      _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
                        supportsRelay: deviceInfo['supportsRelay'] == true,
                        metadata: deviceMetadata,
                      );
                      _devicesSubject.add(_discoveredDevices);
                    }
                  }

                  // Check protocol version compatibility
                  final remoteProtocolVersion = deviceInfo['protocolVersion'];
                  if (remoteProtocolVersion != null && remoteProtocolVersion < protocolVersion) {
                    debugPrint('⚠️ Device using older protocol version: $remoteProtocolVersion');
                  }

                  // Check if device supports relay
                  final supportsRelay = deviceInfo['supportsRelay'] == true;
                  debugPrint('📱 Device supports relay: $supportsRelay');

                  // Update device in discovered devices list with additional info
                  final deviceIndex = _discoveredDevices.indexWhere((d) => d.id == peripheralId);
                  if (deviceIndex >= 0) {
                    _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
                      supportsRelay: supportsRelay,
                    );
                    _devicesSubject.add(_discoveredDevices);
                  }
                } catch (e) {
                  debugPrint('⚠️ Error parsing device info JSON: $e');
                }
              }
            } catch (e) {
              debugPrint('⚠️ Error processing device info string: $e');
            }
          } catch (e) {
            debugPrint('⚠️ Failed to read device info: $e');
            // Non-fatal, continue anyway
          }
        }

        // Service discovery successful
        debugPrint('✅ Service discovery completed successfully for device: $peripheralId');
        _errorRecoveryManager.operationSucceeded();
        return;
      } catch (e, stack) {
        debugPrint('❌ Failed to discover services: $e');
        errorMetrics.recordServiceDiscoveryFailure(peripheralId);
        debugPrint('❌ Stack trace: $stack');

        // Update device connection failure count
        final deviceIndex = _discoveredDevices.indexWhere(
                (d) => d.id == peripheralId
        );

        if (deviceIndex >= 0) {
          // Increment failure count and mark as disconnected
          final previousState = _discoveredDevices[deviceIndex].deviceConnectionState;
          _discoveredDevices[deviceIndex] = _discoveredDevices[deviceIndex].copyWith(
            failedConnectionAttempts: _discoveredDevices[deviceIndex].failedConnectionAttempts + 1,
            connectionState: ConnectionState.disconnected,
            deviceConnectionState: DeviceConnectionState.disconnected,
          );
          _devicesSubject.add(_discoveredDevices);
          debugPrint('🔄 Updated device state from $previousState to ${_discoveredDevices[deviceIndex].deviceConnectionState}');
        }

        // Try to disconnect to cleanup
        try {
          debugPrint('🔄 Attempting to disconnect to clean up resources');
          await _centralManager.disconnect(peripheral);
          debugPrint('✅ Disconnect for cleanup successful');
        } catch (disconnectError) {
          debugPrint('⚠️ Disconnect during cleanup failed: $disconnectError');
        }

        // Make sure connection pool knows this attempt is done
        _connectionPool.connectionCompleted(peripheral);
        debugPrint('🔄 Notified connection pool that attempt is complete');

        // Log error to error recovery manager
        _errorRecoveryManager.handleError('discoverServices', e);
      } finally {
        // Always clear the discovery in progress flag, even if an error occurred
        _discoveryInProgress.remove(peripheralId);
      }
    });
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

  Future<int> deleteMessagesForRecipient(String recipientId) async {
    return _stateLock.synchronized(() async {
      int count = 0;

      // Find and remove messages where this is the recipient
      _messages.removeWhere((m) {
        final isForRecipient = m.recipientId == recipientId;
        if (isForRecipient) count++;
        return isForRecipient;
      });

      // Also cancel any pending futures
      _outgoingMessageCompleters.removeWhere((id, completer) {
        final message = _messages.firstWhere(
                (m) => m.id == id,
            orElse: () => BleMessage(
                id: '',
                senderId: '',
                recipientId: '',
                content: '',
                timestamp: DateTime.now()
            )
        );

        if (message.id.isEmpty || message.recipientId == recipientId) {
          if (!completer.isCompleted) {
            completer.complete(false);
          }
          return true;
        }
        return false;
      });

      if (count > 0) {
        _messagesSubject.add(_messages);
        await _saveMessages();
      }

      return count;
    });
  }

  /// Delete all messages related to a contact (both sent and received)
  Future<int> deleteAllMessagesForContact(String contactId) async {
    return _stateLock.synchronized(() async {
      int count = 0;

      // Remove all messages where this contact is the sender or recipient
      _messages.removeWhere((m) {
        final isRelated = m.senderId == contactId || m.recipientId == contactId;
        if (isRelated) count++;
        return isRelated;
      });

      // Clean up completers
      _outgoingMessageCompleters.removeWhere((id, completer) {
        // If completer refers to a message that doesn't exist anymore, complete it and remove
        final exists = _messages.any((m) => m.id == id);
        if (!exists && !completer.isCompleted) {
          completer.complete(false);
          return true;
        }
        return false;
      });

      if (count > 0) {
        _messagesSubject.add(_messages);
        await _saveMessages();
      }

      return count;
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
    _jniHealthCheckTimer?.cancel();

    _devicesSubject.close();
    _messagesSubject.close();
    _connectionStateSubject.close();
    _errorSubject.close();
    _jniStatusSubject.close();

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
    return _initLock.synchronized(() async {
      if (_isInitialized) return;

      debugPrint('BLE Service initializing...');

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
          }
        }

        _isInitialized = true;
        debugPrint('Notification service initialized successfully');
      } catch (e) {
        debugPrint('Failed to initialize notification service: $e');
      }
    });
  }

  Future<void> requestPermissions() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (Platform.isAndroid) {
      try {
        final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
        _notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

        if (androidPlugin != null) {
          // Request permissions with proper error handling
          try {
            final bool? granted = await androidPlugin.requestNotificationsPermission();
            debugPrint('Notification permission granted: $granted');
          } catch (e) {
            debugPrint('Failed to request notification permission: $e');
          }
        }
      } catch (e) {
        debugPrint('Error requesting notification permissions: $e');
      }
    }
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

class ResilientConnectionManager {
  final Map<String, DateTime> _failedConnectionAttempts = {};
  final Set<String> _pendingConnections = {};
  final Duration _reconnectCooldown = const Duration(seconds: 30);
  final Map<String, int> _connectionSuccess = {};
  final Map<String, int> _connectionFailures = {};


  double getConnectionSuccessRate(String deviceId) {
    final successes = _connectionSuccess[deviceId] ?? 0;
    final failures = _connectionFailures[deviceId] ?? 0;

    if (successes + failures == 0) return 1.0; // No history yet

    return successes / (successes + failures);
  }

  bool canAttemptConnection(String deviceId) {
    if (_pendingConnections.contains(deviceId)) return false;

    final lastAttempt = _failedConnectionAttempts[deviceId];
    if (lastAttempt != null) {
      // Calculate adaptive cooldown based on success rate
      Duration adaptiveCooldown = _reconnectCooldown; // Default cooldown

      // Calculate based on success rate
      final successes = _connectionSuccess[deviceId] ?? 0;
      final failures = _connectionFailures[deviceId] ?? 0;

      if (failures > 0) {
        // Poor success rate = longer cooldown
        final ratio = successes / (successes + failures);
        if (ratio < 0.3) {
          adaptiveCooldown = const Duration(seconds: 120); // 2 minutes for unreliable devices
        } else if (ratio < 0.6) {
          adaptiveCooldown = const Duration(seconds: 60); // 1 minute for moderately reliable
        }
      }

      final timeSinceLastAttempt = DateTime.now().difference(lastAttempt);
      if (timeSinceLastAttempt < adaptiveCooldown) return false;
    }

    return true;
  }

  void markConnectionAttemptStarted(String deviceId) {
    _pendingConnections.add(deviceId);
  }

  void markConnectionAttemptFailed(String deviceId) {
    _pendingConnections.remove(deviceId);
    _failedConnectionAttempts[deviceId] = DateTime.now();

    // Track metrics
    _connectionFailures[deviceId] = (_connectionFailures[deviceId] ?? 0) + 1;
  }

  void markConnectionAttemptSucceeded(String deviceId) {
    _pendingConnections.remove(deviceId);
    _failedConnectionAttempts.remove(deviceId);

    // Track metrics
    _connectionSuccess[deviceId] = (_connectionSuccess[deviceId] ?? 0) + 1;
  }

  void reset() {
    _pendingConnections.clear();
    _failedConnectionAttempts.clear();
  }
}

class ScanParameters {
  final Duration duration;
  final bool lowPower;

  ScanParameters(this.duration, this.lowPower);
}

class BackoffInfo {
  final int seconds;
  final int minutes;

  BackoffInfo({
    required this.seconds,
    required this.minutes,
  });
}

class BleErrorMetrics {
  int connectionFailures = 0;
  int serviceDiscoveryFailures = 0;
  int writeFailures = 0;
  int readFailures = 0;
  int scanFailures = 0;
  Map<String, int> deviceSpecificFailures = {};

  void recordConnectionFailure(String deviceId) {
    connectionFailures++;
    deviceSpecificFailures[deviceId] = (deviceSpecificFailures[deviceId] ?? 0) + 1;
  }

  void recordServiceDiscoveryFailure(String deviceId) {
    serviceDiscoveryFailures++;
    deviceSpecificFailures[deviceId] = (deviceSpecificFailures[deviceId] ?? 0) + 1;
  }

  void recordWriteFailure(String deviceId) {
    writeFailures++;
    deviceSpecificFailures[deviceId] = (deviceSpecificFailures[deviceId] ?? 0) + 1;
  }

  void recordReadFailure(String deviceId) {
    readFailures++;
    deviceSpecificFailures[deviceId] = (deviceSpecificFailures[deviceId] ?? 0) + 1;
  }

  void recordScanFailure() {
    scanFailures++;
  }

  Map<String, dynamic> getMetrics() {
    return {
      'connectionFailures': connectionFailures,
      'serviceDiscoveryFailures': serviceDiscoveryFailures,
      'writeFailures': writeFailures,
      'readFailures': readFailures,
      'scanFailures': scanFailures,
      'deviceSpecificFailures': deviceSpecificFailures,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  void reset() {
    connectionFailures = 0;
    serviceDiscoveryFailures = 0;
    writeFailures = 0;
    readFailures = 0;
    scanFailures = 0;
    deviceSpecificFailures.clear();
  }
}

class MessageQueueHealth {
  int totalMessagesSent = 0;
  int successfulDeliveries = 0;
  int failedDeliveries = 0;
  int pendingMessages = 0;
  Duration averageDeliveryTime = Duration.zero;
  List<Duration> recentDeliveryTimes = [];

  void recordMessageSent() {
    totalMessagesSent++;
  }

  void recordDeliverySuccess(Duration deliveryTime) {
    successfulDeliveries++;

    // Track recent delivery times (keep last 20)
    recentDeliveryTimes.add(deliveryTime);
    if (recentDeliveryTimes.length > 20) {
      recentDeliveryTimes.removeAt(0);
    }

    // Update average
    if (recentDeliveryTimes.isNotEmpty) {
      int totalMs = 0;
      for (final time in recentDeliveryTimes) {
        totalMs += time.inMilliseconds;
      }
      averageDeliveryTime = Duration(milliseconds: totalMs ~/ recentDeliveryTimes.length);
    }
  }

  void recordDeliveryFailure() {
    failedDeliveries++;
  }

  void updatePendingCount(int count) {
    pendingMessages = count;
  }

  Map<String, dynamic> getMetrics() {
    final successRate = totalMessagesSent > 0
        ? '${(successfulDeliveries / totalMessagesSent * 100).toStringAsFixed(1)}%'
        : 'N/A';

    return {
      'totalMessagesSent': totalMessagesSent,
      'successfulDeliveries': successfulDeliveries,
      'failedDeliveries': failedDeliveries,
      'pendingMessages': pendingMessages,
      'successRate': successRate,
      'averageDeliveryTime': '${averageDeliveryTime.inSeconds}.${averageDeliveryTime.inMilliseconds % 1000 ~/ 100}s',
      'timestamp': DateTime.now().toIso8601String(),
    };
  }
}

class ConnectionStabilityMonitor {
  final Map<String, List<DateTime>> _connectionEvents = {};
  final Duration _unstablePeriod = const Duration(minutes: 5);

  void recordConnectionEvent(String deviceId, bool connected) {
    if (!_connectionEvents.containsKey(deviceId)) {
      _connectionEvents[deviceId] = [];
    }

    _connectionEvents[deviceId]!.add(DateTime.now());

    // Cleanup old events
    final cutoff = DateTime.now().subtract(_unstablePeriod);
    _connectionEvents[deviceId] = _connectionEvents[deviceId]!
        .where((time) => time.isAfter(cutoff))
        .toList();
  }

  bool isConnectionUnstable(String deviceId) {
    if (!_connectionEvents.containsKey(deviceId)) return false;

    // If more than 5 connection events in 5 minutes, consider unstable
    return _connectionEvents[deviceId]!.length > 5;
  }

  void reset(String deviceId) {
    _connectionEvents.remove(deviceId);
  }

  // Get all unstable device IDs
  List<String> getUnstableDevices() {
    return _connectionEvents.entries
        .where((entry) => entry.value.length > 5)
        .map((entry) => entry.key)
        .toList();
  }
}