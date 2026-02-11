import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'package:pak_connect/domain/services/bluetooth_state_monitor.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';

/// Lightweight mock for [IConnectionService] used by the Phase 5 harness.
///
/// The mock keeps simple in-memory state so tests can verify high-level
/// interactions without spinning up the full BLE stack. All streams are
/// broadcast to allow multiple listeners, and helper methods exist to emit
/// synthetic events (connection info, discovery updates, etc.).
class MockConnectionService implements IConnectionService {
  final StreamController<ConnectionInfo> _connectionInfoController =
      StreamController<ConnectionInfo>.broadcast();
  final StreamController<List<Peripheral>> _discoveredDevicesController =
      StreamController<List<Peripheral>>.broadcast();
  final StreamController<Map<String, DiscoveredEventArgs>>
  _discoveryDataController =
      StreamController<Map<String, DiscoveredEventArgs>>.broadcast();
  final StreamController<String> _receivedMessagesController =
      StreamController<String>.broadcast();
  final StreamController<SpyModeInfo> _spyModeController =
      StreamController<SpyModeInfo>.broadcast();
  final StreamController<String> _identityController =
      StreamController<String>.broadcast();
  final StreamController<CentralConnectionStateChangedEventArgs>
  _peripheralConnectionController =
      StreamController<CentralConnectionStateChangedEventArgs>.broadcast();
  final StreamController<BluetoothStateInfo> _bluetoothStateController =
      StreamController<BluetoothStateInfo>.broadcast();
  final StreamController<BluetoothStatusMessage> _bluetoothMessageController =
      StreamController<BluetoothStatusMessage>.broadcast();
  final StreamController<String> _hintMatchesController =
      StreamController<String>.broadcast();
  final StreamController<BinaryPayload> _binaryPayloadController =
      StreamController<BinaryPayload>.broadcast();
  final List<BLEServerConnection> _serverConnections = [];
  final bool _isActivelyReconnecting = false;
  String _myUserName = 'Mock User';
  Peripheral? _connectedDevice;
  void Function(bool success)? _contactRequestCompletedListener;
  void Function(String publicKey, String displayName)?
  _contactRequestReceivedListener;
  void Function(String publicKey, String displayName)?
  _asymmetricContactListener;

  final List<Map<String, Object?>> sentMessages = [];
  final List<Map<String, Object?>> sentPeripheralMessages = [];
  final List<QueueSyncMessage> queueSyncMessages = [];
  Future<bool> Function(QueueSyncMessage message, String fromNodeId)?
  _queueSyncHandler;

  bool _isDiscoveryActive = false;
  bool _isAdvertising = false;
  bool _isPeripheralMTUReady = false;
  int? _peripheralNegotiatedMTU;
  bool _isBluetoothReady = true;
  BluetoothLowEnergyState _bluetoothState = BluetoothLowEnergyState.poweredOn;
  bool _isConnected = false;
  bool _hasPeripheralConnection = false;
  bool _isPeripheralMode = false;
  bool _canAcceptMoreConnections = true;
  int _activeConnectionCount = 0;
  int _maxCentralConnections = 1;
  final List<String> _activeConnectionDeviceIds = [];
  String? _currentSessionId;
  String _myPublicKey = 'mock_public_key';
  String _myEphemeralId = 'mock_ephemeral';
  String? _theirPersistentKey;
  Central? _connectedCentral;
  BLEStateManager? _stateManager;
  bool identityExchangeRequested = false;

