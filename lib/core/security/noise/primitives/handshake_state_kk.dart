/// Handshake state machine for Noise Protocol KK pattern
///
/// Implements the KK pattern: → e es ss, ← e ee se
/// KK provides mutual authentication with pre-shared static public keys.
/// Two-message handshake (33% faster than XX pattern).
///
/// Reference: https://noiseprotocol.org/noise.html#interactive-patterns
library;

import 'dart:typed_data';
import 'dh_state.dart';
import 'symmetric_state.dart';
import 'cipher_state.dart';
import '../noise_handshake_exception.dart';

/// Handshake state for KK pattern
///
/// KK pattern requires both parties to know each other's static public keys.
/// Provides mutual authentication with faster handshake than XX.
class HandshakeStateKK {
  /// Protocol name for KK pattern
  static const String protocolName = 'Noise_KK_25519_ChaChaPoly_SHA256';

  /// Symmetric state for key derivation
  final SymmetricState _symmetricState;

  /// Local static key pair
  final DHState _localStatic;

  /// Local ephemeral key pair
  final DHState _localEphemeral;

  /// Remote static public key (pre-shared for KK)
  final DHState _remoteStatic;

  /// Remote ephemeral public key (set during handshake)
  DHState? _remoteEphemeral;

  /// True if we initiated the handshake
  final bool _isInitiator;

  /// Current message index in handshake (0 or 1)
  int _messageIndex = 0;

  /// Handshake complete flag
  bool _isComplete = false;

  /// Create handshake state for KK pattern
  ///
  /// [localStaticPrivateKey] Our 32-byte static private key
  /// [remoteStaticPublicKey] Their 32-byte static public key (REQUIRED for KK)
  /// [isInitiator] True if we're initiating, false if responding
  HandshakeStateKK({
    required Uint8List localStaticPrivateKey,
    required Uint8List remoteStaticPublicKey,
    required bool isInitiator,
  }) : _symmetricState = SymmetricState(protocolName),
       _localStatic = DHState(),
       _localEphemeral = DHState(),
       _remoteStatic = DHState(),
       _isInitiator = isInitiator {
    // Validate remote static key
    if (remoteStaticPublicKey.length != 32) {
      throw ArgumentError('remoteStaticPublicKey must be 32 bytes');
    }

    // Set our static key
    _localStatic.setPrivateKey(localStaticPrivateKey);

    // Set remote static key (pre-shared)
    _remoteStatic.setPublicKey(remoteStaticPublicKey);

    // Generate ephemeral key pair
    _localEphemeral.generateKeyPair();

    // KK pattern: Mix both static public keys into handshake hash
    _symmetricState.mixHash(_localStatic.getPublicKey()!);
    _symmetricState.mixHash(remoteStaticPublicKey);
  }

  /// Start handshake (initiator only)
  ///
  /// Generates Message 1: → e, es, ss
  ///
  /// Returns 96-byte message:
  /// - 32 bytes: ephemeral public key
  /// - 32 bytes: encrypted payload 1 (es applied)
  /// - 32 bytes: encrypted payload 2 (ss applied)
  ///
  /// KK pattern message 1 performs DH operations:
  /// - es: DH(e, rs) - ephemeral to remote static
  /// - ss: DH(s, rs) - static to remote static
  Future<Uint8List> writeMessageA() async {
    if (!_isInitiator) {
      throw StateError('Only initiator can send message A');
    }
    if (_messageIndex != 0) {
      throw StateError('Message A already sent');
    }

    final buffer = <int>[];

    // Write e (our ephemeral public key)
    final ephemeralPublic = _localEphemeral.getPublicKey()!;
    buffer.addAll(ephemeralPublic);
    _symmetricState.mixHash(ephemeralPublic);

    // Perform es: DH(e, rs) - our ephemeral to their static
    final dhES = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteStatic.getPublicKey()!,
    );
    _symmetricState.mixKey(dhES);

    // Perform ss: DH(s, rs) - our static to their static
    final dhSS = DHState.calculate(
      _localStatic.getPrivateKey()!,
      _remoteStatic.getPublicKey()!,
    );
    _symmetricState.mixKey(dhSS);

    // Encrypt empty payload (demonstrates authentication)
    final encrypted = await _symmetricState.encryptAndHash(Uint8List(0));
    buffer.addAll(encrypted);

