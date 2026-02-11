import 'dart:async';

import 'package:pak_connect/domain/models/connection_info.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/services/ble_service.dart';

/// Lightweight BLE service implementation for tests.
///
/// The production [BLEService] integrates with platform channels and complex
/// state machines. These integration tests only need deterministic connection
/// metadata plus successful send operations, so this fake exposes a small API
/// to flip connectivity on/off while satisfying the public BLEService surface
/// that [`MeshNetworkingService`] depends on.
class FakeBleService extends BLEService {
  FakeBleService({String nodeIdPrefix = 'fake-node'})
    : _ephemeralId = '$nodeIdPrefix-ephemeral',
      super(messageHandler: BLEMessageHandler(enableCleanupTimer: false)) {
    _emitConnectionInfo();
  }

  final _connectionInfoController =
      StreamController<ConnectionInfo>.broadcast();
  ConnectionInfo _connectionInfo = const ConnectionInfo(
    isConnected: false,
    isReady: false,
    statusMessage: 'Disconnected',
  );

  String? _currentSessionId;
  bool _isPeripheral = false;
  bool _canSend = false;
  bool _isConnected = false;
  String _lastMessageContent = '';
  final List<String> sentMessageIds = [];
  final List<QueueSyncMessage> sentQueueSyncMessages = [];
  final String _ephemeralId;

  Future<bool> Function(QueueSyncMessage, String)? _queueSyncHandler;

  /// Configure a synthetic connection for tests.
  void simulateConnection({required String peerId, bool isPeripheral = false}) {
    _currentSessionId = peerId;
    _isPeripheral = isPeripheral;
    _canSend = true;
    _isConnected = true;
    _connectionInfo = ConnectionInfo(
      isConnected: true,
      isReady: true,
      statusMessage: 'Connected to $peerId',
    );
    _emitConnectionInfo();
  }

  void simulateDisconnection() {
    _currentSessionId = null;
    _canSend = false;
    _isConnected = false;
    _connectionInfo = const ConnectionInfo(
      isConnected: false,
      isReady: false,
      statusMessage: 'Disconnected',
    );
    _emitConnectionInfo();
  }

  void _emitConnectionInfo() {
    unawaited(
      Future.microtask(() {
        if (!_connectionInfoController.isClosed) {
          _connectionInfoController.add(_connectionInfo);
        }
      }),
    );
  }

  String get lastMessageContent => _lastMessageContent;

  @override
  Stream<ConnectionInfo> get connectionInfo => _connectionInfoController.stream;

  @override
  ConnectionInfo get currentConnectionInfo => _connectionInfo;

  @override
  String? get currentSessionId => _currentSessionId;

  @override
  bool get isPeripheralMode => _isPeripheral;

  @override
  bool get canSendMessages => _canSend;

  @override
  bool get isConnected => _isConnected;

  @override
  Future<bool> sendMessage(
    String content, {
    String? messageId,
    String? originalIntendedRecipient,
    bool logOnly = false,
  }) async {
    _lastMessageContent = content;
    if (messageId != null) {
      sentMessageIds.add(messageId);
    }
    return _canSend;
  }

  @override
  Future<bool> sendPeripheralMessage(
    String content, {
    String? messageId,
  }) async {
    return sendMessage(content, messageId: messageId);
  }

  @override
  void registerQueueSyncHandler(
    Future<bool> Function(QueueSyncMessage, String) handler,
  ) {
    _queueSyncHandler = handler;
  }

  @override
  Future<void> sendQueueSyncMessage(QueueSyncMessage queueMessage) async {
    sentQueueSyncMessages.add(queueMessage);
    if (_queueSyncHandler != null && _currentSessionId != null) {
      await _queueSyncHandler!(queueMessage, _currentSessionId!);
    }
  }

  @override
  Future<String> getMyEphemeralId() async => _ephemeralId;

  @override
  Future<String> getMyPublicKey() async => 'fake-public-key';

  @override
  Future<void> dispose() async {
    await super.dispose();
    await _connectionInfoController.close();
  }
}
