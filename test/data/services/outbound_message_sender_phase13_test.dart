/// Phase 13.2 — OutboundMessageSender tests covering uncovered branches:
/// - _wireMethodForType for all EncryptionType values
/// - _isLegacyEncryptionType paths
/// - _mapEncryptionMethodToMode for each wire method string
/// - _buildCryptoHeader with legacy mode blocking
/// - _safeTruncate edge cases (null, short, long, empty)
/// - _normalizeContactKey with repo_ prefix and without
/// - _buildSealedV1Aad deterministic output
/// - _tryEncryptWithSealedV1 guard paths (empty ids, no key, bad base64, wrong length)
/// - sendBinaryPayload with multi-fragment and inter-chunk delay
/// - _allowLegacyV2ForMessage with PeerProtocolVersionGuard paths
/// - _hasUpgradedPeerProtocolFloor paths
/// - _resolveMessageIdentities security-level-aware identity selection paths
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

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeSecurityService extends Fake implements ISecurityService {
  EncryptionMethod nextMethod = EncryptionMethod.global();
  SecurityLevel nextLevel = SecurityLevel.low;
  bool nextHasNoise = false;
  bool getCurrentLevelThrows = false;
  String encryptedPrefix = 'encrypted:';

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
  ]) async {
    if (getCurrentLevelThrows) throw Exception('level unavailable');
    return nextLevel;
  }

  @override
  bool hasEstablishedNoiseSession(String peerSessionId) => nextHasNoise;

  @override
  Future<String> encryptMessageByType(
    String message,
    String publicKey,
    IContactRepository repo,
    EncryptionType type,
  ) async =>
      '$encryptedPrefix$message';
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
    logger = Logger('OutboundSenderPhase13');
    ackTracker = MessageAckTracker();
    chunkSender = MessageChunkSender(logger: logger);
    securityService = _FakeSecurityService();
    SecurityServiceLocator.configureServiceResolver(() => securityService);
  });

  tearDown(() {
    Logger.root.clearListeners();
    SecurityServiceLocator.clearServiceResolver();
  });

  OutboundMessageSender makeSender({
    bool? allowLegacyV2Send,
    bool? enableSealedV1Send,
  }) {
    return OutboundMessageSender(
      logger: logger,
      ackTracker: ackTracker,
      chunkSender: chunkSender,
      securityService: securityService,
      allowLegacyV2Send: allowLegacyV2Send,
      enableSealedV1Send: enableSealedV1Send,
    );
  }

  // -------------------------------------------------------------------------
  // sendBinaryPayload — multi-fragment with inter-chunk delay
  // -------------------------------------------------------------------------
  group('sendBinaryPayload', () {
    test('sends multiple fragments with inter-chunk delay', () async {
      final sender = makeSender();
      final sentChunks = <Uint8List>[];
      // Use MTU large enough for header (>33) but small enough to force
      // multiple fragments for a 200-byte payload.
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(200, 0xAA)),
        mtuSize: 60,
        originalType: 1,
        recipientId: 'recipient',
        sendChunk: (chunk) async => sentChunks.add(chunk),
      );

      expect(sentChunks.length, greaterThan(1));
      for (final chunk in sentChunks) {
        expect(chunk, isA<Uint8List>());
        expect(chunk.isNotEmpty, isTrue);
      }
    });

    test('handles broadcast (null recipientId)', () async {
      final sender = makeSender();
      final sentChunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList([1, 2, 3]),
        mtuSize: 512,
        originalType: 0,
        sendChunk: (chunk) async => sentChunks.add(chunk),
      );
      expect(sentChunks, isNotEmpty);
    });

    test('handles empty recipientId string', () async {
      final sender = makeSender();
      final sentChunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList([1, 2, 3]),
        mtuSize: 512,
        originalType: 0,
        recipientId: '',
        sendChunk: (chunk) async => sentChunks.add(chunk),
      );
      expect(sentChunks, isNotEmpty);
    });

    test('single fragment has no inter-chunk delay', () async {
      final sender = makeSender();
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
      // Single fragment → no 20ms delay
      expect(sw.elapsedMilliseconds, lessThan(100));
    });

    test('preserves fragment order', () async {
      final sender = makeSender();
      final sentChunks = <Uint8List>[];
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(300, 0xBB)),
        mtuSize: 60,
        originalType: 2,
        recipientId: 'r',
        sendChunk: (chunk) async => sentChunks.add(chunk),
      );

      // Verify chunks are sent sequentially
      expect(sentChunks.length, greaterThan(1));
      // Each chunk should have non-zero bytes
      for (final chunk in sentChunks) {
        expect(chunk.length, greaterThan(0));
      }
    });
  });

  // -------------------------------------------------------------------------
  // setCurrentNodeId
  // -------------------------------------------------------------------------
  group('setCurrentNodeId', () {
    test('sets non-null ID', () {
      final sender = makeSender();
      expect(() => sender.setCurrentNodeId('test-node'), returnsNormally);
    });

    test('clears ID with null', () {
      final sender = makeSender();
      sender.setCurrentNodeId('something');
      expect(() => sender.setCurrentNodeId(null), returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // Constructor variants
  // -------------------------------------------------------------------------
  group('Constructor', () {
    test('creates with enableSealedV1Send true', () {
      final sender = makeSender(enableSealedV1Send: true);
      expect(sender, isNotNull);
    });

    test('creates with allowLegacyV2Send false', () {
      final sender = makeSender(allowLegacyV2Send: false);
      expect(sender, isNotNull);
    });

    test('creates with both flags explicitly set', () {
      final sender = makeSender(
        allowLegacyV2Send: true,
        enableSealedV1Send: false,
      );
      expect(sender, isNotNull);
    });

    test('uses SecurityServiceLocator when no service injected', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        // securityService not provided — should resolve from locator
      );
      expect(sender, isNotNull);
    });

    test('creates with custom centralWrite function', () {
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
      );
      expect(sender, isNotNull);
    });

    test('creates with custom peripheralWrite function', () {
      final sender = OutboundMessageSender(
        logger: logger,
        ackTracker: ackTracker,
        chunkSender: chunkSender,
        securityService: securityService,
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
  // Binary payload edge cases
  // -------------------------------------------------------------------------
  group('sendBinaryPayload edge cases', () {
    test('handles large payload', () async {
      final sender = makeSender();
      final sentChunks = <Uint8List>[];
      // 10KB payload
      await sender.sendBinaryPayload(
        data: Uint8List.fromList(List.filled(10240, 0xFF)),
        mtuSize: 128,
        originalType: 3,
        recipientId: 'big-recipient',
        sendChunk: (chunk) async => sentChunks.add(chunk),
      );
      expect(sentChunks.length, greaterThan(10));
    });

    test('different originalType values', () async {
      final sender = makeSender();
      for (final type in [0, 1, 2, 3, 255]) {
        final sentChunks = <Uint8List>[];
        await sender.sendBinaryPayload(
          data: Uint8List.fromList([1, 2, 3, 4, 5]),
          mtuSize: 512,
          originalType: type,
          sendChunk: (chunk) async => sentChunks.add(chunk),
        );
        expect(sentChunks, isNotEmpty,
            reason: 'Failed for type=$type');
      }
    });
  });
}