    _messageIndex = 1;
    return Uint8List.fromList(buffer);
  }

  /// Process message A (responder only)
  ///
  /// Receives Message 1: ← e, es, ss
  ///
  /// [message] 96-byte message
  ///
  /// Processes initiator's ephemeral key and verifies authentication.
  Future<void> readMessageA(Uint8List message) async {
    if (_isInitiator) {
      throw StateError('Initiator cannot read message A');
    }
    if (_messageIndex != 0) {
      throw StateError('Message A already processed');
    }
    if (message.length < 32) {
      throw ArgumentError(
        'Message A must be at least 32 bytes (got ${message.length})',
      );
    }

    int offset = 0;

    // Read re (remote ephemeral)
    final remoteEphemeral = message.sublist(offset, offset + 32);
    offset += 32;
    _remoteEphemeral = DHState();
    _remoteEphemeral!.setPublicKey(remoteEphemeral);
    _symmetricState.mixHash(remoteEphemeral);

    // Perform es: DH(e, rs) - their ephemeral to our static
    // Note: responder uses their ephemeral, initiator's is remote
    final dhES = DHState.calculate(
      _localStatic.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhES);

    // Perform ss: DH(s, rs) - our static to their static
    final dhSS = DHState.calculate(
      _localStatic.getPrivateKey()!,
      _remoteStatic.getPublicKey()!,
    );
    _symmetricState.mixKey(dhSS);

    // Decrypt and verify payload
    try {
      final payload = message.sublist(offset);
      await _symmetricState.decryptAndHash(payload);
      // Payload verification success means authentication succeeded
    } catch (e) {
      // Crypto failure: Peer likely has wrong key or we have wrong key
      throw NoiseHandshakeException(
        'KK handshake authentication failed: Peer may have wrong static key',
        reason: HandshakeFailureReason.cryptoFailure,
        cause: e is Exception ? e : Exception(e.toString()),
      );
    }

    _messageIndex = 1;
  }

  /// Write message B (responder only)
  ///
  /// Generates Message 2: ← e, ee, se
  ///
  /// Returns 48-byte message:
  /// - 32 bytes: ephemeral public key
  /// - 16 bytes: encrypted empty payload (MAC only)
  ///
  /// KK pattern message 2 performs DH operations:
  /// - ee: DH(e, re) - ephemeral to remote ephemeral
  /// - se: DH(s, re) - static to remote ephemeral
  Future<Uint8List> writeMessageB() async {
    if (_isInitiator) {
      throw StateError('Initiator cannot send message B');
    }
    if (_messageIndex != 1) {
      throw StateError('Invalid state for message B');
    }

    final buffer = <int>[];

    // Write e (our ephemeral public key)
    final ephemeralPublic = _localEphemeral.getPublicKey()!;
    buffer.addAll(ephemeralPublic);
    _symmetricState.mixHash(ephemeralPublic);

    // Perform ee: DH(e, re) - our ephemeral to their ephemeral
    final dhEE = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhEE);

    // Perform se: DH(s, re) - our static to their ephemeral
    final dhSE = DHState.calculate(
      _localStatic.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhSE);

    // Encrypt empty payload (demonstrates authentication)
    final encrypted = await _symmetricState.encryptAndHash(Uint8List(0));
    buffer.addAll(encrypted);

    _messageIndex = 2;
    _isComplete = true;

    return Uint8List.fromList(buffer);
  }

  /// Read message B (initiator only)
  ///
  /// Receives Message 2: ← e, ee, se
  ///
  /// [message] 48-byte message
  ///
  /// Processes responder's ephemeral key and completes handshake.
  Future<void> readMessageB(Uint8List message) async {
    if (!_isInitiator) {
      throw StateError('Responder cannot read message B');
    }
    if (_messageIndex != 1) {
      throw StateError('Invalid state for message B');
    }
    if (message.length < 32) {
      throw ArgumentError(
        'Message B must be at least 32 bytes (got ${message.length})',
      );
    }

    int offset = 0;

    // Read re (remote ephemeral)
    final remoteEphemeral = message.sublist(offset, offset + 32);
    offset += 32;
    _remoteEphemeral = DHState();
    _remoteEphemeral!.setPublicKey(remoteEphemeral);
    _symmetricState.mixHash(remoteEphemeral);

    // Perform ee: DH(e, re) - our ephemeral to their ephemeral
    final dhEE = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhEE);

    // Perform se: DH(e, rs) - our ephemeral to their static
    // Note: initiator uses their ephemeral, responder's static
    final dhSE = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteStatic.getPublicKey()!,
    );
    _symmetricState.mixKey(dhSE);

    // Decrypt and verify payload
    try {
      final payload = message.sublist(offset);
      await _symmetricState.decryptAndHash(payload);
      // Payload verification success means handshake complete
    } catch (e) {
      // Crypto failure: We likely have wrong static key for peer
      throw NoiseHandshakeException(
        'KK handshake completion failed: We may have wrong static key for peer',
        reason: HandshakeFailureReason.cryptoFailure,
        cause: e is Exception ? e : Exception(e.toString()),
      );
    }

    _messageIndex = 2;
    _isComplete = true;
  }

  /// Split into transport ciphers
  ///
  /// Called after handshake completion.
  /// Returns (sendCipher, receiveCipher) based on role.
  (CipherState, CipherState) split() {
    if (!_isComplete) {
      throw StateError('Cannot split before handshake complete');
    }

    final (cipher1, cipher2) = _symmetricState.split();

    // Initiator: cipher1 = send, cipher2 = receive
    // Responder: cipher1 = receive, cipher2 = send
    return _isInitiator ? (cipher1, cipher2) : (cipher2, cipher1);
  }

  /// Get handshake hash for channel binding
  ///
  /// Returns 32-byte handshake hash.
  Uint8List getHandshakeHash() {
    return _symmetricState.getHandshakeHash();
  }

  /// Get remote static public key
  ///
  /// For KK pattern, this is known at construction.
  Uint8List getRemoteStaticPublicKey() {
    return _remoteStatic.getPublicKey()!;
  }

  /// Check if handshake is complete
  bool isComplete() {
    return _isComplete;
  }

  /// Get current message index
  int getMessageIndex() {
    return _messageIndex;
  }

  /// Clear sensitive data
  void destroy() {
    _localStatic.destroy();
    _localEphemeral.destroy();
    _remoteStatic.destroy();
    _remoteEphemeral?.destroy();
    _symmetricState.destroy();
  }
}
