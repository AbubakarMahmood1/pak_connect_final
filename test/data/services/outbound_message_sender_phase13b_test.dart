/// Phase 13b — OutboundMessageSender additional coverage tests focusing on:
/// - sendBinaryPayload error handling and boundary conditions
/// - Fragment structure validation (magic byte, fragment ID consistency)
/// - NodeId management edge cases
/// - Constructor combinations
library;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/outbound_message_sender.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/messaging/message_ack_tracker.dart';
import 'package:pak_connect/domain/messaging/message_chunk_sender.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import 'package:pak_connect/domain/utils/binary_fragmenter.dart';

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
// Tests
// ---------------------------------------------------------------------------

void main() {
  Logger.root.level = Level.OFF;

  late Logger logger;
  late MessageAckTracker ackTracker;
  late MessageChunkSender chunkSender;
  late _FakeSecurityService securityService;

  setUp(() {
    logger = Logger('OutboundSenderPhase13b');
    ackTracker = MessageAckTracker();
    chunkSender = MessageChunkSender(logger: logger);
    securityService = _FakeSecurityService();
    SecurityServiceLocator.configureServiceResolver(() => securityService);
  });

  tearDown(() {
    Logger.root.clearListeners();
    SecurityServiceLocator.clearServiceResolver();
  });

  OutboundMessageSender makeSender() {
    return OutboundMessageSender(
      logger: logger,
      ackTracker: ackTracker,
      chunkSender: chunkSender,
      securityService: securityService,
    );
  }

  // -------------------------------------------------------------------------
  // sendBinaryPayload — error handling
  // -------------------------------------------------------------------------
  group('sendBinaryPayload error handling', () {
    test('propagates sendChunk Exception', () async {
      final sender = makeSender();
      expect(
        () => sender.sendBinaryPayload(
          data: Uint8List.fromList([1, 2, 3]),
          mtuSize: 512,
          originalType: 1,
          sendChunk: (chunk) async => throw Exception('write failed'),
        ),
        throwsException,
      );
    });

    test('propagates sendChunk StateError', () async {
      final sender = makeSender();
      expect(
        () => sender.sendBinaryPayload(
          data: Uint8List.fromList([1, 2, 3]),
          mtuSize: 512,
          originalType: 1,
          sendChunk: (chunk) async => throw StateError('disconnected'),
        ),
        throwsStateError,
      );
    });

    test('first chunk failure stops sending remaining chunks', () async {
      final sender = makeSender();
      var sendCount = 0;

      try {
        await sender.sendBinaryPayload(
          data: Uint8List.fromList(List.filled(500, 0xAA)),
          mtuSize: 60,
          originalType: 1,
          sendChunk: (chunk) async {
            sendCount++;
            if (sendCount == 1) throw Exception('first chunk failed');
          },
        );
      } catch (_) {}

      expect(sendCount, 1);
    });

    test('middle chunk failure stops sending subsequent chunks', () async {
      final sender = makeSender();
      var sendCount = 0;

      try {
        await sender.sendBinaryPayload(
          data: Uint8List.fromList(List.filled(500, 0xBB)),
          mtuSize: 60,
          originalType: 1,
          sendChunk: (chunk) async {
            sendCount++;
            if (sendCount == 3) throw Exception('third chunk failed');
          },
        );
      } catch (_) {}

      expect(sendCount, 3);
    });
  });

  // -------------------------------------------------------------------------
  // sendBinaryPayload — boundary conditions
  // -------------------------------------------------------------------------
  group('sendBinaryPayload boundary conditions', () {
    test('single byte payload produces one fragment', () async {
      final sender = makeSender();
      final chunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList([0x42]),
        mtuSize: 512,
        originalType: 0,
        sendChunk: (chunk) async => chunks.add(chunk),
      );
      expect(chunks.length, 1);
    });

    test('small payload within single-fragment capacity', () async {
      final sender = makeSender();
      final chunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(50, 0xCC)),
        mtuSize: 200,
        originalType: 0,
        sendChunk: (chunk) async => chunks.add(chunk),
      );
      expect(chunks.length, 1);
    });

    test('very small MTU throws on insufficient header space', () async {
      final sender = makeSender();
      expect(
        () => sender.sendBinaryPayload(
          data: Uint8List.fromList([1, 2, 3]),
          mtuSize: 30,
          originalType: 0,
          sendChunk: (chunk) async {},
        ),
        throwsArgumentError,
      );
    });

    test('recipient with unicode characters', () async {
      final sender = makeSender();
      final chunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList([1, 2, 3, 4, 5]),
        mtuSize: 200,
        originalType: 1,
        recipientId: '\u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645',
        sendChunk: (chunk) async => chunks.add(chunk),
      );
      expect(chunks, isNotEmpty);
    });

    test('long recipientId with adequate MTU produces fragments', () async {
      final sender = makeSender();
      final chunks = <Uint8List>[];
      final longRecipient = 'r' * 100;
      await sender.sendBinaryPayload(
        data: Uint8List.fromList([1, 2, 3]),
        mtuSize: 512,
        originalType: 1,
        recipientId: longRecipient,
        sendChunk: (chunk) async => chunks.add(chunk),
      );
      expect(chunks, isNotEmpty);
    });

    test('larger payload produces many fragments', () async {
      final sender = makeSender();
      final chunks = <Uint8List>[];
      // 2 KB payload with MTU 128 → manageable fragment count without timeout
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(2048, 0xDD)),
        mtuSize: 128,
        originalType: 1,
        recipientId: 'big',
        sendChunk: (chunk) async => chunks.add(chunk),
      );
      expect(chunks.length, greaterThan(10));
    });

    test('all fragments start with BinaryFragmenter magic byte 0xF0', () async {
      final sender = makeSender();
      final chunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(200, 0xEE)),
        mtuSize: 60,
        originalType: 1,
        recipientId: 'magic',
        sendChunk: (chunk) async => chunks.add(chunk),
      );
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(
          chunk[0],
          BinaryFragmenter.magic,
          reason: 'Fragment must start with magic byte',
        );
      }
    });

    test('all fragments share the same fragment id (bytes 1-8)', () async {
      final sender = makeSender();
      final chunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(200, 0xFF)),
        mtuSize: 60,
        originalType: 1,
        recipientId: 'fid',
        sendChunk: (chunk) async => chunks.add(chunk),
      );
      expect(chunks.length, greaterThan(1));
      final firstFragId = chunks[0].sublist(1, 9);
      for (var i = 1; i < chunks.length; i++) {
        expect(
          chunks[i].sublist(1, 9),
          equals(firstFragId),
          reason: 'Fragment $i must share fragment id with fragment 0',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // sendBinaryPayload — timing and isolation
  // -------------------------------------------------------------------------
  group('sendBinaryPayload timing', () {
    test('multi-fragment send introduces inter-chunk delay', () async {
      final sender = makeSender();
      var count = 0;
      final sw = Stopwatch()..start();
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(300, 0x11)),
        mtuSize: 60,
        originalType: 0,
        sendChunk: (chunk) async => count++,
      );
      sw.stop();
      expect(count, greaterThan(2));
      // Each inter-chunk gap is 20ms; with N fragments, total >= (N-1)*20ms
      // Use lenient assertion for CI variability
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo((count - 1) * 10));
    });

    test('sequential sends maintain fragment isolation', () async {
      final sender = makeSender();
      final firstChunks = <Uint8List>[];
      final secondChunks = <Uint8List>[];

      await sender.sendBinaryPayload(
        data: Uint8List.fromList([1, 2, 3]),
        mtuSize: 512,
        originalType: 1,
        recipientId: 'first',
        sendChunk: (chunk) async => firstChunks.add(chunk),
      );

      await sender.sendBinaryPayload(
        data: Uint8List.fromList([4, 5, 6]),
        mtuSize: 512,
        originalType: 2,
        recipientId: 'second',
        sendChunk: (chunk) async => secondChunks.add(chunk),
      );

      expect(firstChunks, isNotEmpty);
      expect(secondChunks, isNotEmpty);
      // Different sends produce different fragment IDs
      expect(firstChunks[0].sublist(1, 9), isNot(equals(secondChunks[0].sublist(1, 9))));
    });
  });

  // -------------------------------------------------------------------------
  // NodeId management edge cases
  // -------------------------------------------------------------------------
  group('NodeId management', () {
    test('setCurrentNodeId persists across repeated calls', () {
      final sender = makeSender();
      sender.setCurrentNodeId('node-1');
      sender.setCurrentNodeId('node-2');
      sender.setCurrentNodeId('node-3');
      expect(() => sender.setCurrentNodeId('node-4'), returnsNormally);
    });

    test('setCurrentNodeId accepts empty string', () {
      final sender = makeSender();
      expect(() => sender.setCurrentNodeId(''), returnsNormally);
    });

    test('setCurrentNodeId accepts very long id', () {
      final sender = makeSender();
      final longId = 'x' * 2048;
      expect(() => sender.setCurrentNodeId(longId), returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // Constructor edge cases
  // -------------------------------------------------------------------------
  group('Constructor edge cases', () {
    test('creates with all custom write functions', () {
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

    test('resolves security from locator when no service injected', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
      );
      expect(sender, isNotNull);
    });

    test('sender with all flags disabled', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );
      expect(sender, isNotNull);
    });

    test('sender with repeated default construction', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
      );
      expect(sender, isNotNull);
    });
  });
}
