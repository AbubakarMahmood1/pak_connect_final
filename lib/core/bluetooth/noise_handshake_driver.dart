import 'dart:convert';
import 'dart:typed_data';
import 'package:logging/logging.dart';
import '../security/noise/models/noise_models.dart';
import '../services/security_manager.dart';
import 'kk_pattern_tracker.dart';

class NoiseHandshakePlan {
  NoiseHandshakePlan({required this.message1, required this.pattern});

  final Uint8List message1;
  final NoisePattern pattern;
}

class NoiseHandshake1Result {
  NoiseHandshake1Result({required this.message2, required this.isKkPattern});

  final Uint8List message2;
  final bool isKkPattern;
}

/// Handles Noise handshake message generation/processing.
///
/// Keeps cryptographic operations isolated from HandshakeCoordinator orchestration.
class NoiseHandshakeDriver {
  NoiseHandshakeDriver({
    required Logger logger,
    required KKPatternTracker kkPatternTracker,
  }) : _logger = logger,
       _kkTracker = kkPatternTracker;

  final Logger _logger;
  final KKPatternTracker _kkTracker;

  /// Create Noise handshake message 1 (initiator).
  ///
  /// Selects KK when possible, otherwise XX.
  Future<NoiseHandshakePlan> prepareHandshake1({
    required String myEphemeralId,
    required String theirEphemeralId,
    String? theirNoisePublicKey,
  }) async {
    final noiseService = SecurityManager.instance.noiseService;
    if (noiseService == null) {
      throw Exception('Noise service not initialized');
    }

    NoisePattern selectedPattern = NoisePattern.xx; // Safe default
    Uint8List? remoteStaticKey;

    if (theirNoisePublicKey != null) {
      // We already know their Noise key (from previous session or hint)
      final peerKey = theirNoisePublicKey;
      if (_kkTracker.shouldAttempt(peerKey)) {
        _logger.info('🔑 Have peer Noise key - attempting KK pattern');
        selectedPattern = NoisePattern.kk;
        remoteStaticKey = base64.decode(peerKey);
      } else {
        _logger.info('⚠️ KK backoff active or max retries reached - using XX');
      }
    } else {
      _logger.info('👤 No prior Noise key - using XX pattern (first contact)');
    }

    final msg1 = await noiseService.initiateHandshake(
      theirEphemeralId,
      pattern: selectedPattern,
      remoteStaticPublicKey: remoteStaticKey,
    );

    if (msg1 == null) {
      throw Exception('Failed to initiate Noise handshake');
    }

    _logger.info(
      '  Generated message 1: ${msg1.length} bytes (pattern: $selectedPattern)',
    );

    return NoiseHandshakePlan(message1: msg1, pattern: selectedPattern);
  }

  /// Process inbound Noise handshake 1 (responder); returns message 2.
  Future<NoiseHandshake1Result> processInboundHandshake1({
    required Uint8List data,
    required String peerId,
  }) async {
    final noiseService = SecurityManager.instance.noiseService;
    if (noiseService == null) {
      throw Exception('Noise service not initialized');
    }

    final isKK = data.length == 96; // KK message 1 is 96 bytes (e, es, ss)

    final msg2 = await noiseService.processHandshakeMessage(data, peerId);

    if (msg2 == null) {
      throw Exception('Failed to process Noise handshake 1');
    }

    _logger.info('  Generated message 2: ${msg2.length} bytes');

    return NoiseHandshake1Result(message2: msg2, isKkPattern: isKK);
  }

  /// Process Noise handshake 2 (initiator); returns message 3.
  Future<Uint8List> processHandshake2({
    required Uint8List data,
    required String peerId,
  }) async {
    final noiseService = SecurityManager.instance.noiseService;
    if (noiseService == null) {
      throw Exception('Noise service not initialized');
    }

    final msg3 = await noiseService.processHandshakeMessage(data, peerId);

    if (msg3 == null) {
      throw Exception('Failed to process Noise handshake 2');
    }

    _logger.info('  Generated Noise message 3: ${msg3.length} bytes');
    return msg3;
  }

  /// Process Noise handshake 3 (responder).
  Future<void> processHandshake3({
    required Uint8List data,
    required String peerId,
  }) async {
    final noiseService = SecurityManager.instance.noiseService;
    if (noiseService == null) {
      throw Exception('Noise service not initialized');
    }

    final result = await noiseService.processHandshakeMessage(data, peerId);

    if (result != null) {
      _logger.warning('⚠️ Noise handshake 3 returned data (expected null)');
    }

    _logger.info('  Noise handshake 3 processed successfully');
  }
}
