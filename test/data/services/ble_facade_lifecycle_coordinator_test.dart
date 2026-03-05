import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/ble_connection_manager.dart';
import 'package:pak_connect/data/services/ble_connection_service.dart';
import 'package:pak_connect/data/services/ble_facade_lifecycle_coordinator.dart';
import 'package:pak_connect/domain/interfaces/i_ble_advertising_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_platform_host.dart';
import 'package:pak_connect/domain/models/ble_server_connection.dart';
import 'package:pak_connect/domain/models/connection_phase.dart';
import 'package:pak_connect/domain/models/connection_state.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/models/spy_mode_info.dart';

class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);
  @override
  final UUID uuid;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestCentral implements Central {
  const _TestCentral(this.uuid);
  @override
  final UUID uuid;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestCharacteristic implements GATTCharacteristic {
  const _TestCharacteristic(this.uuid);
  @override
  final UUID uuid;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestWriteRequest implements GATTWriteRequest {
  _TestWriteRequest(this.value);
  @override
  final Uint8List value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPeripheralManager implements PeripheralManager {
  _TestPeripheralManager({this.throwOnStreams = false});
  final bool throwOnStreams;

  final StreamController<CentralConnectionStateChangedEventArgs>
  _connectionController = StreamController<CentralConnectionStateChangedEventArgs>.broadcast();
  final StreamController<CentralMTUChangedEventArgs> _mtuController =
      StreamController<CentralMTUChangedEventArgs>.broadcast();
  final StreamController<GATTCharacteristicNotifyStateChangedEventArgs>
  _notifyController = StreamController<GATTCharacteristicNotifyStateChangedEventArgs>.broadcast();
  final StreamController<GATTCharacteristicWriteRequestedEventArgs>
  _writeController = StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();

  int respondWriteCount = 0;
  int respondWriteErrorCount = 0;

  void emitConnection(CentralConnectionStateChangedEventArgs event) =>
      _connectionController.add(event);
  void emitMtu(CentralMTUChangedEventArgs event) => _mtuController.add(event);
  void emitNotifyState(GATTCharacteristicNotifyStateChangedEventArgs event) =>
      _notifyController.add(event);
  void emitWrite(GATTCharacteristicWriteRequestedEventArgs event) =>
      _writeController.add(event);

  Future<void> dispose() async {
    await _connectionController.close();
    await _mtuController.close();
    await _notifyController.close();
    await _writeController.close();
  }

  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged {
    if (throwOnStreams) throw UnsupportedError('peripheral connection stream');
    return _connectionController.stream;
  }

  @override
  Stream<CentralMTUChangedEventArgs> get mtuChanged {
    if (throwOnStreams) throw UnsupportedError('peripheral mtu stream');
    return _mtuController.stream;
  }

  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged {
    if (throwOnStreams) throw UnsupportedError('peripheral notify stream');
    return _notifyController.stream;
  }

  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested {
    if (throwOnStreams) throw UnsupportedError('peripheral write stream');
    return _writeController.stream;
  }

  @override
  Future<void> respondWriteRequest(GATTWriteRequest request) async {
    respondWriteCount++;
  }

  @override
  Future<void> respondWriteRequestWithError(
    GATTWriteRequest request, {
    required GATTError error,
  }) async {
    respondWriteErrorCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestCentralManager implements CentralManager {
  _TestCentralManager({this.throwOnNotifiedStream = false});
  final bool throwOnNotifiedStream;

  final StreamController<GATTCharacteristicNotifiedEventArgs>
  _notifiedController = StreamController<GATTCharacteristicNotifiedEventArgs>.broadcast();

  void emitNotified(GATTCharacteristicNotifiedEventArgs event) =>
      _notifiedController.add(event);

  Future<void> dispose() async {
    await _notifiedController.close();
  }

  @override
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified {
    if (throwOnNotifiedStream) throw UnsupportedError('central notify stream');
    return _notifiedController.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestPlatformHost implements IBLEPlatformHost {
  _TestPlatformHost({
    required this.centralManager,
    required this.peripheralManager,
  });

  @override
  final CentralManager centralManager;
  @override
  final PeripheralManager peripheralManager;

  @override
  Future<void> ensureEphemeralKeysInitialized() async {}

  @override
  String getCurrentEphemeralId() => 'ephemeral-self';
}

class _TestConnectionService implements BLEConnectionService {
  int setupCalls = 0;
  Central? _connectedCentral;
  GATTCharacteristic? _connectedCharacteristic;

  @override
  void setupConnectionInitialization() {
    setupCalls++;
  }

  @override
  Central? get connectedCentral => _connectedCentral;
  @override
  set connectedCentral(Central? value) => _connectedCentral = value;

  @override
  GATTCharacteristic? get connectedCharacteristic => _connectedCharacteristic;
  @override
  set connectedCharacteristic(GATTCharacteristic? value) =>
      _connectedCharacteristic = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestConnectionManager implements BLEConnectionManager {
  Future<String?> Function()? localHintProvider;
  @override
  Function()? onConnectionComplete;
  @override
  Function(GATTCharacteristic?)? onCharacteristicFound;

  int centralConnectedCalls = 0;
  int centralDisconnectedCalls = 0;
  int updateServerMtuCalls = 0;
  int subscribedCalls = 0;
  final List<String> disconnectClientCalls = <String>[];
  bool hasClientLink = false;
  bool hasPendingClient = false;
  bool responderBlocked = false;
  bool teardownDeferred = false;
  bool collisionResolving = false;
  bool hasServerConnectionValue = true;
  int _serverConnectionCount = 1;
  @override
  List<BLEServerConnection> serverConnections = <BLEServerConnection>[];
  ChatConnectionState _connectionState = ChatConnectionState.disconnected;

  set serverConnectionCountValue(int value) => _serverConnectionCount = value;
  set connectionStateValue(ChatConnectionState value) => _connectionState = value;

  @override
  void setLocalHintProvider(Future<String?> Function()? provider) {
    localHintProvider = provider;
  }

  @override
  void handleCentralConnected(Central central) {
    centralConnectedCalls++;
  }

  @override
  void handleCentralDisconnected(Central central) {
    centralDisconnectedCalls++;
  }

  @override
  void updateServerMtu(String address, int mtu) {
    updateServerMtuCalls++;
  }

  @override
  void handleCharacteristicSubscribed(
    Central central,
    GATTCharacteristic characteristic,
  ) {
    subscribedCalls++;
  }

  @override
  bool hasClientLinkForPeer(String peerAddress) => hasClientLink;

  @override
  bool hasPendingClientForPeer(String peerAddress) => hasPendingClient;

  @override
  bool isResponderHandshakeBlocked(String address) => responderBlocked;

  @override
  bool isServerTeardownDeferred(String address) => teardownDeferred;

  @override
  bool isCollisionResolving(String address) => collisionResolving;

  @override
  bool hasServerConnection(String address) => hasServerConnectionValue;

  @override
  int get serverConnectionCount => _serverConnectionCount;

  @override
  ChatConnectionState get connectionState => _connectionState;

  @override
  Future<void> disconnectClient(String deviceId) async {
    disconnectClientCalls.add(deviceId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestDiscoveryService implements IBLEDiscoveryService {
  int initializeCalls = 0;
  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestAdvertisingService implements IBLEAdvertisingService {
  bool _peripheralHandshakeStarted = false;
  int updateMtuCalls = 0;
  int resetCalls = 0;
  int? lastMtu;
  GATTCharacteristic? _messageCharacteristic;

  set messageCharacteristicValue(GATTCharacteristic? value) =>
      _messageCharacteristic = value;

  @override
  bool get peripheralHandshakeStarted => _peripheralHandshakeStarted;
  @override
  set peripheralHandshakeStarted(bool value) =>
      _peripheralHandshakeStarted = value;

  @override
  GATTCharacteristic? get messageCharacteristic => _messageCharacteristic;

  @override
  void updatePeripheralMtu(int mtu) {
    updateMtuCalls++;
    lastMtu = mtu;
  }

  @override
  void resetPeripheralSession() {
    resetCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestMessagingService implements IBLEMessagingService {
  int processCalls = 0;
  Uint8List? lastProcessedData;
  String? lastSenderDeviceId;
  String? lastSenderNodeId;

  @override
  Future<void> processIncomingPeripheralData(
    Uint8List data, {
    required String senderDeviceId,
    String? senderNodeId,
  }) async {
    processCalls++;
    lastProcessedData = data;
    lastSenderDeviceId = senderDeviceId;
    lastSenderNodeId = senderNodeId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHandshakeService implements IBLEHandshakeService {
  bool inProgress = false;
  String? localHint = 'hint-local';
  int buildHintCalls = 0;
  int disposeCalls = 0;
  final List<bool?> performCalls = <bool?>[];
  bool handleIncomingResult = false;
  bool throwOnHandleIncoming = false;
  int handleIncomingCalls = 0;

  @override
  bool get isHandshakeInProgress => inProgress;

  @override
  Future<String?> buildLocalCollisionHint() async {
    buildHintCalls++;
    return localHint;
  }

  @override
  Future<void> performHandshake({bool? startAsInitiatorOverride}) async {
    performCalls.add(startAsInitiatorOverride);
  }

  @override
  void disposeHandshakeCoordinator() {
    disposeCalls++;
  }

  @override
  Future<bool> handleIncomingHandshakeMessage(
    Uint8List data, {
    bool isFromPeripheral = false,
  }) async {
    handleIncomingCalls++;
    if (throwOnHandleIncoming) throw StateError('boom');
    return handleIncomingResult;
  }

  @override
  Stream<SpyModeInfo> get spyModeDetectedStream => const Stream.empty();
  @override
  Stream<String> get identityRevealedStream => const Stream.empty();
  @override
  Stream<ConnectionPhase> get handshakePhaseStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _TestCentralManager centralManager;
  late _TestPeripheralManager peripheralManager;
  late _TestPlatformHost platformHost;
  late _TestConnectionManager connectionManager;
  late _TestConnectionService connectionService;
  late _TestDiscoveryService discoveryService;
  late _TestAdvertisingService advertisingService;
  late _TestMessagingService messagingService;
  late _TestHandshakeService handshakeService;
  late BleLifecycleCoordinator coordinator;
  late _TestCentral central;
  late _TestPeripheral peripheral;
  late _TestCharacteristic characteristic;

  setUp(() {
    centralManager = _TestCentralManager();
    peripheralManager = _TestPeripheralManager();
    platformHost = _TestPlatformHost(
      centralManager: centralManager,
      peripheralManager: peripheralManager,
    );
    connectionManager = _TestConnectionManager();
    connectionService = _TestConnectionService();
    discoveryService = _TestDiscoveryService();
    advertisingService = _TestAdvertisingService();
    messagingService = _TestMessagingService();
    handshakeService = _TestHandshakeService();
    coordinator = BleLifecycleCoordinator(
      logger: Logger('test.lifecycle'),
      platformHost: platformHost,
      connectionManager: connectionManager,
      getConnectionService: () => connectionService,
      getDiscoveryService: () => discoveryService,
      getAdvertisingService: () => advertisingService,
      getMessagingService: () => messagingService,
      getHandshakeService: () => handshakeService,
    );
    central = _TestCentral(UUID.fromString('00000000-0000-0000-0000-000000000001'));
    peripheral = _TestPeripheral(
      UUID.fromString('00000000-0000-0000-0000-000000000002'),
    );
    characteristic = _TestCharacteristic(UUID.fromAddress(0x2A19));
  });

  tearDown(() async {
    await coordinator.dispose();
    await centralManager.dispose();
    await peripheralManager.dispose();
  });

  test('ensureConnectionServicePrepared is idempotent and wires callbacks', () async {
    coordinator.ensureConnectionServicePrepared();
    coordinator.ensureConnectionServicePrepared();

    expect(connectionService.setupCalls, 1);
    expect(connectionManager.localHintProvider, isNotNull);
    expect(await connectionManager.localHintProvider!.call(), 'hint-local');
    expect(handshakeService.buildHintCalls, 1);

    expect(connectionManager.onConnectionComplete, isNotNull);
    await connectionManager.onConnectionComplete!.call();
    expect(handshakeService.performCalls, [true]);
  });

  test('ensureDiscoveryInitialized runs once', () async {
    await coordinator.ensureDiscoveryInitialized();
    await coordinator.ensureDiscoveryInitialized();
    expect(discoveryService.initializeCalls, 1);
  });

  test('peripheral connection, mtu, notify, and write events delegate correctly', () async {
    coordinator.ensureConnectionServicePrepared();
    connectionManager.serverConnectionCountValue = 1;
    connectionManager.hasServerConnectionValue = true;
    advertisingService.messageCharacteristicValue = characteristic;
    handshakeService.handleIncomingResult = false;

    peripheralManager.emitConnection(
      CentralConnectionStateChangedEventArgs(
        central,
        ConnectionState.connected,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(connectionManager.centralConnectedCalls, 1);
    expect(connectionService.connectedCentral, central);

    peripheralManager.emitMtu(CentralMTUChangedEventArgs(central, 185));
    await Future<void>.delayed(Duration.zero);
    expect(advertisingService.updateMtuCalls, 1);
    expect(connectionManager.updateServerMtuCalls, 1);
    expect(advertisingService.lastMtu, 185);

    peripheralManager.emitNotifyState(
      GATTCharacteristicNotifyStateChangedEventArgs(
        central,
        characteristic,
        true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(connectionManager.subscribedCalls, 1);
    expect(connectionService.connectedCharacteristic, characteristic);

    final writeRequest = _TestWriteRequest(Uint8List.fromList([1, 2, 3]));
    peripheralManager.emitWrite(
      GATTCharacteristicWriteRequestedEventArgs(
        central,
        characteristic,
        writeRequest,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(handshakeService.handleIncomingCalls, greaterThan(0));
    expect(messagingService.processCalls, 1);
    expect(peripheralManager.respondWriteCount, 1);
  });

  test('write handler returns protocol error when processing throws', () async {
    coordinator.ensureConnectionServicePrepared();
    handshakeService.throwOnHandleIncoming = true;

    final writeRequest = _TestWriteRequest(Uint8List.fromList([7]));
    peripheralManager.emitWrite(
      GATTCharacteristicWriteRequestedEventArgs(
        central,
        characteristic,
        writeRequest,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(peripheralManager.respondWriteErrorCount, 1);
  });

  test('disconnect events reset session and promote replacement server link', () async {
    coordinator.ensureConnectionServicePrepared();
    connectionService.connectedCentral = central;
    connectionService.connectedCharacteristic = characteristic;

    connectionManager.serverConnectionCountValue = 0;
    peripheralManager.emitConnection(
      CentralConnectionStateChangedEventArgs(
        central,
        ConnectionState.disconnected,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(connectionManager.centralDisconnectedCalls, 1);
    expect(handshakeService.disposeCalls, 1);
    expect(advertisingService.resetCalls, 1);
    expect(connectionService.connectedCentral, isNull);
    expect(connectionService.connectedCharacteristic, isNull);

    final replacement = _TestCentral(
      UUID.fromString('00000000-0000-0000-0000-0000000000AA'),
    );
    connectionService.connectedCentral = replacement;
    connectionManager.serverConnectionCountValue = 1;
    connectionManager.serverConnections = [
      BLEServerConnection(
        address: replacement.uuid.toString(),
        central: replacement,
        connectedAt: DateTime.now(),
        subscribedCharacteristic: characteristic,
      ),
    ];
    peripheralManager.emitConnection(
      CentralConnectionStateChangedEventArgs(
        replacement,
        ConnectionState.disconnected,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(connectionService.connectedCentral, replacement);
    expect(connectionService.connectedCharacteristic, characteristic);
  });

  test('central notifications handle service-changed, handshake, and relay payloads', () async {
    coordinator.ensureConnectionServicePrepared();

    final serviceChanged = _TestCharacteristic(UUID.fromAddress(0x2A05));
    centralManager.emitNotified(
      GATTCharacteristicNotifiedEventArgs(
        peripheral,
        serviceChanged,
        Uint8List.fromList([0]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(connectionManager.disconnectClientCalls, [peripheral.uuid.toString()]);

    final normal = _TestCharacteristic(UUID.fromAddress(0x2A19));
    handshakeService.handleIncomingResult = true;
    centralManager.emitNotified(
      GATTCharacteristicNotifiedEventArgs(
        peripheral,
        normal,
        Uint8List.fromList([1]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(messagingService.processCalls, 0);

    handshakeService.handleIncomingResult = false;
    centralManager.emitNotified(
      GATTCharacteristicNotifiedEventArgs(
        peripheral,
        normal,
        Uint8List.fromList([2]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(messagingService.processCalls, 1);
    expect(messagingService.lastSenderDeviceId, peripheral.uuid.toString());
  });

  test('unsupported platform stream bindings are tolerated', () async {
    final unsupportedCoordinator = BleLifecycleCoordinator(
      logger: Logger('test.lifecycle.unsupported'),
      platformHost: _TestPlatformHost(
        centralManager: _TestCentralManager(throwOnNotifiedStream: true),
        peripheralManager: _TestPeripheralManager(throwOnStreams: true),
      ),
      connectionManager: connectionManager,
      getConnectionService: () => connectionService,
      getDiscoveryService: () => discoveryService,
      getAdvertisingService: () => advertisingService,
      getMessagingService: () => messagingService,
      getHandshakeService: () => handshakeService,
    );
    addTearDown(unsupportedCoordinator.dispose);

    expect(unsupportedCoordinator.ensureConnectionServicePrepared, returnsNormally);
  });
}
