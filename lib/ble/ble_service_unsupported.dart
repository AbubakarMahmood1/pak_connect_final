// ble_service_unsupported.dart
import 'dart:async';
import 'ble_service.dart';

/// Fallback implementation for platforms that don't support BLE
class BleServiceUnsupported implements BleService {
  // Stream controllers
  final _scanResultsController = StreamController<List<dynamic>>.broadcast();
  final _connectionStateController = StreamController<dynamic>.broadcast();
  final _advertisingStateController = StreamController<bool>.broadcast();
  final _bluetoothStateController = StreamController<dynamic>.broadcast();

  // Stream getters
  @override
  Stream<List<dynamic>> get scanResults => _scanResultsController.stream;

  @override
  Stream<dynamic> get connectionState => _connectionStateController.stream;

  @override
  Stream<bool> get advertisingState => _advertisingStateController.stream;

  @override
  Stream<dynamic> get bluetoothState => _bluetoothStateController.stream;

  // State getters
  @override
  bool get isScanning => false;

  @override
  bool get isAdvertising => false;

  @override
  List<dynamic> get discoveredDevices => [];

  @override
  Future<void> initialize() async {
    print('BLE not supported on this platform');
  }

  @override
  Future<bool> isBluetoothAvailable() async {
    return false;
  }

  @override
  Future<bool> startScanning({
    List<String> withServices = const [],
    Duration timeout = const Duration(seconds: 10),
  }) async {
    print('BLE scanning not supported on this platform');
    return false;
  }

  @override
  Future<void> stopScanning() async {
    print('BLE scanning not supported on this platform');
  }

  @override
  Future<bool> startAdvertising(String deviceId, String serviceUuid) async {
    print('BLE advertising not supported on this platform');
    return false;
  }

  @override
  Future<bool> stopAdvertising() async {
    print('BLE advertising not supported on this platform');
    return false;
  }

  @override
  Future<bool> connectToDevice(dynamic device, {
    Duration timeout = const Duration(seconds: 15),
    int maxRetries = 3,
  }) async {
    print('BLE connections not supported on this platform');
    return false;
  }

  @override
  Future<bool> disconnectDevice(dynamic device) async {
    print('BLE connections not supported on this platform');
    return false;
  }

  @override
  Future<List<dynamic>> discoverServices(dynamic device) async {
    print('BLE services not supported on this platform');
    return [];
  }

  @override
  Future<bool> writeCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      List<int> data,
      {bool withResponse = true}
      ) async {
    print('BLE characteristic operations not supported on this platform');
    return false;
  }

  @override
  Future<List<int>?> readCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      ) async {
    print('BLE characteristic operations not supported on this platform');
    return null;
  }

  @override
  Future<Stream<List<int>>?> subscribeToCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      ) async {
    print('BLE notifications not supported on this platform');
    return null;
  }

  @override
  Future<bool> unsubscribeFromCharacteristic(
      dynamic device,
      String serviceUuid,
      String characteristicUuid,
      ) async {
    print('BLE notifications not supported on this platform');
    return false;
  }

  @override
  Map<String, dynamic> getSignalStrength(int rssi) {
    return {'icon': 'signalCellularOutline', 'color': 'grey'};
  }

  @override
  void dispose() {
    _scanResultsController.close();
    _connectionStateController.close();
    _advertisingStateController.close();
    _bluetoothStateController.close();
  }
}