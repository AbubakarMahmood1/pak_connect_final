import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/data/services/ble_message_handler_facade.dart';
import 'package:pak_connect/domain/constants/binary_payload_types.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/utils/binary_fragmenter.dart';
import 'package:pak_connect/domain/utils/message_fragmenter.dart';
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BLEMessageHandlerFacade', () {
    late _FakeSecurityService securityService;
    late BLEMessageHandlerFacade facade;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BLEMessageHandlerFacade.clearDependencyResolvers();
      securityService = _FakeSecurityService();
      facade = BLEMessageHandlerFacade(
        enableCleanupTimer: false,
        securityService: securityService,
      );
    });

    tearDown(() {
      BLEMessageHandlerFacade.clearDependencyResolvers();
      facade.dispose();
    });

    test('sendMessage returns false when central sender is not configured', () async {
      final result = await facade.sendMessage(
        recipientKey: 'recipient_key_001',
        content: 'hello',
        timeout: const Duration(seconds: 1),
      );

      expect(result, isFalse);
    });

    test('sendMessage delegates to configured central sender', () async {
      final invocations = <Map<String, Object?>>[];
      facade.configureSenders(
        sendCentral: ({
          required recipientKey,
          required content,
          required timeout,
          messageId,
          originalIntendedRecipient,
        }) async {
          invocations.add({
            'recipientKey': recipientKey,
            'content': content,
            'timeout': timeout,
            'messageId': messageId,
            'originalIntendedRecipient': originalIntendedRecipient,
          });
          return true;
        },
        sendPeripheral: ({
          required senderKey,
          required content,
          messageId,
        }) async => true,
      );

      final result = await facade.sendMessage(
        recipientKey: 'recipient_key_002',
        content: 'payload',
        timeout: const Duration(milliseconds: 500),
        messageId: 'msg-1',
        originalIntendedRecipient: 'final-destination',
      );

      expect(result, isTrue);
      expect(invocations.length, 1);
      expect(invocations.single['recipientKey'], 'recipient_key_002');
      expect(invocations.single['content'], 'payload');
      expect(invocations.single['messageId'], 'msg-1');
      expect(
        invocations.single['originalIntendedRecipient'],
        'final-destination',
      );
    });

    test('sendMessage returns false when configured sender throws', () async {
      facade.configureSenders(
        sendCentral: ({
          required recipientKey,
          required content,
          required timeout,
          messageId,
          originalIntendedRecipient,
        }) async {
          throw StateError('boom');
        },
        sendPeripheral: ({
          required senderKey,
          required content,
          messageId,
        }) async => true,
      );

      final result = await facade.sendMessage(
        recipientKey: 'recipient_key_003',
        content: 'payload',
        timeout: const Duration(seconds: 1),
      );

      expect(result, isFalse);
    });

    test('sendPeripheralMessage delegates and handles failures', () async {
      var shouldThrow = false;
      facade.configureSenders(
        sendCentral: ({
          required recipientKey,
          required content,
          required timeout,
          messageId,
          originalIntendedRecipient,
        }) async => true,
        sendPeripheral: ({
          required senderKey,
          required content,
          messageId,
        }) async {
          if (shouldThrow) {
            throw StateError('peripheral send fail');
          }
          return senderKey == 'sender_a' && content == 'hi';
        },
      );

      final ok = await facade.sendPeripheralMessage(
        senderKey: 'sender_a',
        content: 'hi',
        messageId: 'm1',
      );
      expect(ok, isTrue);

      shouldThrow = true;
      final failed = await facade.sendPeripheralMessage(
        senderKey: 'sender_b',
        content: 'hi',
      );
      expect(failed, isFalse);
    });

    test('processReceivedData returns null for non-fragment non-protocol payload', () async {
      final result = await facade.processReceivedData(
        data: Uint8List.fromList([0x7F, 0x01, 0x02]),
        fromDeviceId: 'dev-1',
        fromNodeId: 'node-1',
      );

      expect(result, isNull);
    });

    test('routes reassembled handshake protocol messages to handshake service', () async {
      final handshakeService = _FakeHandshakeService();
      handshakeService.nextHandleResult = true;

      BLEMessageHandlerFacade.configureDependencyResolvers(
        handshakeServiceResolver: () => handshakeService,
      );

      final handshakeMessage = ProtocolMessage.connectionReady(
        deviceId: 'device-x',
        deviceName: 'X',
      );
      final bytes = handshakeMessage.toBytes(enableCompression: false);
      final chunks = MessageFragmenter.fragmentBytes(bytes, 90, 'phase2_msg_001');

      String? lastResult;
      for (final chunk in chunks) {
        lastResult = await facade.processReceivedData(
          data: chunk.toBytes(),
          fromDeviceId: 'dev-2',
          fromNodeId: 'peer-node',
        );
      }

      expect(lastResult, isNull);
      expect(handshakeService.handleCalls, 1);
      expect(handshakeService.lastIsFromPeripheral, isFalse);
      expect(handshakeService.lastData, isNotNull);
    });

    test('processes binary payload reassembly and calls binary callback on decrypt success', () async {
      securityService.decryptResult = Uint8List.fromList([9, 8, 7, 6]);
      securityService.decryptShouldThrow = false;

      Uint8List? callbackBytes;
      int? callbackType;
      String? callbackFragmentId;
      String? callbackSender;
      facade.onBinaryPayloadReceived = (
        data,
        originalType,
        fragmentId,
        ttl,
        recipient,
        senderNodeId,
      ) {
        callbackBytes = data;
        callbackType = originalType;
        callbackFragmentId = fragmentId;
        callbackSender = senderNodeId;
      };

      final fragments = BinaryFragmenter.fragment(
        data: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
        mtu: 120,
        originalType: BinaryPayloadType.media,
        ttl: 4,
      );

      for (final fragment in fragments) {
        await facade.processReceivedData(
          data: fragment,
          fromDeviceId: 'device-binary',
          fromNodeId: 'sender-node-key',
        );
      }

      expect(callbackBytes, isNotNull);
      expect(callbackBytes, Uint8List.fromList([9, 8, 7, 6]));
      expect(callbackType, BinaryPayloadType.media);
      expect(callbackFragmentId, isNotEmpty);
      expect(callbackSender, 'sender-node-key');
      expect(securityService.decryptCalls, 1);
      expect(securityService.lastDecryptPublicKey, 'sender-node-key');
    });

    test('drops binary payload when decrypt fails (fail-closed)', () async {
      securityService.decryptShouldThrow = true;

      var callbackCalls = 0;
      facade.onBinaryPayloadReceived = (
        data,
        originalType,
        fragmentId,
        ttl,
        recipient,
        senderNodeId,
      ) {
        callbackCalls++;
      };

      final fragments = BinaryFragmenter.fragment(
        data: Uint8List.fromList([42, 43, 44, 45]),
        mtu: 120,
        originalType: BinaryPayloadType.media,
        ttl: 4,
      );

      for (final fragment in fragments) {
        await facade.processReceivedData(
          data: fragment,
          fromDeviceId: 'device-binary-2',
          fromNodeId: 'sender-node-key-2',
        );
      }

      expect(callbackCalls, 0);
      expect(securityService.decryptCalls, 1);
    });

    test('forwards binary fragments for non-local recipients and stores reassembled forward payload', () async {
      facade.setCurrentNodeId('local-node');

      final forwarded = <_ForwardCall>[];
      facade.onForwardBinaryFragment = (
        data,
        fragmentId,
        index,
        fromDeviceId,
        fromNodeId,
      ) {
        forwarded.add(
          _ForwardCall(
            data: data,
            fragmentId: fragmentId,
            index: index,
            fromDeviceId: fromDeviceId,
            fromNodeId: fromNodeId,
          ),
        );
      };

      final originalData = Uint8List.fromList(
        List<int>.generate(120, (i) => i % 255),
      );
      final fragments = BinaryFragmenter.fragment(
        data: originalData,
        mtu: 55,
        originalType: BinaryPayloadType.media,
        recipient: 'remote-node',
        ttl: 5,
      );

      for (final fragment in fragments) {
        await facade.processReceivedData(
          data: fragment,
          fromDeviceId: 'sender-device',
          fromNodeId: 'sender-node',
        );
      }

      expect(forwarded.length, fragments.length);
      expect(forwarded.first.fragmentId, isNotEmpty);
      expect(forwarded.first.fromDeviceId, 'sender-device');
      expect(forwarded.first.fromNodeId, 'sender-node');

      final reassembled = facade.takeForwardReassembledPayload(
        forwarded.first.fragmentId,
      );
      expect(reassembled, isNotNull);
      expect(reassembled!.bytes, originalData);
      expect(reassembled.originalType, BinaryPayloadType.media);
      expect(reassembled.recipient, 'remote-node');
    });

    test('initializeRelaySystem accepts resolver and callback wiring', () async {
      final seenStore = _FakeSeenMessageStore();
      BLEMessageHandlerFacade.configureDependencyResolvers(
        seenMessageStoreResolver: () => seenStore,
      );

      facade.setMessageQueue(InMemoryOfflineMessageQueue());
      facade.setSpamPreventionManager(SpamPreventionManager());

      await facade.initializeRelaySystem(
        currentNodeId: 'node-relay',
        nextHopsProvider: () => ['next-1', 'next-2'],
        onRelayMessageReceived: (_, __, ___) {},
        onRelayDecisionMade: (_) {},
        onRelayStatsUpdated: (_) {},
      );

      facade.onContactRequestReceived = (_, __) {};
      facade.onContactAcceptReceived = (_, __) {};
      facade.onContactRejectReceived = () {};
      facade.onCryptoVerificationReceived = (_, __) {};
      facade.onCryptoVerificationResponseReceived = (_, __, ___, ____) {};
      facade.onQueueSyncReceived = (_, __) {};
      facade.onSendQueueMessages = (_, __) {};
      facade.onQueueSyncCompleted = (_, __) {};
      facade.onRelayMessageReceived = (_, __, ___) {};
      facade.onRelayMessageReceivedIds = (_, __, ___) {};
      facade.onRelayDecisionMade = (_) {};
      facade.onRelayStatsUpdated = (_) {};
      facade.onSendAckMessage = (_) {};
      facade.onSendRelayMessage = (_, __) {};
      facade.onTextMessageReceived = (_, __, ___) async {};
      facade.onIdentityRevealed = (_) {};

      expect(facade.getAvailableNextHops(), ['next-1', 'next-2']);
      // Ensure no crash on repeated disposal.
      facade.dispose();
      facade.dispose();
    });
  });
}

