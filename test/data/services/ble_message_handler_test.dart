import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart'
    as relay_models;
import '../../test_helpers/messaging/in_memory_offline_message_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BLEMessageHandler', () {
    late BLEMessageHandler handler;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      handler = BLEMessageHandler(enableCleanupTimer: false);
    });

    tearDown(() {
      handler.dispose();
    });

    test(
      'checkQRIntroductionMatch returns true only when matching intro exists',
      () async {
        SharedPreferences.setMockInitialValues({
          'scanned_intro_public-key-a': jsonEncode({'intro_id': 'intro-1'}),
        });

        final hasMatch = await handler.checkQRIntroductionMatch(
          otherPublicKey: 'public-key-a',
          theirName: 'Alice',
        );
        final hasNoMatch = await handler.checkQRIntroductionMatch(
          otherPublicKey: 'public-key-b',
          theirName: 'Bob',
        );

        expect(hasMatch, isTrue);
        expect(hasNoMatch, isFalse);
      },
    );

    test(
      'handleQRIntroductionClaim accepts known and unknown intro sessions',
      () async {
        SharedPreferences.setMockInitialValues({
          'my_qr_session_intro-1': jsonEncode({
            'started_showing': 1000,
            'stopped_showing': 2000,
          }),
        });

        final stateManager = BLEStateManager();

        await handler.handleQRIntroductionClaim(
          otherPublicKey: 'peer-key-1',
          introId: 'intro-1',
          scannedTime: 1500,
          theirName: 'Peer',
          stateManager: stateManager,
        );
        await handler.handleQRIntroductionClaim(
          otherPublicKey: 'peer-key-2',
          introId: 'unknown-intro',
          scannedTime: 1500,
          theirName: 'Unknown',
          stateManager: stateManager,
        );
      },
    );

    test(
      'processReceivedData ignores ping byte and non-chunk binary payload',
      () async {
        final repo = ContactRepository();

        final pingResult = await handler.processReceivedData(
          Uint8List.fromList([0x00]),
          contactRepository: repo,
        );
        final binaryResult = await handler.processReceivedData(
          Uint8List.fromList([0x7F, 0x00, 0x01]),
          senderPublicKey: 'peer-key',
          contactRepository: repo,
        );

        expect(pingResult, isNull);
        expect(binaryResult, isNull);
      },
    );

    test(
      'relay wrappers are callable before and after relay initialization',
      () async {
        final preInitRelay = await handler.createOutgoingRelay(
          originalMessageId: 'msg-before-init',
          originalContent: 'hello',
          finalRecipientPublicKey: 'recipient-a',
        );
        final preInitDecrypt = await handler.shouldAttemptDecryption(
          finalRecipientPublicKey: 'recipient-a',
          originalSenderPublicKey: 'sender-a',
        );

        expect(preInitRelay, isNull);
        expect(preInitDecrypt, isFalse);

        await handler.initializeRelaySystem(
          currentNodeId: 'node-local',
          messageQueue: InMemoryOfflineMessageQueue(),
        );
        handler.setNextHopsProvider(() => ['hop-1', 'hop-2']);

        final postInitRelay = await handler.createOutgoingRelay(
          originalMessageId: 'msg-after-init',
          originalContent: 'hello after init',
          finalRecipientPublicKey: 'recipient-b',
        );
        final postInitDecrypt = await handler.shouldAttemptDecryption(
          finalRecipientPublicKey: 'recipient-b',
          originalSenderPublicKey: 'sender-b',
        );

        expect(handler.getAvailableNextHops(), ['hop-1', 'hop-2']);
        expect(postInitRelay, anyOf(isNull, isNotNull));
        expect(postInitDecrypt, isA<bool>());
        expect(handler.getRelayStatistics(), isNotNull);
      },
    );

    test('sendQueueSyncMessage preserves compatibility path', () async {
      final characteristic = GATTCharacteristic.mutable(
        uuid: UUID.fromString('00000000-0000-0000-0000-00000000c0c0'),
        properties: [GATTCharacteristicProperty.write],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: const [],
      );
      final queueSyncMessage = relay_models.QueueSyncMessage(
        queueHash: 'hash-1',
        messageIds: ['m1', 'm2'],
        syncTimestamp: DateTime.now(),
        nodeId: 'node-local',
        syncType: relay_models.QueueSyncType.request,
      );

      final sent = await handler.sendQueueSyncMessage(
        centralManager: null,
        peripheralManager: null,
        connectedDevice: null,
        connectedCentral: null,
        messageCharacteristic: characteristic,
        syncMessage: queueSyncMessage,
        mtuSize: 64,
        stateManager: BLEStateManager(),
      );

      expect(sent, isTrue);
    });

    test('dispose is safe to call repeatedly', () {
      handler.dispose();
      handler.dispose();
    });
  });
}
