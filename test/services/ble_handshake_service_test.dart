import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/spy_mode_info.dart';
import 'package:pak_connect/core/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/data/repositories/intro_hint_repository.dart';
import 'package:pak_connect/data/services/ble_handshake_service.dart';

import 'ble_handshake_service_test.mocks.dart';

class _TestBufferedMessage {
  final Uint8List data;
  final bool isFromPeripheral;
  final DateTime timestamp;

  _TestBufferedMessage({required this.data, this.isFromPeripheral = false})
    : timestamp = DateTime.now();
}

class _StubStateManager implements IBLEStateManagerFacade {
  bool connected = true;
  bool peripheralMode = false;
  String? userName = 'Alice';
  String? ephemeralId;
  Future<void> Function()? loadUserNameHandler;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> loadUserName() async {
    if (loadUserNameHandler != null) {
      return loadUserNameHandler!();
    }
  }

  @override
  Future<String> getMyPersistentId() async => 'pub-key-12345678';

  @override
  void dispose() {}

  @override
  Future<void> setMyUserName(String name) async => userName = name;

  @override
  Future<void> setMyUserNameWithCallbacks(String name) async => userName = name;

  @override
  void setPeripheralMode(bool isPeripheral) {
    peripheralMode = isPeripheral;
  }

  @override
  bool get isConnected => connected;

  @override
  bool get isPeripheralMode => peripheralMode;

  @override
  String? get myUserName => userName;

  @override
  String? get myEphemeralId => ephemeralId;

  @override
  String getIdType() => 'persistent';

  @override
  String? get otherUserName => null;

  @override
  String? get theirEphemeralId => null;

  @override
  String? get theirPersistentKey => null;

  @override
  String? get myPersistentId => null;

  @override
  String? get currentSessionId => null;

  @override
  bool get isPaired => false;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@GenerateNiceMocks([MockSpec<IntroHintRepository>()])
void main() {
  late _StubStateManager mockStateManager;
  late MockIntroHintRepository mockIntroHintRepository;
  late StreamController<SpyModeInfo> spyModeController;
  late StreamController<String> identityController;
  late List<ProtocolMessage> sentMessages;
  late BLEHandshakeService service;
  late List<LogRecord> logRecords;
  late Set<Pattern> allowedSevere;

  void _stubDefaults() {
    mockStateManager
      ..connected = true
      ..peripheralMode = false
      ..userName = 'Alice'
      ..ephemeralId = null
      ..loadUserNameHandler = null;
  }

  setUp(() {
    logRecords = [];
    allowedSevere = {};
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logRecords.add);

    mockStateManager = _StubStateManager();
    mockIntroHintRepository = MockIntroHintRepository();
    spyModeController = StreamController<SpyModeInfo>.broadcast();
    identityController = StreamController<String>.broadcast();
    sentMessages = [];
    _stubDefaults();

    service = BLEHandshakeService(
      stateManager: mockStateManager,
      onIdentityExchangeSent: (_, __) {},
      updateConnectionInfo:
          ({
            bool? isConnected,
            bool? isReady,
            String? otherUserName,
            String? statusMessage,
          }) {},
      setHandshakeInProgress: (_) {},
      handleSpyModeDetected: spyModeController.add,
      handleIdentityRevealed: identityController.add,
      sendProtocolMessage: (message) async => sentMessages.add(message),
      processPendingMessages: () async {},
      startGossipSync: () async {},
      onHandshakeCompleteCallback: (_, __, ___) async {},
      introHintRepo: mockIntroHintRepository,
      messageBuffer: [],
    );
  });

  void allowSevere(Pattern pattern) => allowedSevere.add(pattern);

  tearDown(() async {
    await spyModeController.close();
    await identityController.close();

    final severe = logRecords.where((l) => l.level >= Level.SEVERE);
    final unexpected = severe.where(
      (l) => !allowedSevere.any(
        (p) => p is String
            ? l.message.contains(p)
            : (p as RegExp).hasMatch(l.message),
      ),
    );
    expect(
      unexpected,
      isEmpty,
      reason: 'Unexpected SEVERE errors:\n${unexpected.join("\n")}',
    );
    for (final pattern in allowedSevere) {
      final found = severe.any(
        (l) => pattern is String
            ? l.message.contains(pattern)
            : (pattern as RegExp).hasMatch(l.message),
      );
      expect(
        found,
        isTrue,
        reason: 'Missing expected SEVERE matching "$pattern"',
      );
    }
  });

  test('requestIdentityExchange does nothing when not connected', () async {
    mockStateManager.connected = false;

    await service.requestIdentityExchange();

    expect(sentMessages, isEmpty);
  });

  test('requestIdentityExchange sends identity when connected', () async {
    mockStateManager.connected = true;

    await service.requestIdentityExchange();

    expect(sentMessages, hasLength(1));
    expect(sentMessages.first.type, ProtocolMessageType.identity);
  });

  test('triggerIdentityReExchange swallows load errors', () async {
    mockStateManager.loadUserNameHandler = () async => throw Exception('fail');

    await service.triggerIdentityReExchange();

    expect(sentMessages, isEmpty);
  });

  test(
    'triggerIdentityReExchange sends identity when peripheral mode active',
    () async {
      mockStateManager.peripheralMode = true;

      await service.triggerIdentityReExchange();

      expect(sentMessages, hasLength(1));
      expect(sentMessages.first.type, ProtocolMessageType.identity);
    },
  );

  test('isHandshakeMessage detects handshake types', () {
    expect(service.isHandshakeMessage('connectionReady'), isTrue);
    expect(service.isHandshakeMessage('meshRelay'), isFalse);
  });

  test('getBufferedMessages returns a copy', () {
    final bufferEntry = _TestBufferedMessage(
      data: Uint8List.fromList([1, 2, 3]),
    );
    final buffer = [bufferEntry];

    service = BLEHandshakeService(
      stateManager: mockStateManager,
      onIdentityExchangeSent: (_, __) {},
      updateConnectionInfo:
          ({
            bool? isConnected,
            bool? isReady,
            String? otherUserName,
            String? statusMessage,
          }) {},
      setHandshakeInProgress: (_) {},
      handleSpyModeDetected: spyModeController.add,
      handleIdentityRevealed: identityController.add,
      sendProtocolMessage: (message) async => sentMessages.add(message),
      processPendingMessages: () async {},
      startGossipSync: () async {},
      onHandshakeCompleteCallback: (_, __, ___) async {},
      introHintRepo: mockIntroHintRepository,
      messageBuffer: buffer,
    );

    final result = service.getBufferedMessages();
    expect(result, isNot(same(buffer)));
    expect(result.length, 1);
  });

  test('spyModeDetectedStream relays controller events', () async {
    final future = service.spyModeDetectedStream.first;
    service.emitSpyModeDetected(
      SpyModeInfo(contactName: 'spy', ephemeralID: 'id'),
    );
    final event = await future;
    expect(event.contactName, 'spy');
  });

  test('identityRevealedStream relays controller events', () async {
    final future = service.identityRevealedStream.first;
    service.emitIdentityRevealed('peer');
    final value = await future;
    expect(value, 'peer');
  });

  test('isHandshakeInProgress is false when coordinator missing', () {
    expect(service.isHandshakeInProgress, isFalse);
  });

  test('hasHandshakeCompleted is false when coordinator missing', () {
    expect(service.hasHandshakeCompleted, isFalse);
  });

  test('currentHandshakePhase is null when coordinator missing', () {
    expect(service.currentHandshakePhase, isNull);
  });
}
