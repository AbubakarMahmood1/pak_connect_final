import 'dart:async';

import 'package:pak_connect/core/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/entities/enhanced_message.dart';

/// Lightweight mock for [IConnectionService] used in Phase 5 test harnesses.
///
/// The implementation keeps track of the most recent calls while exposing
/// broadcast streams so suites can verify emitted events without needing to
/// spin up the real BLE stack.
class MockConnectionService implements IConnectionService {
  final StreamController<EnhancedMessage> _receivedMessagesController =
      StreamController<EnhancedMessage>.broadcast();
  final StreamController<dynamic> _discoveredDevicesController =
      StreamController<dynamic>.broadcast();
  final StreamController<String> _connectionInfoController =
      StreamController<String>.broadcast();
  final StreamController<bool> _bluetoothStateController =
      StreamController<bool>.broadcast();

  final List<Function(bool success)> _handshakeCallbacks = [];

  final List<Map<String, Object?>> sentMessages = [];
  final List<Map<String, Object?>> sentPeripheralMessages = [];
  final List<Map<String, Object?>> queueSyncMessages = [];
  final List<dynamic> _currentDiscoveredDevices = [];

  bool _isDiscoveryActive = false;
  bool _isAdvertising = false;
  bool _isConnected = false;
  bool _isBluetoothReady = true;
  bool _isHandshakeInProgress = false;
  bool _hasHandshakeCompleted = false;

  String? _currentConnectionInfo;
  String? _connectedDevice;
  String? _otherUserName;
  String? _myUserName;
  String? _currentSessionId;
  String? _theirEphemeralId;
  String? _theirPersistentKey;
  String _myPublicKey = 'mock_public_key';
  String _myEphemeralId = 'mock_ephemeral';

  bool identityExchangeRequested = false;

  Future<void> dispose() async {
    await _receivedMessagesController.close();
    await _discoveredDevicesController.close();
    await _connectionInfoController.close();
    await _bluetoothStateController.close();
  }

  @override
  Future<bool> sendMessage({
    required String recipient,
    required String content,
    String? messageId,
  }) async {
    sentMessages.add({
      'recipient': recipient,
      'content': content,
      'messageId': messageId,
    });
    return true;
  }

  @override
  Future<bool> sendPeripheralMessage({
    required String recipientAddress,
    required String content,
  }) async {
    sentPeripheralMessages.add({
      'recipientAddress': recipientAddress,
      'content': content,
    });
    return true;
  }

  @override
  Future<bool> sendQueueSyncMessage({
    required String recipientId,
    required List<EnhancedMessage> pendingMessages,
  }) async {
    queueSyncMessages.add({
      'recipientId': recipientId,
      'pendingMessages': pendingMessages,
    });
    return true;
  }

  @override
  Stream<EnhancedMessage> get receivedMessagesStream =>
      _receivedMessagesController.stream;

  void emitIncomingMessage(EnhancedMessage message) {
    _receivedMessagesController.add(message);
  }

  @override
  Future<void> startScanning() async {
    _isDiscoveryActive = true;
  }

  @override
  Future<void> stopScanning() async {
    _isDiscoveryActive = false;
  }

  @override
  Stream<dynamic> get discoveredDevicesStream =>
      _discoveredDevicesController.stream;

  void emitDiscoveredDevice(dynamic device) {
    _discoveredDevicesController.add(device);
  }

  @override
  List<dynamic> get currentDiscoveredDevices =>
      List<dynamic>.unmodifiable(_currentDiscoveredDevices);

  void setCurrentDiscoveredDevices(List<dynamic> devices) {
    _currentDiscoveredDevices
      ..clear()
      ..addAll(devices);
  }

  @override
  bool get isDiscoveryActive => _isDiscoveryActive;

  @override
  Future<void> startAsPeripheral() async {
    _isAdvertising = true;
  }

  @override
  bool get isAdvertising => _isAdvertising;

  @override
  Future<void> connectToDevice(String deviceAddress) async {
    _connectedDevice = deviceAddress;
    _isConnected = true;
  }

  @override
  Future<void> disconnect() async {
    _connectedDevice = null;
    _isConnected = false;
  }

  @override
  Stream<String> get connectionInfoStream => _connectionInfoController.stream;

  void emitConnectionInfo(String info) {
    _currentConnectionInfo = info;
    _connectionInfoController.add(info);
  }

  @override
  String? get currentConnectionInfo => _currentConnectionInfo;

  @override
  bool get isConnected => _isConnected;

  @override
  String? get connectedDevice => _connectedDevice;

  @override
  Stream<bool> get bluetoothStateStream => _bluetoothStateController.stream;

  void emitBluetoothState(bool ready) {
    _isBluetoothReady = ready;
    _bluetoothStateController.add(ready);
  }

  @override
  bool get isBluetoothReady => _isBluetoothReady;

  @override
  dynamic get state => 'mock_state';

  @override
  String getMyPublicKey() => _myPublicKey;

  set myPublicKey(String value) => _myPublicKey = value;

  @override
  String getMyEphemeralId() => _myEphemeralId;

  set myEphemeralId(String value) => _myEphemeralId = value;

  @override
  String? get otherUserName => _otherUserName;

  set otherUserName(String? value) => _otherUserName = value;

  @override
  Future<void> setMyUserName(String userName) async {
    _myUserName = userName;
  }

  String? get myUserName => _myUserName;

  @override
  String? get currentSessionId => _currentSessionId;

  set currentSessionId(String? value) => _currentSessionId = value;

  @override
  String? get theirEphemeralId => _theirEphemeralId;

  set theirEphemeralId(String? value) => _theirEphemeralId = value;

  @override
  String? get theirPersistentKey => _theirPersistentKey;

  set theirPersistentKey(String? value) => _theirPersistentKey = value;

  @override
  bool get isHandshakeInProgress => _isHandshakeInProgress;

  @override
  bool get hasHandshakeCompleted => _hasHandshakeCompleted;

  @override
  Future<bool> performHandshake({
    required String deviceAddress,
    required bool isInitiator,
  }) async {
    _isHandshakeInProgress = true;
    await Future<void>.delayed(Duration.zero);
    _isHandshakeInProgress = false;
    _hasHandshakeCompleted = true;
    _connectedDevice = deviceAddress;
    _currentSessionId = 'session-$deviceAddress';
    for (final callback in _handshakeCallbacks) {
      callback(true);
    }
    return true;
  }

  @override
  void onHandshakeComplete(Function(bool success) callback) {
    _handshakeCallbacks.add(callback);
  }

  @override
  Future<void> requestIdentityExchange() async {
    identityExchangeRequested = true;
  }
}