  ConnectionInfo _currentConnectionInfo = ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'Idle',
  );

  Future<void> dispose() async {
    await _connectionInfoController.close();
    await _discoveredDevicesController.close();
    await _discoveryDataController.close();
    await _receivedMessagesController.close();
    await _spyModeController.close();
    await _identityController.close();
    await _peripheralConnectionController.close();
    await _bluetoothStateController.close();
    await _bluetoothMessageController.close();
    await _hintMatchesController.close();
    await _binaryPayloadController.close();
  }

  // ===== Messaging =====

  @override
  Future<bool> sendMessage(
    String message, {
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    sentMessages.add({
      'content': message,
      'messageId': messageId,
      'recipient': originalIntendedRecipient,
    });
    return true;
  }

  @override
  Future<bool> sendPeripheralMessage(
    String message, {
    String? messageId,
  }) async {
    sentPeripheralMessages.add({'content': message, 'messageId': messageId});
    return true;
  }

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage queueMessage) async {
    queueSyncMessages.add(queueMessage);
    if (_queueSyncHandler != null) {
      await _queueSyncHandler!(queueMessage, 'mock_node');
    }
  }

  @override
  Future<String> sendBinaryMedia({
    required Uint8List data,
    required String recipientId,
    int originalType = 0x90,
    Map<String, dynamic>? metadata,
    bool persistOnly = false,
  }) async => 'mock-transfer-${DateTime.now().millisecondsSinceEpoch}';

  @override
  Future<bool> retryBinaryMedia({
    required String transferId,
    String? recipientId,
    int? originalType,
  }) async => true;

  @override
  Stream<String> get receivedMessages => _receivedMessagesController.stream;

  @override
  Stream<BinaryPayload> get receivedBinaryStream =>
      _binaryPayloadController.stream;

  void emitIncomingMessage(String payload) {
    _receivedMessagesController.add(payload);
  }

  void emitIncomingBinary(BinaryPayload payload) {
    _binaryPayloadController.add(payload);
  }

  // ===== Discovery =====

  @override
  Future<void> startScanning({
    ScanningSource source = ScanningSource.system,
  }) async {
    _isDiscoveryActive = true;
  }

  @override
  Future<void> stopScanning() async {
    _isDiscoveryActive = false;
  }

  @override
  Stream<List<Peripheral>> get discoveredDevices =>
      _discoveredDevicesController.stream;

  void emitDiscoveredDevices(List<Peripheral> devices) {
    _discoveredDevicesController.add(devices);
  }

  @override
  Future<Peripheral?> scanForSpecificDevice({Duration? timeout}) async {
    final completer = Completer<Peripheral?>();
    Peripheral? match;
    late StreamSubscription<List<Peripheral>> sub;
    sub = discoveredDevices.listen((devices) {
      match = devices.isNotEmpty ? devices.first : null;
      completer.complete(match);
      sub.cancel();
    });

    if (timeout != null) {
      Future.delayed(timeout).then((_) {
        if (!completer.isCompleted) {
          completer.complete(match);
          sub.cancel();
        }
      });
    }

    return completer.future;
  }

  @override
  Stream<Map<String, DiscoveredEventArgs>> get discoveryData =>
      _discoveryDataController.stream;

  void emitDiscoveryData(Map<String, DiscoveredEventArgs> data) {
    _discoveryDataController.add(data);
  }

  @override
  Stream<String> get hintMatches => _hintMatchesController.stream;

  void emitHintMatch(String value) => _hintMatchesController.add(value);

  bool get isDiscoveryActive => _isDiscoveryActive;

  // ===== Advertising / role management =====

  @override
  Future<void> startAsPeripheral() async {
    _isAdvertising = true;
    _isPeripheralMode = true;
  }

  @override
  Future<void> startAsCentral() async {
    _isPeripheralMode = false;
  }

  @override
  Future<void> refreshAdvertising({bool? showOnlineStatus}) async {
    // no-op for mock
  }

  @override
  bool get isAdvertising => _isAdvertising;

  @override
  bool get isPeripheralMTUReady => _isPeripheralMTUReady;

  set isPeripheralMTUReady(bool value) => _isPeripheralMTUReady = value;

  @override
  int? get peripheralNegotiatedMTU => _peripheralNegotiatedMTU;

  set peripheralNegotiatedMTU(int? value) => _peripheralNegotiatedMTU = value;

  // ===== Connection management =====

  @override
  Future<void> connectToDevice(Peripheral device) async {
    _isConnected = true;
    final deviceId = device.uuid.toString();
    _connectedDevice = device;
    _activeConnectionCount = 1;
    _currentSessionId = deviceId;
    _currentConnectionInfo = _currentConnectionInfo.copyWith(
      isConnected: true,
      statusMessage: 'Connected to $deviceId',
      otherUserName: _connectedCentral?.uuid.toString(),
    );
    _connectionInfoController.add(_currentConnectionInfo);
  }

  @override
  Future<void> disconnect() async {
    _isConnected = false;
    _connectedDevice = null;
    _activeConnectionCount = 0;
    _activeConnectionDeviceIds.clear();
    _currentConnectionInfo = _currentConnectionInfo.copyWith(
      isConnected: false,
      statusMessage: 'Disconnected',
    );
    _connectionInfoController.add(_currentConnectionInfo);
  }

  @override
  void startConnectionMonitoring() {
    // no-op for mock
  }

  @override
  void stopConnectionMonitoring() {
    // no-op for mock
  }

  @override
  Stream<ConnectionInfo> get connectionInfo => _connectionInfoController.stream;

  @override
  ConnectionInfo get currentConnectionInfo => _currentConnectionInfo;

  void emitConnectionInfo(ConnectionInfo info) {
    _currentConnectionInfo = info;
    _connectionInfoController.add(info);
  }

  @override
  bool get isConnected => _isConnected;

  @override
  bool get isActivelyReconnecting => _isActivelyReconnecting;

  @override
  Central? get connectedCentral => _connectedCentral;

  set connectedCentral(Central? value) => _connectedCentral = value;

  @override
  Peripheral? get connectedDevice => _connectedDevice;

  // ===== Bluetooth state =====

  @override
  Stream<BluetoothStateInfo> get bluetoothStateStream =>
      _bluetoothStateController.stream;

  @override
  Stream<BluetoothStatusMessage> get bluetoothMessageStream =>
      _bluetoothMessageController.stream;

  @override
  bool get isBluetoothReady => _isBluetoothReady;

  void emitBluetoothReady(bool ready) {
    _isBluetoothReady = ready;
    _bluetoothStateController.add(
      BluetoothStateInfo(
        state: _bluetoothState,
        isReady: ready,
        timestamp: DateTime.now(),
      ),
    );
  }

  @override
  BluetoothLowEnergyState get state => _bluetoothState;

  set bluetoothState(BluetoothLowEnergyState value) {
    _bluetoothState = value;
    _bluetoothStateController.add(
      BluetoothStateInfo(
        state: value,
        isReady: _isBluetoothReady,
        timestamp: DateTime.now(),
      ),
    );
  }

  // ===== Identity / handshake =====

  @override
  Future<void> requestIdentityExchange() async {
    identityExchangeRequested = true;
  }

  @override
  Stream<SpyModeInfo> get spyModeDetected => _spyModeController.stream;

  void emitSpyMode(SpyModeInfo info) => _spyModeController.add(info);

  @override
  Stream<String> get identityRevealed => _identityController.stream;

  void emitIdentity(String identity) => _identityController.add(identity);

  // ===== IMeshBleService members =====

  @override
  String? get currentSessionId => _currentSessionId;

  set currentSessionId(String? value) => _currentSessionId = value;

  @override
  Future<String> getMyPublicKey() async => _myPublicKey;

  set myPublicKey(String value) => _myPublicKey = value;

  @override
  Future<String> getMyEphemeralId() async => _myEphemeralId;

  set myEphemeralId(String value) => _myEphemeralId = value;

  @override
  String? get theirPersistentPublicKey => _theirPersistentKey;

  set theirPersistentPublicKey(String? value) => _theirPersistentKey = value;

  @override
  bool get canSendMessages => _isConnected;

  @override
  bool get hasPeripheralConnection => _hasPeripheralConnection;

  set hasPeripheralConnection(bool value) => _hasPeripheralConnection = value;

  @override
  bool get isPeripheralMode => _isPeripheralMode;

  set isPeripheralMode(bool value) => _isPeripheralMode = value;

  @override
  bool get canAcceptMoreConnections => _canAcceptMoreConnections;

  set canAcceptMoreConnections(bool value) => _canAcceptMoreConnections = value;

  @override
  int get activeConnectionCount => _activeConnectionCount;

  set activeConnectionCount(int value) => _activeConnectionCount = value;

  @override
  int get maxCentralConnections => _maxCentralConnections;

  set maxCentralConnections(int value) => _maxCentralConnections = value;

  @override
  List<String> get activeConnectionDeviceIds =>
      List.unmodifiable(_activeConnectionDeviceIds);

  void setActiveConnectionDeviceIds(List<String> ids) {
    _activeConnectionDeviceIds
      ..clear()
      ..addAll(ids);
  }

  @override
  List<BLEServerConnection> get serverConnections =>
      List.unmodifiable(_serverConnections);

  @override
  int get clientConnectionCount => _activeConnectionCount;

  @override
  Stream<CentralConnectionStateChangedEventArgs>
  get peripheralConnectionChanges => _peripheralConnectionController.stream;

  void emitPeripheralConnectionChange(
    CentralConnectionStateChangedEventArgs args,
  ) => _peripheralConnectionController.add(args);

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage message, String fromNodeId) handler,
  ) {
    _queueSyncHandler = handler;
  }

  void emitContactRequest(String publicKey, String displayName) {
    _contactRequestReceivedListener?.call(publicKey, displayName);
  }

  void emitAsymmetricContact(String publicKey, String displayName) {
    _asymmetricContactListener?.call(publicKey, displayName);
  }

  @override
  Future<void> triggerIdentityReExchange() async {
    identityExchangeRequested = true;
  }

  @override
  Future<void> setMyUserName(String name) async {
    _myUserName = name;
  }

  // Expose the shared BLE state manager when tests need it.
  set stateManager(BLEStateManager manager) => _stateManager = manager;
  BLEStateManager get stateManager => _stateManager ?? BLEStateManager();

  @override
  Future<ProtocolMessage?> revealIdentityToFriend() async {
    return null;
  }

  @override
  Future<void> acceptContactRequest() async {
    _contactRequestCompletedListener?.call(true);
  }

  @override
  void rejectContactRequest() {
    _contactRequestCompletedListener?.call(false);
  }

  @override
  void setContactRequestCompletedListener(
    void Function(bool success) listener,
  ) {
    _contactRequestCompletedListener = listener;
  }

  @override
  void setContactRequestReceivedListener(
    void Function(String publicKey, String displayName) listener,
  ) {
    _contactRequestReceivedListener = listener;
  }

  @override
  void setAsymmetricContactListener(
    void Function(String publicKey, String displayName) listener,
  ) {
    _asymmetricContactListener = listener;
  }

  @override
  void setPairingInProgress(bool isInProgress) {
    // No-op in mock.
  }

  @override
  String? get otherUserName => _myUserName;

  @override
  String? get theirEphemeralId => _currentSessionId;

  @override
  String? get theirPersistentKey => _theirPersistentKey;

  @override
  String? get myPersistentId => _myPublicKey;
}
