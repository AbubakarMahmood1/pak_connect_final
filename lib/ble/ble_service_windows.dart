// ble_service_windows.dart
import 'dart:async';
import 'package:flutter/services.dart';
import 'ble_service.dart';

/// Windows-specific implementation of BLE service using method channels
class BleServiceWindows implements BleService {
  static const _channel = MethodChannel('pak_connect/ble_windows');

  // Controllers for stream-based reactivity
  final _scanResultsController = StreamController<List<BleDeviceInfo>>.broadcast();
  final _connectionStateController = StreamController<ConnectionInfo>.broadcast();
  final _advertisingStateController = StreamController<bool>.broadcast();
  final _bluetoothStateController = StreamController<String>.broadcast();

  // Internal state tracking
  bool _isScanning = false;
  bool _isAdvertising = false;
  bool _isInitialized = false;
  final List<BleDeviceInfo> _discoveredDevices = [];
  final Map<String, dynamic> _connectedDevices = {};

  // Event channels for streaming data from native code
  static const EventChannel _scanResultsChannel = EventChannel('pak_connect/ble_windows/scan_results');
  static const EventChannel _connectionStateChannel = EventChannel('pak_connect/ble_windows/connection_state');
  static const EventChannel _bluetoothStateChannel = EventChannel('pak_connect/ble_windows/bluetooth_state');

  // Stream subscriptions to manage
  StreamSubscription? _scanResultsSubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _bluetoothStateSubscription;

  // Stream getters
  @override
  Stream<List<BleDeviceInfo>> get scanResults => _scanResultsController.stream;

  @override
  Stream<ConnectionInfo> get connectionState => _connectionStateController.stream;

  @override
  Stream<bool> get advertisingState => _advertisingStateController.stream;

  @override
  Stream<String> get bluetoothState => _bluetoothStateController.stream;

  // State getters
  @override
  bool get isScanning => _isScanning;

  @override
  bool get isAdvertising => _isAdvertising;

  @override
  List<BleDeviceInfo> get discoveredDevices => List<BleDeviceInfo>.from(_discoveredDevices);

  /// Initialize the Windows BLE service
  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Register the method call handler
      _channel.setMethodCallHandler(_handleMethodCall);

      // Initialize the native Windows BLE service
      final result = await _channel.invokeMethod('initialize');
      print('Windows BLE initialize result: $result');

      // Listen for scan results from native code
      _scanResultsSubscription = _scanResultsChannel.receiveBroadcastStream().listen((event) {
        _handleScanResults(event);
      }, onError: (error) {
        print('Scan results stream error: $error');
      });

      // Listen for connection state changes from native code
      _connectionStateSubscription = _connectionStateChannel.receiveBroadcastStream().listen((event) {
        _handleConnectionStateUpdate(event);
      }, onError: (error) {
        print('Connection state stream error: $error');
      });

      // Listen for Bluetooth adapter state changes from native code
      _bluetoothStateSubscription = _bluetoothStateChannel.receiveBroadcastStream().listen((event) {
        _bluetoothStateController.add(event.toString());
      }, onError: (error) {
        print('Bluetooth state stream error: $error');
      });