class _ForwardCall {
  _ForwardCall({
    required this.data,
    required this.fragmentId,
    required this.index,
    required this.fromDeviceId,
    required this.fromNodeId,
  });

  final Uint8List data;
  final String fragmentId;
  final int index;
  final String fromDeviceId;
  final String fromNodeId;
}

class _FakeSecurityService implements ISecurityService {
  int decryptCalls = 0;
  bool decryptShouldThrow = false;
  Uint8List decryptResult = Uint8List(0);
  String? lastDecryptPublicKey;
  String? lastMappingPersistentKey;
  String? lastMappingEphemeralId;

  @override
  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  ) async {
    decryptCalls++;
    lastDecryptPublicKey = publicKey;
    if (decryptShouldThrow) {
      throw StateError('decrypt failed');
    }
    return decryptResult;
  }

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {
    lastMappingPersistentKey = persistentPublicKey;
    lastMappingEphemeralId = ephemeralID;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected security call: $invocation');
}

class _FakeHandshakeService implements IBLEHandshakeService {
  int handleCalls = 0;
  bool nextHandleResult = false;
  Uint8List? lastData;
  bool? lastIsFromPeripheral;

  @override
  Future<bool> handleIncomingHandshakeMessage(
    Uint8List data, {
    bool isFromPeripheral = false,
  }) async {
    handleCalls++;
    lastData = data;
    lastIsFromPeripheral = isFromPeripheral;
    return nextHandleResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected handshake call: $invocation');
}

class _FakeSeenMessageStore implements ISeenMessageStore {
  @override
  Future<void> initialize() async {}

  @override
  bool hasDelivered(String messageId) => false;

  @override
  bool hasRead(String messageId) => false;

  @override
  Future<void> markDelivered(String messageId) async {}

  @override
  Future<void> markRead(String messageId) async {}

  @override
  Map<String, dynamic> getStatistics() => const {};

  @override
  Future<void> clear() async {}

  @override
  Future<void> performMaintenance() async {}
}
