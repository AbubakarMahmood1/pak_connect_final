import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'ble_background_service.dart';
import 'ble_background_service_factory.dart';

// Utility class to interface with BLE background service
class BleServiceUtility {
  // Instance of the BLE service obtained from the factory
  static late BleBackgroundService _service;

  // Stream controllers for service status
  static final _serviceStatusController = StreamController<bool>.broadcast();

  // Expose streams for listening
  static Stream<List<Map<String, dynamic>>> get scanResults => _service.scanResults.map((result) => List<Map<String, dynamic>>.from(result['devices'] ?? []));
  static Stream<Map<String, dynamic>> get connectionState => _service.connectionState;
  static Stream<Map<String, dynamic>> get bluetoothState => _service.bluetoothState;
  static Stream<bool> get advertisingState => _service.advertisingState.map((state) => state['isAdvertising'] == true);
  static Stream<bool> get serviceStatus => _serviceStatusController.stream;
  // Restore operation result streams (assuming BleBackgroundService is extended)
  static Stream<Map<String, dynamic>> get writeResults => _service.writeResults;
  static Stream<Map<String, dynamic>> get readResults => _service.readResults;
  static Stream<Map<String, dynamic>> get connectResults => _service.connectResults;
  static Stream<Map<String, dynamic>> get disconnectResults => _service.disconnectResults;

  // Initialize the utility
  static Future<void> initialize() async {
    // Get the appropriate service implementation from the factory
    _service = BleBackgroundServiceFactory.getService();

    // Initialize the service
    await _service.initialize();

    // Start monitoring service status
    _monitorServiceStatus();
  }

  // Monitor service running status
  static void _monitorServiceStatus() {
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      final isRunning = await _service.isRunning(); // Requires isRunning in BleBackgroundService
      _serviceStatusController.add(isRunning);
    });
  }

  // Start the background service
  static Future<bool> startBackgroundService() async {
    return await _service.startService();
  }

  // Stop the background service
  static Future<bool> stopBackgroundService() async {
    return await _service.stopService();
  }

  // Start scanning for devices
  static Future<void> startScanning({
    List<String>? withServices,
    int timeoutSeconds = 10,
  }) async {
    final isRunning = await _service.startService();
    if (isRunning) {
      _service.startScanning(services: withServices ?? [], timeout: timeoutSeconds);
    }
  }

  // Stop scanning for devices
  static Future<void> stopScanning() async {
    _service.stopScanning();
  }

  // Start advertising
  static Future<void> startAdvertising(String deviceId, String serviceUuid) async {
    final isRunning = await _service.startService();
    if (isRunning) {
      _service.startAdvertising(deviceId, serviceUuid);
    }
  }

  // Stop advertising
  static Future<void> stopAdvertising() async {
    _service.stopAdvertising();
  }

  // Connect to a BLE device
  static Future<void> connectToDevice(
      String remoteId, {
        int timeout = 15,
        int maxRetries = 3,
      }) async {
    final isRunning = await _service.startService();
    if (isRunning) {
      _service.connectToDevice(remoteId, timeout: timeout, maxRetries: maxRetries);
    }
  }

  // Disconnect from a BLE device
  static Future<void> disconnectDevice(String remoteId) async {
    _service.disconnectDevice(remoteId);
  }

  // Write to a characteristic
  static Future<void> writeCharacteristic({
    required String remoteId,
    required String serviceUuid,
    required String characteristicUuid,
    required String data,
    String format = 'utf8',
    bool withResponse = true,
  }) async {
    _service.writeCharacteristic(
      remoteId,
      serviceUuid,
      characteristicUuid,
      data,
      format: format,
      withResponse: withResponse,
    );
  }

  // Read from a characteristic
  static Future<void> readCharacteristic({
    required String remoteId,
    required String serviceUuid,
    required String characteristicUuid,
    String format = 'utf8',
  }) async {
    _service.readCharacteristic(
      remoteId,
      serviceUuid,
      characteristicUuid,
      format: format,
    );
  }

  // Get the service status (running or not)
  static Future<bool> isServiceRunning() async {
    return await _service.isRunning();
  }

  // Helper method to get a stored device ID or generate a new one
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString('ble_device_id');
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await prefs.setString('ble_device_id', deviceId);
    }
    return deviceId;
  }

  // Clean up resources when done
  static void dispose() {
    _serviceStatusController.close();
    // Service streams are managed by the BleBackgroundService implementation
  }
}