      _isInitialized = true;
      print('Windows BLE Service initialized');
    } catch (e) {
      print('Windows BLE Service initialization error: $e');
    }
  }

  /// Handle method calls from native code
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onScanStateChanged':
        _isScanning = call.arguments['isScanning'];
        return null;
      case 'onBluetoothStateChanged':
        final state = call.arguments['state'];
        _bluetoothStateController.add(state);
        return null;
      case 'onAdvertisingStateChanged':
        _isAdvertising = call.arguments['isAdvertising'];
        _advertisingStateController.add(_isAdvertising);
        return null;
      default:
        print('Unknown method call: ${call.method}');
        return null;
    }
  }

  /// Handle scan results from native code
  void _handleScanResults(dynamic event) {
    if (event is! List) return;

    _discoveredDevices.clear();

    for (var deviceData in event) {
      final device = BleDeviceInfo(
        device: deviceData['deviceId'],
        rssi: deviceData['rssi'] ?? -100,
        advertisedName: deviceData['name'] ?? 'Unknown',
        deviceId: deviceData['deviceId'],
        platformName: 'Windows',
      );

      _discoveredDevices.add(device);
    }

    _scanResultsController.add(_discoveredDevices);
  }

  /// Handle connection state updates from native code
  void _handleConnectionStateUpdate(dynamic event) {
    if (event is! Map) return;

    final deviceId = event['deviceId'];
    final stateName = event['state'];
    final isConnected = event['isConnected'] ?? false;

    final connectionInfo = ConnectionInfo(
      device: deviceId,
      state: stateName,
      isConnected: isConnected,
    );

    // Update connected devices map
    if (isConnected) {
      _connectedDevices[deviceId] = connectionInfo;
    } else {
      _connectedDevices.remove(deviceId);
    }

    _connectionStateController.add(connectionInfo);
  }

  /// Check if Bluetooth is available and enabled on Windows
  @override
  Future<bool> isBluetoothAvailable() async {
    if (!_isInitialized) await initialize();

    try {
      final result = await _channel.invokeMethod('isBluetoothAvailable');
      return result == true;
    } catch (e) {
      print('Error checking Windows Bluetooth availability: $e');
      return false;
    }
  }

  /// Start scanning for BLE devices
  @override
  Future<bool> startScanning({
    List<String> withServices = const [],
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_isInitialized) await initialize();
    if (_isScanning) return true;

    try {
      // Clear previous scan results
      _discoveredDevices.clear();
      _scanResultsController.add(_discoveredDevices);

      // Start scanning through the platform channel
      final result = await _channel.invokeMethod('startScan', {
        'withServices': withServices,
        'timeoutMs': timeout.inMilliseconds,
      });

      _isScanning = result == true;
      return _isScanning;
    } catch (e) {
      print('Windows start scanning error: $e');
      return false;
    }
  }

  /// Stop scanning for BLE devices
  @override
  Future<void> stopScanning() async {
    if (!_isInitialized || !_isScanning) return;

    try {
      await _channel.invokeMethod('stopScan');
      _isScanning = false;
    } catch (e) {
      print('Windows stop scanning error: $e');
    }
  }

  /// Start advertising as a peripheral (may not be available on Windows)
  @override
  Future<bool> startAdvertising(String deviceId, String serviceUuid) async {
    if (!_isInitialized) await initialize();

    try {
      final result = await _channel.invokeMethod('startAdvertising', {
        'deviceId': deviceId,
        'serviceUuid': serviceUuid,
      });

      _isAdvertising = result == true;
      _advertisingStateController.add(_isAdvertising);
      return _isAdvertising;
    } catch (e) {
      print('Windows start advertising error: $e');
      return false;
    }
  }

  /// Stop advertising as a peripheral
  @override
  Future<bool> stopAdvertising() async {
    if (!_isInitialized || !_isAdvertising) return true;

    try {
      final result = await _channel.invokeMethod('stopAdvertising');
      _isAdvertising = false;
      _advertisingStateController.add(_isAdvertising);
      return result == true;
    } catch (e) {
      print('Windows stop advertising error: $e');
      return false;
    }
  }

  /// Connect to a discovered device
  @override
  Future<bool> connectToDevice(dynamic device, {
    Duration timeout = const Duration(seconds: 15),
    int maxRetries = 3,
  }) async {
    if (!_isInitialized) await initialize();

    String deviceId;
    if (device is String) {
      deviceId = device;
    } else if (device is BleDeviceInfo) {
      deviceId = device.deviceId;
    } else {
      throw ArgumentError('Invalid device parameter type: ${device.runtimeType}');
    }

    if (_connectedDevices.containsKey(deviceId)) {
      print('Device already connected: $deviceId');
      return true;
    }

    bool connected = false;

    // Try connecting with retries
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        print('Windows connection attempt $attempt of $maxRetries');

        final result = await _channel.invokeMethod('connectToDevice', {
          'deviceId': deviceId,
          'timeoutMs': timeout.inMilliseconds,
        });

        connected = result == true;
        if (connected) break;

        // Wait before retrying
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: 2));
        }
      } catch (e) {
        print('Windows connection attempt $attempt failed: $e');

        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: 2));
        }
      }
    }

    return connected;
  }

  /// Disconnect from a device
  @override
  Future<bool> disconnectDevice(dynamic device) async {
    if (!_isInitialized) await initialize();

    String deviceId;
    if (device is String) {
      deviceId = device;
    } else if (device is BleDeviceInfo) {
      deviceId = device.deviceId;
    } else {
      throw ArgumentError('Invalid device parameter type: ${device.runtimeType}');
    }

    if (!_connectedDevices.containsKey(deviceId)) {
      print('Device not connected: $deviceId');
      return false;
    }

    try {
      final result = await _channel.invokeMethod('disconnectDevice', {
        'deviceId': deviceId,
      });

      return result == true;
    } catch (e) {
      print('Windows disconnect error: $e');
      return false;
    }
  }

  /// Discover services for a connected device
  @override
  Future<List<dynamic>> discoverServices(dynamic device) async {
    if (!_isInitialized) await initialize();

    String deviceId;
    if (device is String) {
      deviceId = device;
    } else if (device is BleDeviceInfo) {
      deviceId = device.deviceId;
    } else {
      throw ArgumentError('Invalid device parameter type: ${device.runtimeType}');
    }

    if (!_connectedDevices.containsKey(deviceId)) {
      print('Device not connected: $deviceId');
      return [];
    }

    try {
      final result = await _channel.invokeMethod('discoverServices', {
        'deviceId': deviceId,
      });

      if (result is List) {
        return result;
      }

      return [];
    } catch (e) {
      print('Windows discover services error: $e');
      return [];
    }
  }

  /// Write data to a characteristic
  @override
  Future<bool> writeCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      List<int> data,
      {bool withResponse = true}
      ) async {
    if (!_isInitialized) await initialize();

    String deviceId;
    if (device is String) {
      deviceId = device;
    } else if (device is BleDeviceInfo) {
      deviceId = device.deviceId;
    } else {
      throw ArgumentError('Invalid device parameter type: ${device.runtimeType}');
    }

    if (!_connectedDevices.containsKey(deviceId)) {
      print('Device not connected: $deviceId');
      return false;
    }

    try {
      final result = await _channel.invokeMethod('writeCharacteristic', {
        'deviceId': deviceId,
        'serviceUuid': serviceUuid,
        'characteristicUuid': characteristicUuid,
        'data': data,
        'withResponse': withResponse,
      });

      return result == true;
    } catch (e) {
      print('Windows write characteristic error: $e');
      return false;
    }
  }

  /// Read data from a characteristic
  @override
  Future<List<int>?> readCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      ) async {
    if (!_isInitialized) await initialize();

    String deviceId;
    if (device is String) {
      deviceId = device;
    } else if (device is BleDeviceInfo) {
      deviceId = device.deviceId;
    } else {
      throw ArgumentError('Invalid device parameter type: ${device.runtimeType}');
    }

    if (!_connectedDevices.containsKey(deviceId)) {
      print('Device not connected: $deviceId');
      return null;
    }

    try {
      final result = await _channel.invokeMethod('readCharacteristic', {
        'deviceId': deviceId,
        'serviceUuid': serviceUuid,
        'characteristicUuid': characteristicUuid,
      });

      if (result is List<int>) {
        return result;
      } else if (result is Uint8List) {
        return result.toList();
      }

      return null;
    } catch (e) {
      print('Windows read characteristic error: $e');
      return null;
    }
  }

  /// Subscribe to notifications from a characteristic
  @override
  Future<Stream<List<int>>?> subscribeToCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      ) async {
    if (!_isInitialized) await initialize();

    String deviceId;
    if (device is String) {
      deviceId = device;
    } else if (device is BleDeviceInfo) {
      deviceId = device.deviceId;
    } else {
      throw ArgumentError('Invalid device parameter type: ${device.runtimeType}');
    }

    if (!_connectedDevices.containsKey(deviceId)) {
      print('Device not connected: $deviceId');
      return null;
    }

    try {
      final String notificationChannelName = 'pak_connect/ble_windows/notification_$deviceId\_$serviceUuid\_$characteristicUuid';
      final EventChannel notificationChannel = EventChannel(notificationChannelName);

      // Tell native code to start notifications and use this channel
      final result = await _channel.invokeMethod('subscribeToCharacteristic', {
        'deviceId': deviceId,
        'serviceUuid': serviceUuid,
        'characteristicUuid': characteristicUuid,
        'notificationChannel': notificationChannelName,
      });

      if (result == true) {
        // Return a stream that converts the incoming data to List<int>
        return notificationChannel.receiveBroadcastStream().map((event) {
          if (event is List<int>) {
            return event;
          } else if (event is Uint8List) {
            return event.toList();
          }
          return <int>[];
        });
      }

      return null;
    } catch (e) {
      print('Windows subscribe to characteristic error: $e');
      return null;
    }
  }

  /// Unsubscribe from notifications
  @override
  Future<bool> unsubscribeFromCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      ) async {
    if (!_isInitialized) await initialize();

    String deviceId;
    if (device is String) {
      deviceId = device;
    } else if (device is BleDeviceInfo) {
      deviceId = device.deviceId;
    } else {
      throw ArgumentError('Invalid device parameter type: ${device.runtimeType}');
    }

    try {
      final result = await _channel.invokeMethod('unsubscribeFromCharacteristic', {
        'deviceId': deviceId,
        'serviceUuid': serviceUuid,
        'characteristicUuid': characteristicUuid,
      });

      return result == true;
    } catch (e) {
      print('Windows unsubscribe from characteristic error: $e');
      return false;
    }
  }

  /// Get signal strength icon and color based on RSSI value
  @override
  Map<String, dynamic> getSignalStrength(int rssi) {
    String iconName;
    String colorName;

    if (rssi >= -60) {
      iconName = 'signalCellular3';
      colorName = 'green';
    } else if (rssi >= -70) {
      iconName = 'signalCellular2';
      colorName = 'lightGreen';
    } else if (rssi >= -80) {
      iconName = 'signalCellular1';
      colorName = 'orange';
    } else {
      iconName = 'signalCellularOutline';
      colorName = 'red';
    }

    return {'icon': iconName, 'color': colorName};
  }

  /// Clean up resources when service is no longer needed
  @override
  void dispose() {
    print('Disposing Windows BLE Service');

    // Cancel all subscriptions
    _scanResultsSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _bluetoothStateSubscription?.cancel();

    // Close all stream controllers
    _scanResultsController.close();
    _connectionStateController.close();
    _advertisingStateController.close();
    _bluetoothStateController.close();

    // Stop operations
    stopScanning();
    stopAdvertising();

    // Inform native code to clean up
    _channel.invokeMethod('dispose');
  }
}