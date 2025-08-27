import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../../data/services/ble_service.dart';

// BLE Service provider
final bleServiceProvider = Provider<BLEService>((ref) {
  final service = BLEService();
  service.initialize();
  
  ref.onDispose(() {
    service.dispose();
  });
  
  return service;
});

// BLE State provider
final bleStateProvider = StreamProvider<BluetoothLowEnergyState>((ref) {
  final service = ref.watch(bleServiceProvider);
  return Stream.periodic(Duration(seconds: 1), (_) => service.state);
});

// Discovered devices provider
final discoveredDevicesProvider = StreamProvider<List<Peripheral>>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.discoveredDevices;
});

// Received messages provider
final receivedMessagesProvider = StreamProvider<String>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.receivedMessages;
});

// Name changes provider
final nameChangesProvider = StreamProvider<String?>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.nameChanges;
});

final connectionStateStreamProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.connectionState;
});

final monitoringStateProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.monitoringState;
});

final isMonitoringProvider = Provider<bool>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.isMonitoring;
});

final advertisingStateProvider = StreamProvider<String>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.advertisingState;
});