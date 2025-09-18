import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../../data/services/ble_service.dart';
import '../../core/models/connection_info.dart';
import '../../data/repositories/chats_repository.dart';

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
  return Stream.fromFuture(service.initializationComplete).asyncExpand((_) => Stream.periodic(Duration(seconds: 1), (_) => service.state));
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

final connectionInfoProvider = StreamProvider<ConnectionInfo>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.connectionInfo;
});

final chatsRepositoryProvider = Provider<ChatsRepository>((ref) {
  return ChatsRepository();
});

// Discovery data with advertisements provider
final discoveryDataProvider = StreamProvider<Map<String, DiscoveredEventArgs>>((ref) {
  final service = ref.watch(bleServiceProvider);
  return service.discoveryData;
});