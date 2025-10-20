/// Handshake state machine for Noise Protocol XX pattern
/// 
/// Ports the HandshakeState interface from bitchat-android's noise-java library.
/// Implements the XX pattern: → e, ← e ee s es, → s se
/// 
/// Reference: bitchat-android/noise/southernstorm/protocol/HandshakeState.java
library;

import 'dart:typed_data';
import 'dh_state.dart';
import 'symmetric_state.dart';
import 'cipher_state.dart';

/// Handshake state for XX pattern
/// 
/// XX pattern provides mutual authentication with identity hiding.
/// Three-message handshake exchanges ephemeral and static keys.
class HandshakeState {
  /// Protocol name for XX pattern
  static const String protocolName = 'Noise_XX_25519_ChaChaPoly_SHA256';
  
  /// Symmetric state for key derivation
  final SymmetricState _symmetricState;
  
  /// Local static key pair
  final DHState _localStatic;
  
  /// Local ephemeral key pair
  final DHState _localEphemeral;
  
  /// Remote static public key (set during handshake)
  DHState? _remoteStatic;
  
  /// Remote ephemeral public key (set during handshake)
  DHState? _remoteEphemeral;
  
  /// True if we initiated the handshake
  final bool _isInitiator;
  
  /// Current message index in handshake (0, 1, or 2)
  int _messageIndex = 0;
  
  /// Handshake complete flag
  bool _isComplete = false;

  /// Create handshake state for XX pattern
  /// 
  /// [localStaticPrivateKey] Our 32-byte static private key
  /// [isInitiator] True if we're initiating, false if responding
  HandshakeState({
    required Uint8List localStaticPrivateKey,
    required bool isInitiator,
  })  : _symmetricState = SymmetricState(protocolName),
        _localStatic = DHState(),
        _localEphemeral = DHState(),
        _isInitiator = isInitiator {
    
    // Set our static key
    _localStatic.setPrivateKey(localStaticPrivateKey);
    
    // Generate ephemeral key pair
    _localEphemeral.generateKeyPair();
  }

  /// Start handshake (initiator only)
  /// 
  /// Generates Message 1: → e (send ephemeral public key)
  /// 
  /// Returns 32-byte message containing ephemeral key
  /// 
  /// Matches HandshakeState.writeMessage() for initiator message 1.
  Future<Uint8List> writeMessageA() async {
    if (!_isInitiator) {
      throw StateError('Only initiator can send message A');
    }
    if (_messageIndex != 0) {
      throw StateError('Message A already sent');
    }

    // Message 1: → e
    final message = Uint8List(32);
    
    // Write ephemeral public key
    final ephemeralPublic = _localEphemeral.getPublicKey()!;
    message.setAll(0, ephemeralPublic);
    
    // Mix hash: h = HASH(h || e)
    _symmetricState.mixHash(ephemeralPublic);
    
    _messageIndex = 1;
    return message;
  }

  /// Process message A (responder only)
  /// 
  /// Receives Message 1: ← e (receive ephemeral public key)
  /// 
  /// [message] 32-byte message containing remote ephemeral key
  /// 
  /// Matches HandshakeState.readMessage() for responder message 1.
  Future<void> readMessageA(Uint8List message) async {
    if (_isInitiator) {
      throw StateError('Initiator cannot read message A');
    }
    if (_messageIndex != 0) {
      throw StateError('Message A already processed');
    }
    if (message.length != 32) {
      throw ArgumentError('Message A must be 32 bytes');
    }

    // Read remote ephemeral key
    _remoteEphemeral = DHState();
    _remoteEphemeral!.setPublicKey(message);
    
    // Mix hash: h = HASH(h || re)
    _symmetricState.mixHash(message);
    
    _messageIndex = 1;
  }

  /// Write message B (responder only)
  /// 
  /// Generates Message 2: ← e, ee, s, es
  /// 
  /// Returns 96-byte message (32 ephemeral + 48 encrypted static + 16 MAC)
  /// 
  /// Matches HandshakeState.writeMessage() for responder message 2.
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
    
