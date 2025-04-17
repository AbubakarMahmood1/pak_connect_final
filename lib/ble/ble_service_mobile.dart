// ble_service_mobile.dart
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'ble_service.dart';

/// Mobile (iOS/Android) implementation of BLE service
class BleServiceMobile implements BleService {
  
  // Controllers for stream-based reactivity
  final _scanResultsController = StreamController<List<BleDeviceInfo>>.broadcast();
  final _connectionStateController = StreamController<ConnectionInfo>.broadcast();
  final _advertisingStateController = StreamController<bool>.broadcast();
  final _bluetoothStateController = StreamController<BluetoothAdapterState>.broadcast();

  // Internal state tracking
  bool _isScanning = false;
  bool _isAdvertising = false;
  final List<BleDeviceInfo> _discoveredDevices = [];
  final Map<String, BluetoothDevice> _connectedDevices = {};

  // Create an instance of the peripheral plugin
  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  AdvertiseData? _currentAdvertisement;

  // Stream getters
  @override
  Stream<List<BleDeviceInfo>> get scanResults => _scanResultsController.stream;

  @override
  Stream<ConnectionInfo> get connectionState => _connectionStateController.stream;

  @override
  Stream<bool> get advertisingState => _advertisingStateController.stream;

  @override
  Stream<BluetoothAdapterState> get bluetoothState => _bluetoothStateController.stream;

  // State getters
  @override
  bool get isScanning => _isScanning;

  @override
  bool get isAdvertising => _isAdvertising;

  @override
  List<BleDeviceInfo> get discoveredDevices => List<BleDeviceInfo>.from(_discoveredDevices);

  // Stream subscriptions to manage
  StreamSubscription? _scanResultsSubscription;
  StreamSubscription? _isScanningSubscription;
  StreamSubscription? _adapterStateSubscription;
  StreamSubscription? _peripheralStateSubscription;

