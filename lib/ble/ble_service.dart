import 'dart:async';
import 'ble_service_factory.dart';

/// Abstract BLE service interface that defines common functionality
abstract class BleService {
  static final BleService _instance = getPlatformBleService();

  /// Get the singleton instance of BLE service
  factory BleService() => _instance;

  /// Initialize the BLE service
  Future<void> initialize();

  /// Check if Bluetooth is available and enabled
  Future<bool> isBluetoothAvailable();

  /// Start scanning for BLE devices
  Future<bool> startScanning({
    List<String> withServices,
    Duration timeout,
  });

  /// Stop scanning for BLE devices
  Future<void> stopScanning();

  /// Start advertising as a peripheral (not available on all platforms)
  Future<bool> startAdvertising(String deviceId, String serviceUuid);

  /// Stop advertising as a peripheral
  Future<bool> stopAdvertising();

  /// Connect to a discovered device
  Future<bool> connectToDevice(dynamic device, {
    Duration timeout,
    int maxRetries,
  });

  /// Disconnect from a device
  Future<bool> disconnectDevice(dynamic device);

  /// Discover services for a connected device
  Future<List<dynamic>> discoverServices(dynamic device);

  /// Write data to a characteristic
  Future<bool> writeCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      List<int> data,
      {bool withResponse}
      );

  /// Read data from a characteristic
  Future<List<int>?> readCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      );

  /// Subscribe to notifications from a characteristic
  Future<Stream<List<int>>?> subscribeToCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      );

  /// Unsubscribe from notifications
  Future<bool> unsubscribeFromCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      );

  /// Get signal strength visualization information
  Map<String, dynamic> getSignalStrength(int rssi);

  /// Clean up resources
  void dispose();

  /// Stream getters that platforms need to implement
  Stream<List<dynamic>> get scanResults;
  Stream<dynamic> get connectionState;
  Stream<bool> get advertisingState;
  Stream<dynamic> get bluetoothState;

  /// State getters
  bool get isScanning;
  bool get isAdvertising;
  List<dynamic> get discoveredDevices;
}

/// Model class for BLE device information (platform-independent)
class BleDeviceInfo {
  final dynamic device;       // Platform-specific device object
  final int rssi;
  final String advertisedName;
  final String deviceId;
  final String platformName;  // Human-readable platform name

  BleDeviceInfo({
    required this.device,
    required this.rssi,
    required this.advertisedName,
    required this.deviceId,
    required this.platformName,
  });

  @override
  String toString() {
    return 'BleDeviceInfo(name: $advertisedName, id: $deviceId, rssi: $rssi, platform: $platformName)';
  }
}

/// Connection state information (platform-independent)
class ConnectionInfo {
  final dynamic device;
  final String state;
  final bool isConnected;

  ConnectionInfo({
    required this.device,
    required this.state,
    required this.isConnected,
  });

  @override
  String toString() {
    return 'ConnectionInfo(device: ${device}, state: $state, isConnected: $isConnected)';
  }
}