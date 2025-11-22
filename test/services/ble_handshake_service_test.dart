import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/models/spy_mode_info.dart';
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

class _TestStateManager {
  bool hasBleConnection = true;
  bool isPeripheralMode = false;
  String? myUserName = 'Alice';
  String? myEphemeralId;
  Future<void> Function()? _loadUserNameHandler;
  Future<String> Function()? _persistentIdHandler;

  void mockLoadUserName(Future<void> Function() handler) {
    _loadUserNameHandler = handler;
  }

  void mockPersistentId(Future<String> Function() handler) {
    _persistentIdHandler = handler;
  }

  Future<void> loadUserName() async {
    if (_loadUserNameHandler != null) {
      return _loadUserNameHandler!();
    }
  }

  Future<String> getMyPersistentId() async {
    if (_persistentIdHandler != null) {
      return _persistentIdHandler!();
    }
    return 'pub-key-12345678';
  }
}

@GenerateNiceMocks([MockSpec<IntroHintRepository>()])
void main() {
  late _TestStateManager mockStateManager;
  late MockIntroHintRepository mockIntroHintRepository;
  late StreamController<SpyModeInfo> spyModeController;
  late StreamController<String> identityController;
  late List<ProtocolMessage> sentMessages;
  late BLEHandshakeService service;

  setUp(() {
    mockStateManager = _TestStateManager();
    mockIntroHintRepository = MockIntroHintRepository();
    spyModeController = StreamController<SpyModeInfo>.broadcast();
    identityController = StreamController<String>.broadcast();
    sentMessages = [];

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
      spyModeDetectedController: spyModeController,
      identityRevealedController: identityController,
      introHintRepo: mockIntroHintRepository,
      messageBuffer: [],
    );
  });

  tearDown(() async {
    await spyModeController.close();
    await identityController.close();
  });

  test('requestIdentityExchange does nothing when not connected', () async {
    mockStateManager.hasBleConnection = false;

    await service.requestIdentityExchange();

    expect(sentMessages, isEmpty);
  });

  test('requestIdentityExchange sends identity when connected', () async {
    mockStateManager.hasBleConnection = true;

    await service.requestIdentityExchange();

    expect(sentMessages, hasLength(1));
    expect(sentMessages.first.type, ProtocolMessageType.identity);
  });

  test('triggerIdentityReExchange swallows load errors', () async {
    mockStateManager.mockLoadUserName(() => Future.error(Exception('fail')));

    await service.triggerIdentityReExchange();

    expect(sentMessages, isEmpty);
  });

  test(
    'triggerIdentityReExchange sends identity when peripheral mode active',
    () async {
      mockStateManager.isPeripheralMode = true;

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
      spyModeDetectedController: spyModeController,
      identityRevealedController: identityController,
      introHintRepo: mockIntroHintRepository,
      messageBuffer: buffer,
    );

    final result = service.getBufferedMessages();
    expect(result, isNot(same(buffer)));
    expect(result.length, 1);
  });

  test('spyModeDetectedStream relays controller events', () async {
    final future = service.spyModeDetectedStream.first;
    spyModeController.add(SpyModeInfo(contactName: 'spy', ephemeralID: 'id'));
    final event = await future;
    expect(event.contactName, 'spy');
  });

  test('identityRevealedStream relays controller events', () async {
    final future = service.identityRevealedStream.first;
    identityController.add('peer');
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
