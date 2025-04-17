export 'ble_background_service_mobile.dart'
if (dart.library.io) 'ble_background_service_mobile.dart'
if (dart.library.html) 'ble_background_service_pc.dart';

abstract class BleBackgroundService {
  Future<void> initialize();
  Future<bool> startService();
  Future<bool> stopService();
  Future<bool> isRunning(); // Added for status checking
  void startScanning({List<String> services = const [], int timeout = 10});
  void stopScanning();
  void startAdvertising(String deviceId, String serviceUuid);
  void stopAdvertising();
  void connectToDevice(String remoteId, {int timeout = 15, int maxRetries = 3});
  void disconnectDevice(String remoteId);
  void writeCharacteristic(
      String remoteId,
      String serviceUuid,
      String characteristicUuid,
      String data, {
        String format = 'utf8',
        bool withResponse = true,
      });
  void readCharacteristic(
      String remoteId,
      String serviceUuid,
      String characteristicUuid, {
        String format = 'utf8',
      });
  Stream<Map<String, dynamic>> get scanResults;
  Stream<Map<String, dynamic>> get connectionState;
  Stream<Map<String, dynamic>> get bluetoothState;
  Stream<Map<String, dynamic>> get advertisingState;
  // Added streams for operation results
  Stream<Map<String, dynamic>> get writeResults;
  Stream<Map<String, dynamic>> get readResults;
  Stream<Map<String, dynamic>> get connectResults;
  Stream<Map<String, dynamic>> get disconnectResults;
}