  /// Initialize the BLE service
  @override
  Future<void> initialize() async {
    try {
      // Monitor Bluetooth adapter state
      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((state) {
        _bluetoothStateController.add(state);
      });

      // Wait for a valid adapter state
      await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
        const Duration(seconds: 5),
        onTimeout: () => BluetoothAdapterState.unavailable,
      );

      _monitorAdvertisingState();

      print('Mobile BLE Service initialized');
    } catch (e) {
      print('Mobile BLE Service initialization error: $e');
    }
  }

  /// Monitor if device is currently advertising
  void _monitorAdvertisingState() {
    // Check advertising status periodically
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      final isAdvertising = await _blePeripheral.isAdvertising;
      if (_isAdvertising != isAdvertising) {
        _isAdvertising = isAdvertising;
        _advertisingStateController.add(isAdvertising);
      }
    });
  }

  /// Check if Bluetooth is available and enabled
  @override
  Future<bool> isBluetoothAvailable() async {
    try {
      if (await FlutterBluePlus.isSupported == false) {
        return false;
      }

      // Wait for a valid adapter state
      BluetoothAdapterState state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first.timeout(
        const Duration(seconds: 3),
        onTimeout: () => BluetoothAdapterState.unavailable,
      );

      return state == BluetoothAdapterState.on;
    } catch (e) {
      print('Error checking Bluetooth availability: $e');
      return false;
    }
  }

  /// Start scanning for BLE devices
  @override
  Future<bool> startScanning({
    List<String> withServices = const [],
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_isScanning) return true;

    try {
      // Clear previous scan results
      _discoveredDevices.clear();
      _scanResultsController.add(_discoveredDevices);

      // Check permissions
      bool hasPermissions = await _checkPermissions();
      if (!hasPermissions) {
        print('BLE scanning permission denied');
        return false;
      }

      // Check Bluetooth state
      if (!await isBluetoothAvailable()) {
        print('Bluetooth is not available or not enabled');
        return false;
      }

      // Convert service UUIDs to Guid objects
      List<Guid> serviceGuids = withServices.map((uuid) => Guid(uuid)).toList();

      // Start the scan
      await FlutterBluePlus.startScan(
        withServices: serviceGuids,
        timeout: timeout,
      );

      _isScanning = true;

      // Listen for scan results
      await _scanResultsSubscription?.cancel();
      _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
        _processScanResults(results);
      });

      // Monitor scanning state
      await _isScanningSubscription?.cancel();
      _isScanningSubscription = FlutterBluePlus.isScanning.listen((scanning) {
        _isScanning = scanning;
        if (!scanning) {
          _scanResultsController.add(_discoveredDevices);
        }
      });

      return true;
    } catch (e) {
      print('Start scanning error: $e');
      _isScanning = false;
      return false;
    }
  }

  /// Process scan results and update the discovered devices list
  void _processScanResults(List<ScanResult> results) {
    for (var result in results) {
      final remoteId = result.device.remoteId;

      // Get the device name - prefer advertised name, fall back to platform name
      String deviceName = result.advertisementData.advName;
      if (deviceName.isEmpty) {
        deviceName = result.device.platformName;
      }

      // Extract device ID from name (e.g., "MyApp-12345678" -> "12345678")
      String deviceId = "Unknown";
      if (deviceName.startsWith('MyApp-')) {
        deviceId = deviceName.substring(6);
      }

      final existingIndex = _discoveredDevices.indexWhere(
              (d) => (d.device as BluetoothDevice).remoteId == remoteId
      );

      final newDevice = BleDeviceInfo(
        device: result.device,
        rssi: result.rssi,
        advertisedName: deviceName,
        deviceId: deviceId,
        platformName: 'Mobile',
      );

      if (existingIndex == -1) {
        // New device
        _discoveredDevices.add(newDevice);
      } else {
        // Update existing device
        _discoveredDevices[existingIndex] = newDevice;
      }
    }

    // Broadcast the updated list
    _scanResultsController.add(_discoveredDevices);
  }

  /// Stop scanning for BLE devices
  @override
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      print("Stop scan error: $e");
    }

    _isScanning = false;
  }

  /// Start advertising as a peripheral
  @override
  Future<bool> startAdvertising(String deviceId, String serviceUuid) async {
    if (_isAdvertising) return true;

    try {
      // Check permissions
      bool hasPermissions = await _checkPermissions();
      if (!hasPermissions) {
        print('BLE advertising permission denied');
        return false;
      }

      // Check Bluetooth state
      if (!await isBluetoothAvailable()) {
        print('Bluetooth is not available or not enabled');
        return false;
      }

      // Convert the device ID to bytes for the manufacturer data
      final List<int> deviceIdBytes = deviceId.codeUnits;

      // Create the advertisement data - format is important for receiving devices
      _currentAdvertisement = AdvertiseData(
        // Standard manufacturer data format: [Company ID (2 bytes), Data]
        manufacturerData: Uint8List.fromList([0xFF, 0xFF, ...deviceIdBytes]),
        serviceUuid: serviceUuid,
        localName: "MyApp-$deviceId",
      );

      // Start advertising
      await _blePeripheral.start(advertiseData: _currentAdvertisement!);
      _isAdvertising = true;
      _advertisingStateController.add(true);

      print('BLE advertising started for device ID: $deviceId');
      return true;
    } catch (e) {
      print('Start advertising error: $e');
      return false;
    }
  }

  /// Stop advertising as a peripheral
  @override
  Future<bool> stopAdvertising() async {
    if (!_isAdvertising) return true;

    try {
      await _blePeripheral.stop();
      _isAdvertising = false;
      _advertisingStateController.add(false);
      print('BLE advertising stopped');
      return true;
    } catch (e) {
      print('Stop advertising error: $e');
      return false;
    }
  }

  /// Connect to a BLE device with retry mechanism
  @override
  Future<bool> connectToDevice(dynamic device, {
    Duration timeout = const Duration(seconds: 15),
    int maxRetries = 3,
  }) async {
    BluetoothDevice bleDevice = device as BluetoothDevice;

    if (_connectedDevices.containsKey(bleDevice.remoteId.toString())) {
      print('Device already connected: ${bleDevice.platformName}');
      return true;
    }

    bool connected = false;
    String error = '';

    // Try connecting with retries
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        print('Connection attempt $attempt of $maxRetries');

        // Connect to the device
        await bleDevice.connect(timeout: timeout);

        // Add to connected devices map
        _connectedDevices[bleDevice.remoteId.toString()] = bleDevice;

        // Listen for connection state changes
        bleDevice.connectionState.listen((state) {
          final update = ConnectionInfo(
            device: bleDevice,
            state: state.name,
            isConnected: state == BluetoothConnectionState.connected,
          );

          _connectionStateController.add(update);

          if (state == BluetoothConnectionState.disconnected) {
            _connectedDevices.remove(bleDevice.remoteId.toString());
          }
        });

        // Negotiate MTU size for Android devices
        if (Platform.isAndroid) {
          try {
            int mtu = await bleDevice.requestMtu(512);
            print('Negotiated MTU: $mtu bytes');
          } catch (e) {
            print('MTU negotiation failed: $e');
          }
        }

        connected = true;
        print('Connected to device: ${bleDevice.platformName}');
        break; // Connection successful, exit retry loop
      } catch (e) {
        error = e.toString();
        print('Connection attempt $attempt failed: $e');

        if (e is Exception && attempt < maxRetries) {
          // Wait before retrying
          await Future.delayed(Duration(seconds: 2));
        }
      }
    }

    if (!connected) {
      print('Failed to connect after $maxRetries attempts: $error');
    }

    return connected;
  }

  /// Disconnect from a BLE device
  @override
  Future<bool> disconnectDevice(dynamic device) async {
    BluetoothDevice bleDevice = device as BluetoothDevice;

    try {
      await bleDevice.disconnect();
      _connectedDevices.remove(bleDevice.remoteId.toString());
      print('Disconnected from device: ${bleDevice.platformName}');
      return true;
    } catch (e) {
      print('Disconnect error: $e');
      return false;
    }
  }

  /// Discover services for a connected device
  @override
  Future<List<BluetoothService>> discoverServices(dynamic device) async {
    BluetoothDevice bleDevice = device as BluetoothDevice;

    try {
      final services = await bleDevice.discoverServices();

      // Log discovered services and characteristics for debugging
      for (var service in services) {
        print('Service UUID: ${service.uuid}');
        for (var characteristic in service.characteristics) {
          print('  Characteristic UUID: ${characteristic.uuid}');
          print('  Properties: read=${characteristic.properties.read}, '
              'write=${characteristic.properties.write}, '
              'notify=${characteristic.properties.notify}');
        }
      }

      return services;
    } catch (e) {
      print('Discover services error: $e');
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
    BluetoothDevice bleDevice = device as BluetoothDevice;

    if (!_connectedDevices.containsKey(bleDevice.remoteId.toString())) {
      print('Device not connected. Cannot write characteristic.');
      return false;
    }

    try {
      // Get the services (discover if not already cached)
      List<BluetoothService> services;
      try {
        services = await bleDevice.discoverServices();
      } catch (e) {
        print('Error discovering services: $e');
        return false;
      }

      // Find the service and characteristic
      final service = services.firstWhere(
            (s) => s.uuid.toString() == serviceUuid,
        orElse: () => throw Exception('Service not found: $serviceUuid'),
      );

      final characteristic = service.characteristics.firstWhere(
            (c) => c.uuid.toString() == characteristicUuid,
        orElse: () => throw Exception('Characteristic not found: $characteristicUuid'),
      );

      // Write the data
      await characteristic.write(
        data,
        withoutResponse: !withResponse,
      );

      print('Write successful: ${data.length} bytes');
      return true;
    } catch (e) {
      print('Write characteristic error: $e');
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
    BluetoothDevice bleDevice = device as BluetoothDevice;

    if (!_connectedDevices.containsKey(bleDevice.remoteId.toString())) {
      print('Device not connected. Cannot read characteristic.');
      return null;
    }

    try {
      // Get the services
      final services = await bleDevice.discoverServices();

      // Find the service and characteristic
      final service = services.firstWhere(
            (s) => s.uuid.toString() == serviceUuid,
        orElse: () => throw Exception('Service not found: $serviceUuid'),
      );

      final characteristic = service.characteristics.firstWhere(
            (c) => c.uuid.toString() == characteristicUuid,
        orElse: () => throw Exception('Characteristic not found: $characteristicUuid'),
      );

      // Read the value
      final value = await characteristic.read();
      print('Read successful: ${utf8.decode(value, allowMalformed: true)}');
      return value;
    } catch (e) {
      print('Read characteristic error: $e');
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
    BluetoothDevice bleDevice = device as BluetoothDevice;

    if (!_connectedDevices.containsKey(bleDevice.remoteId.toString())) {
      print('Device not connected. Cannot subscribe to characteristic.');
      return null;
    }

    try {
      // Get the services
      final services = await bleDevice.discoverServices();

      // Find the service and characteristic
      final service = services.firstWhere(
            (s) => s.uuid.toString() == serviceUuid,
        orElse: () => throw Exception('Service not found: $serviceUuid'),
      );

      final characteristic = service.characteristics.firstWhere(
            (c) => c.uuid.toString() == characteristicUuid,
        orElse: () => throw Exception('Characteristic not found: $characteristicUuid'),
      );

      // Check if the characteristic supports notifications
      if (!characteristic.properties.notify && !characteristic.properties.indicate) {
        throw Exception('Characteristic does not support notifications');
      }

      // Enable notifications
      await characteristic.setNotifyValue(true);
      print('Subscribed to notifications on ${characteristicUuid}');

      return characteristic.lastValueStream;
    } catch (e) {
      print('Subscribe to characteristic error: $e');
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
    BluetoothDevice bleDevice = device as BluetoothDevice;

    try {
      // Get the services
      final services = await bleDevice.discoverServices();

      // Find the service and characteristic
      final service = services.firstWhere(
            (s) => s.uuid.toString() == serviceUuid,
        orElse: () => throw Exception('Service not found'),
      );

      final characteristic = service.characteristics.firstWhere(
            (c) => c.uuid.toString() == characteristicUuid,
        orElse: () => throw Exception('Characteristic not found'),
      );

      // Disable notifications
      await characteristic.setNotifyValue(false);
      print('Unsubscribed from notifications on ${characteristicUuid}');
      return true;
    } catch (e) {
      print('Unsubscribe from characteristic error: $e');
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

  /// Check if required permissions are granted
  Future<bool> _checkPermissions() async {
    if (Platform.isAndroid) {
      // Check if location services are enabled (required for BLE on Android)
      bool locationEnabled = await Geolocator.isLocationServiceEnabled();
      if (!locationEnabled) {
        print('Location services are disabled');
        return false;
      }

      // Request required permissions
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse,
      ].request();

      // Check if all permissions are granted
      bool allGranted = statuses.values.every((status) => status.isGranted);

      // Handle permanently denied permissions
      if (!allGranted) {
        if (statuses.values.any((status) => status.isPermanentlyDenied)) {
          print('Some permissions are permanently denied. Please enable them in settings.');
        } else {
          print('Permission denied: ${statuses.entries.where((e) => !e.value.isGranted).map((e) => e.key).join(", ")}');
        }
      }

      return allGranted;
    } else if (Platform.isIOS) {
      // iOS permissions are simpler but we still request them
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetooth,
      ].request();

      return statuses.values.every((status) => status.isGranted);
    }

    return false;
  }

  /// Clean up resources when service is no longer needed
  @override
  void dispose() {
    print('Disposing BLE Service');

    // Cancel all subscriptions
    _scanResultsSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _peripheralStateSubscription?.cancel();

    // Close all stream controllers
    _scanResultsController.close();
    _connectionStateController.close();
    _advertisingStateController.close();
    _bluetoothStateController.close();

    // Stop scanning and advertising
    stopAdvertising();
    stopScanning();
  }
}