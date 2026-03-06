/// Phase 11.2 — OutboundMessageSender tests covering constructor defaults,
/// sendBinaryPayload, setCurrentNodeId, and helper method behaviour
/// accessed through the public API.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/outbound_message_sender.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/messaging/message_ack_tracker.dart';
import 'package:pak_connect/domain/messaging/message_chunk_sender.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeSecurityService extends Fake implements ISecurityService {
  EncryptionMethod nextMethod = EncryptionMethod.global();
  SecurityLevel nextLevel = SecurityLevel.low;

  @override
  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  ) async =>
      nextMethod;

  @override
  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]) async =>
      nextLevel;

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => false;

  @override
  Future<String> encryptMessageByType(
    String message,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async =>
      'encrypted:$message';
}

// ---------------------------------------------------------------------------
void main() {
  late Logger logger;
  late MessageAckTracker ackTracker;
  late MessageChunkSender chunkSender;
  late _FakeSecurityService securityService;
  late List<LogRecord> logs;

  setUp(() {
    logs = [];
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(logs.add);

    logger = Logger('OutboundMessageSenderTest');
    ackTracker = MessageAckTracker();
    chunkSender = MessageChunkSender(logger: logger);
    securityService = _FakeSecurityService();
  });

  tearDown(() {
    Logger.root.clearListeners();
  });

  // -------------------------------------------------------------------------
  // Constructor & defaults
  // -------------------------------------------------------------------------
  group('OutboundMessageSender construction', () {
    test('creates with required args and security service', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );
      expect(sender, isNotNull);
    });

    test('creates with custom legacy/sealed flags', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
        allowLegacyV2Send: false,
        enableSealedV1Send: true,
      );
      expect(sender, isNotNull);
    });

    test('creates with custom write functions', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
        centralWrite: ({
          required centralManager,
          required peripheral,
          required characteristic,
          required value,
        }) async {},
        peripheralWrite: ({
          required peripheralManager,
          required central,
          required characteristic,
          required value,
          bool withoutResponse = false,
        }) async {},
      );
      expect(sender, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // setCurrentNodeId
  // -------------------------------------------------------------------------
  group('setCurrentNodeId', () {
    test('sets and does not throw', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );
      expect(() => sender.setCurrentNodeId('node-abc'), returnsNormally);
    });

    test('null clears node id', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );
      sender.setCurrentNodeId('node-1');
      expect(() => sender.setCurrentNodeId(null), returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // sendBinaryPayload
  // -------------------------------------------------------------------------
  group('sendBinaryPayload', () {
    test('fragments and sends all chunks', () async {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );

      final sentChunks = <Uint8List>[];

      // 100 bytes of data with a fairly large MTU should result in small
      // number of fragments
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(100, 0x42)),
        mtuSize: 200,
        originalType: 1,
        recipientId: 'rpk-1',
        sendChunk: (chunk) async => sentChunks.add(chunk),
      );

      expect(sentChunks, isNotEmpty);
      // Each chunk should be a valid byte array
      for (final chunk in sentChunks) {
        expect(chunk, isA<Uint8List>());
        expect(chunk.isNotEmpty, isTrue);
      }
    });

    test('works with null recipientId', () async {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );

      final sentChunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList([1, 2, 3, 4, 5]),
        mtuSize: 200,
        originalType: 2,
        sendChunk: (chunk) async => sentChunks.add(chunk),
      );
      expect(sentChunks, isNotEmpty);
    });

    test('single fragment does not add inter-chunk delay', () async {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );

      var sendCount = 0;
      final sw = Stopwatch()..start();
      await sender.sendBinaryPayload(
        data: Uint8List.fromList([0x01]),
        mtuSize: 512,
        originalType: 0,
        sendChunk: (chunk) async => sendCount++,
      );
      sw.stop();
      expect(sendCount, greaterThanOrEqualTo(1));
      // Should be fast since single fragment → no delay
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });
}