    // Perform ee: DH(e, re)
    final dhEE = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhEE);
    
    // Write s (our static public key, encrypted)
    final staticPublic = _localStatic.getPublicKey()!;
    final encryptedStatic = await _symmetricState.encryptAndHash(staticPublic);
    buffer.addAll(encryptedStatic);
    
    // Perform es: DH(s, re)
    final dhES = DHState.calculate(
      _localStatic.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhES);
    
    _messageIndex = 2;
    return Uint8List.fromList(buffer);
  }

  /// Read message B (initiator only)
  /// 
  /// Receives Message 2: ← e, ee, s, es
  /// 
  /// [message] 96-byte message
  /// Returns remote static public key (32 bytes)
  /// 
  /// Matches HandshakeState.readMessage() for initiator message 2.
  Future<Uint8List> readMessageB(Uint8List message) async {
    if (!_isInitiator) {
      throw StateError('Responder cannot read message B');
    }
    if (_messageIndex != 1) {
      throw StateError('Invalid state for message B');
    }
    if (message.length != 80) {
      throw ArgumentError('Message B must be 80 bytes (got ${message.length})');
    }

    int offset = 0;
    
    // Read re (remote ephemeral)
    final remoteEphemeral = message.sublist(offset, offset + 32);
    offset += 32;
    _remoteEphemeral = DHState();
    _remoteEphemeral!.setPublicKey(remoteEphemeral);
    _symmetricState.mixHash(remoteEphemeral);
    
    // Perform ee: DH(e, re)
    final dhEE = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhEE);
    
    // Read rs (remote static, encrypted)
    final encryptedStatic = message.sublist(offset);
    final remoteStatic = await _symmetricState.decryptAndHash(encryptedStatic);
    _remoteStatic = DHState();
    _remoteStatic!.setPublicKey(remoteStatic);
    
    // Perform es: DH(e, rs)
    final dhES = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteStatic!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhES);
    
    _messageIndex = 2;
    return remoteStatic;
  }

  /// Write message C (initiator only)
  /// 
  /// Generates Message 3: → s, se
  /// 
  /// Returns 48-byte message (48 encrypted static)
  /// 
  /// Matches HandshakeState.writeMessage() for initiator message 3.
  Future<Uint8List> writeMessageC() async {
    if (!_isInitiator) {
      throw StateError('Responder cannot send message C');
    }
    if (_messageIndex != 2) {
      throw StateError('Invalid state for message C');
    }

    // Write s (our static public key, encrypted)
    final staticPublic = _localStatic.getPublicKey()!;
    final encryptedStatic = await _symmetricState.encryptAndHash(staticPublic);
    
    // Perform se: DH(s, re)
    final dhSE = DHState.calculate(
      _localStatic.getPrivateKey()!,
      _remoteEphemeral!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhSE);
    
    _messageIndex = 3;
    _isComplete = true;
    
    return encryptedStatic;
  }

  /// Read message C (responder only)
  /// 
  /// Receives Message 3: ← s, se
  /// 
  /// [message] 48-byte message
  /// Returns remote static public key (32 bytes)
  /// 
  /// Matches HandshakeState.readMessage() for responder message 3.
  Future<Uint8List> readMessageC(Uint8List message) async {
    if (_isInitiator) {
      throw StateError('Initiator cannot read message C');
    }
    if (_messageIndex != 2) {
      throw StateError('Invalid state for message C');
    }
    if (message.length != 48) {
      throw ArgumentError('Message C must be 48 bytes');
    }

    // Read rs (remote static, encrypted)
    final remoteStatic = await _symmetricState.decryptAndHash(message);
    _remoteStatic = DHState();
    _remoteStatic!.setPublicKey(remoteStatic);
    
    // Perform se: DH(e, rs)  - responder uses ephemeral, not static!
    final dhSE = DHState.calculate(
      _localEphemeral.getPrivateKey()!,
      _remoteStatic!.getPublicKey()!,
    );
    _symmetricState.mixKey(dhSE);
    
    _messageIndex = 3;
    _isComplete = true;
    
    return remoteStatic;
  }

  /// Split into transport ciphers
  /// 
  /// Called after handshake completion.
  /// Returns (sendCipher, receiveCipher) based on role.
  /// 
  /// Matches HandshakeState.split() from noise-java.
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
  /// Can be used for session identification.
  Uint8List getHandshakeHash() {
    return _symmetricState.getHandshakeHash();
  }

  /// Get remote static public key
  /// 
  /// Returns null if not yet received.
  Uint8List? getRemoteStaticPublicKey() {
    return _remoteStatic?.getPublicKey();
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
  /// 
  /// Destroys all key material for forward secrecy.
  void destroy() {
    _localStatic.destroy();
    _localEphemeral.destroy();
    _remoteStatic?.destroy();
    _remoteEphemeral?.destroy();
    _symmetricState.destroy();
  }
}
