/// Noise Protocol session for a single peer
/// 
/// Ports NoiseSession.kt from bitchat-android.
/// Manages XX handshake, transport encryption, and replay protection.
/// 
/// Reference: bitchat-android/noise/NoiseSession.kt (733 lines)
library;

import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'models/noise_models.dart';
import 'primitives/handshake_state.dart';
import 'primitives/handshake_state_kk.dart';
import 'primitives/cipher_state.dart';

/// Session state enum
enum NoiseSessionState {
  uninitialized,
  handshaking,
  established,
  failed,
}

/// Individual Noise session for a specific peer
/// 
/// 100% compatible with bitchat-android Noise Protocol implementation.
class NoiseSession {
  static final _logger = Logger('NoiseSession');
  
  /// Peer identifier
  final String peerID;
  
  /// True if we initiated the handshake
  final bool isInitiator;
  
  /// Noise pattern to use (XX or KK)
  final NoisePattern pattern;
  
  /// Remote peer's static public key (required for KK pattern)
  final Uint8List? _remoteStaticPublicKeyForKK;
  
  /// Our static private key (32 bytes)
  /// Our static private key (32 bytes) - stored for handshake
  final Uint8List _localStaticPrivateKey;
  
  // Noise Protocol Configuration (matching bitchat-android)
  static const int _rekeyTimeLimit = 3600000; // 1 hour in milliseconds
  static const int _rekeyMessageLimit = 10000; // 10k messages
  
  // XX Pattern Message Sizes (actual sizes, not bitchat-android)
  static const int _xxMessage1Size = 32;      // → e
  static const int _xxMessage2Size = 80;      // ← e, ee, s, es (32 + 48)
  static const int _xxMessage3Size = 48;      // → s, se
  
  // KK Pattern Message Sizes
  static const int _kkMessage1Size = 96;      // → e, es, ss (32 + 32 + 32)
  static const int _kkMessage2Size = 48;      // ← e, ee, se (32 + 16)
  
  // Replay Protection Constants (matching bitchat-android)
  static const int _nonceSizeBytes = 4;
  static const int _replayWindowSize = 1024;
  static const int _replayWindowBytes = _replayWindowSize ~/ 8; // 128 bytes
  
  // State
  NoiseSessionState _state = NoiseSessionState.uninitialized;
  
  // Handshake state (active during handshake)
  // For XX pattern: uses HandshakeState
  // For KK pattern: uses HandshakeStateKK
  HandshakeState? _handshakeState;
  HandshakeStateKK? _handshakeStateKK;
  
  // Transport ciphers (active after handshake)
  CipherState? _sendCipher;
  CipherState? _receiveCipher;
  
  // Remote peer's static public key (set after handshake)
  Uint8List? _remoteStaticPublicKey;
  
  // Handshake hash for channel binding (set after handshake)
  Uint8List? _handshakeHash;
  
  // Session timing
  DateTime? _sessionEstablishedTime;
  
  // Message counters
  int _messagesSent = 0;
  int _messagesReceived = 0;
  
  // Replay protection
  int _highestReceivedNonce = 0;
  final Uint8List _replayWindow = Uint8List(_replayWindowBytes);

  /// Create a new Noise session
  /// 
  /// [peerID] Peer identifier
  /// [isInitiator] True if we initiate handshake
  /// [pattern] Noise pattern to use (xx or kk)
  /// [localStaticPrivateKey] Our 32-byte static private key
  /// [localStaticPublicKey] Our 32-byte static public key (not stored, only private key needed)
  /// [remoteStaticPublicKey] Remote's 32-byte static public key (REQUIRED for KK pattern)
  NoiseSession({
    required this.peerID,
    required this.isInitiator,
    this.pattern = NoisePattern.xx,
    required Uint8List localStaticPrivateKey,
    required Uint8List localStaticPublicKey, // Parameter kept for API compatibility
    Uint8List? remoteStaticPublicKey,
  })  : _localStaticPrivateKey = Uint8List.fromList(localStaticPrivateKey),
        _remoteStaticPublicKeyForKK = remoteStaticPublicKey != null 
            ? Uint8List.fromList(remoteStaticPublicKey)
            : null {
    
    // Validate KK pattern requirements
    if (pattern == NoisePattern.kk && remoteStaticPublicKey == null) {
      throw ArgumentError('KK pattern requires remoteStaticPublicKey parameter');
    }
    if (pattern == NoisePattern.kk && remoteStaticPublicKey!.length != 32) {
      throw ArgumentError('remoteStaticPublicKey must be 32 bytes for KK pattern');
    }
    
    _logger.info('[$peerID] Created ${pattern.name.toUpperCase()} session as ${isInitiator ? "INITIATOR" : "RESPONDER"}');
  }

  // ========== PUBLIC GETTERS ==========

  /// Current session state
  NoiseSessionState get state => _state;

  /// Remote peer's static public key (available after handshake)
  Uint8List? get remoteStaticPublicKey => _remoteStaticPublicKey;

  /// Handshake hash for channel binding (available after handshake)
  Uint8List? get handshakeHash => _handshakeHash;

  // ========== HANDSHAKE METHODS ==========

  /// Start handshake (initiator only)
  /// 
  /// For XX pattern: Returns Message 1 (32 bytes): → e
  /// For KK pattern: Returns Message 1 (96 bytes): → e, es, ss
  Future<Uint8List> startHandshake() async {
    if (!isInitiator) {
      throw StateError('Only initiator can start handshake');
    }
    if (_state != NoiseSessionState.uninitialized) {
      throw StateError('Handshake already started');
    }

    _logger.info('[$peerID] Starting ${pattern.name.toUpperCase()} handshake as INITIATOR');
    _state = NoiseSessionState.handshaking;
    
    if (pattern == NoisePattern.kk) {
      // KK pattern handshake
      _handshakeStateKK = HandshakeStateKK(
        localStaticPrivateKey: _localStaticPrivateKey,
        remoteStaticPublicKey: _remoteStaticPublicKeyForKK!,
        isInitiator: true,
      );
      
      // Generate and send Message 1: → e, es, ss
      final message = await _handshakeStateKK!.writeMessageA();
      _logger.fine('[$peerID] Sent KK message 1 (${message.length} bytes)');
      
      return message;
    } else {
      // XX pattern handshake (original code)
      _handshakeState = HandshakeState(
        localStaticPrivateKey: _localStaticPrivateKey,
        isInitiator: true,
      );
      
      // Generate and send Message 1: → e
      final message = await _handshakeState!.writeMessageA();
      _logger.fine('[$peerID] Sent XX message 1 (${message.length} bytes)');
      
      return message;
    }
  }

  /// Process incoming handshake message
  /// 
  /// Returns response message if needed, null if handshake complete.
  /// Throws on handshake failure.
  Future<Uint8List?> processHandshakeMessage(Uint8List message) async {
    _logger.fine('[$peerID] Processing handshake message (${message.length} bytes)');
    
    try {
      // Route to pattern-specific handler
      if (pattern == NoisePattern.kk) {
        return await _processHandshakeMessageKK(message);
      } else {
        return await _processHandshakeMessageXX(message);
      }
    } catch (e, stackTrace) {
      _logger.severe('[$peerID] Handshake failed: $e', e, stackTrace);
      _state = NoiseSessionState.failed;
      destroy();
      rethrow;
    }
  }
  
  /// Process XX pattern handshake message
  Future<Uint8List?> _processHandshakeMessageXX(Uint8List message) async {
    // Initialize handshake state if needed (responder)
    if (_handshakeState == null) {
      if (isInitiator) {
        throw StateError('Initiator must call startHandshake first');
      }
      
      _logger.info('[$peerID] Starting XX handshake as RESPONDER');
      _state = NoiseSessionState.handshaking;
      
      _handshakeState = HandshakeState(
        localStaticPrivateKey: _localStaticPrivateKey,
        isInitiator: false,
      );
    }

    final messageIndex = _handshakeState!.getMessageIndex();
    
    if (isInitiator) {
      // Initiator receives message 2
      if (messageIndex == 1 && message.length == _xxMessage2Size) {
        _logger.fine('[$peerID] Initiator processing XX message 2');
        final remoteStatic = await _handshakeState!.readMessageB(message);
        _remoteStaticPublicKey = remoteStatic;
        
        // Send message 3
        final response = await _handshakeState!.writeMessageC();
        _logger.fine('[$peerID] Initiator sending XX message 3 (${response.length} bytes)');
        
        // Handshake complete!
        await _completeHandshake();
        return response;
      }
    } else {
      // Responder receives message 1 or 3
      if (messageIndex == 0 && message.length == _xxMessage1Size) {
        _logger.fine('[$peerID] Responder processing XX message 1');
        await _handshakeState!.readMessageA(message);
        
        // Send message 2
        final response = await _handshakeState!.writeMessageB();
        _logger.fine('[$peerID] Responder sending XX message 2 (${response.length} bytes)');
        return response;
        
      } else if (messageIndex == 2 && message.length == _xxMessage3Size) {
        _logger.fine('[$peerID] Responder processing XX message 3');
        final remoteStatic = await _handshakeState!.readMessageC(message);
        _remoteStaticPublicKey = remoteStatic;
        
        // Handshake complete!
        await _completeHandshake();
        return null; // No response needed
      }
    }
    
    throw ArgumentError('Unexpected XX message size or state');
  }
  
  /// Process KK pattern handshake message
  Future<Uint8List?> _processHandshakeMessageKK(Uint8List message) async {
    // Initialize handshake state if needed (responder)
    if (_handshakeStateKK == null) {
      if (isInitiator) {
        throw StateError('Initiator must call startHandshake first');
      }
      
      if (_remoteStaticPublicKeyForKK == null) {
        throw StateError('KK responder requires remote static public key');
      }
      
      _logger.info('[$peerID] Starting KK handshake as RESPONDER');
      _state = NoiseSessionState.handshaking;
      
      _handshakeStateKK = HandshakeStateKK(
        localStaticPrivateKey: _localStaticPrivateKey,
        remoteStaticPublicKey: _remoteStaticPublicKeyForKK,
        isInitiator: false,
      );
    }

    final messageIndex = _handshakeStateKK!.getMessageIndex();
    
    if (isInitiator) {
      // Initiator receives message 2: ← e, ee, se
      if (messageIndex == 1 && message.length == _kkMessage2Size) {
        _logger.fine('[$peerID] Initiator processing KK message 2');
        await _handshakeStateKK!.readMessageB(message);
        
        // Handshake complete! (KK is 2 messages)
        _remoteStaticPublicKey = _remoteStaticPublicKeyForKK;
        await _completeHandshake();
        return null; // No response needed
      }
    } else {
      // Responder receives message 1: → e, es, ss
      if (messageIndex == 0 && message.length == _kkMessage1Size) {
        _logger.fine('[$peerID] Responder processing KK message 1');
        await _handshakeStateKK!.readMessageA(message);
        
        // Send message 2: ← e, ee, se
        final response = await _handshakeStateKK!.writeMessageB();
        _logger.fine('[$peerID] Responder sending KK message 2 (${response.length} bytes)');
        
        // Handshake complete!
        _remoteStaticPublicKey = _remoteStaticPublicKeyForKK;
        await _completeHandshake();
        return response;
      }
    }
    
    throw ArgumentError('Unexpected KK message size or state');
  }

  /// Complete handshake and derive transport keys
  Future<void> _completeHandshake() async {
    _logger.info('[$peerID] ${pattern.name.toUpperCase()} handshake complete!');
    
    if (pattern == NoisePattern.kk) {
      // KK pattern completion
      if (_handshakeStateKK == null) {
        throw StateError('No KK handshake state');
      }
      
      // Get handshake hash for channel binding
      _handshakeHash = _handshakeStateKK!.getHandshakeHash();
      
      // Split into transport ciphers
      final (send, receive) = _handshakeStateKK!.split();
      _sendCipher = send;
      _receiveCipher = receive;
      
      // Clean up handshake state
      _handshakeStateKK!.destroy();
      _handshakeStateKK = null;
      
    } else {
      // XX pattern completion (original code)
      if (_handshakeState == null) {
        throw StateError('No XX handshake state');
      }
      
      // Get handshake hash for channel binding
      _handshakeHash = _handshakeState!.getHandshakeHash();
      
      // Split into transport ciphers
      final (send, receive) = _handshakeState!.split();
      _sendCipher = send;
      _receiveCipher = receive;
      
      // Clean up handshake state
      _handshakeState!.destroy();
      _handshakeState = null;
    }
    
    // Update state (common for both patterns)
    _state = NoiseSessionState.established;
    _sessionEstablishedTime = DateTime.now();
    _messagesSent = 0;
    _messagesReceived = 0;
    
    _logger.info('[$peerID] Session ESTABLISHED - transport ciphers ready');
  }

  // ========== TRANSPORT ENCRYPTION METHODS ==========

  /// Encrypt plaintext for transport
  /// 
  /// Prepends 4-byte nonce to ciphertext for replay protection.
  /// 
  /// [data] Plaintext bytes to encrypt
  /// Returns nonce and ciphertext combined payload
  Future<Uint8List> encrypt(Uint8List data) async {
    if (_state != NoiseSessionState.established) {
      throw StateError('Session not established');
    }
    if (_sendCipher == null) {
      throw StateError('Send cipher not initialized');
    }

    // Get current nonce
    final nonce = _sendCipher!.getNonce();
    
    // Encrypt with empty AD
    final ciphertext = await _sendCipher!.encryptWithAd(null, data);
    
    // Prepend 4-byte nonce (big-endian)
    final combined = Uint8List(_nonceSizeBytes + ciphertext.length);
    _nonceToBytes(nonce, combined);
    combined.setRange(_nonceSizeBytes, combined.length, ciphertext);
    
    _messagesSent++;
    _logger.fine('[$peerID] Encrypted message (nonce: $nonce, size: ${combined.length})');
    
    return combined;
  }

  /// Decrypt ciphertext from transport
  /// 
  /// Extracts and validates 4-byte nonce for replay protection.
  /// 
  /// [combinedPayload] `nonce``ciphertext` combined payload
  /// Returns plaintext bytes
  Future<Uint8List> decrypt(Uint8List combinedPayload) async {
    if (_state != NoiseSessionState.established) {
      throw StateError('Session not established');
    }
    if (_receiveCipher == null) {
      throw StateError('Receive cipher not initialized');
    }
    if (combinedPayload.length < _nonceSizeBytes) {
      throw ArgumentError('Payload too small for nonce');
    }

    // Extract nonce and ciphertext
    final (receivedNonce, ciphertext) = _extractNonceFromPayload(combinedPayload);
    
    // Validate nonce for replay protection
    if (!_isValidNonce(receivedNonce)) {
      throw Exception('Replay attack detected: invalid nonce $receivedNonce');
    }
    
    // Set cipher nonce to match received nonce
    _receiveCipher!.setNonce(receivedNonce);
    
    // Decrypt
    final plaintext = await _receiveCipher!.decryptWithAd(null, ciphertext);
    
    // Mark nonce as seen
    _markNonceAsSeen(receivedNonce);
    
    _messagesReceived++;
    _logger.fine('[$peerID] Decrypted message (nonce: $receivedNonce, size: ${plaintext.length})');
    
    return plaintext;
  }

  // ========== REPLAY PROTECTION METHODS ==========

  /// Check if nonce is valid for replay protection
  bool _isValidNonce(int receivedNonce) {
    // Too old - outside window
    if (receivedNonce + _replayWindowSize <= _highestReceivedNonce) {
      _logger.warning('[$peerID] Nonce too old: $receivedNonce (highest: $_highestReceivedNonce)');
      return false;
    }
    
    // Future nonce - always accept
    if (receivedNonce > _highestReceivedNonce) {
      return true;
    }
    
    // Within window - check if already seen
    final offset = (_highestReceivedNonce - receivedNonce).toInt();
    final byteIndex = offset ~/ 8;
    final bitIndex = offset % 8;
    
    final alreadySeen = (_replayWindow[byteIndex] & (1 << bitIndex)) != 0;
    if (alreadySeen) {
      _logger.warning('[$peerID] Duplicate nonce: $receivedNonce');
    }
    
    return !alreadySeen;
  }

  /// Mark nonce as seen in replay window
  void _markNonceAsSeen(int receivedNonce) {
    if (receivedNonce > _highestReceivedNonce) {
      final shift = (receivedNonce - _highestReceivedNonce).toInt();
      
      if (shift >= _replayWindowSize) {
        // Clear entire window
        _replayWindow.fillRange(0, _replayWindow.length, 0);
      } else {
        // Shift window right by shift bits
        _shiftReplayWindow(shift);
      }
      
      _highestReceivedNonce = receivedNonce;
      _replayWindow[0] = _replayWindow[0] | 1; // Mark most recent bit
      
    } else {
      // Mark bit in existing window
      final offset = (_highestReceivedNonce - receivedNonce).toInt();
      final byteIndex = offset ~/ 8;
      final bitIndex = offset % 8;
      _replayWindow[byteIndex] = _replayWindow[byteIndex] | (1 << bitIndex);
    }
  }

  /// Shift replay window right by shift bits
  void _shiftReplayWindow(int shift) {
    for (int i = _replayWindowBytes - 1; i >= 0; i--) {
      final sourceByteIndex = i - shift ~/ 8;
      int newByte = 0;
      
      if (sourceByteIndex >= 0) {
        newByte = (_replayWindow[sourceByteIndex] & 0xFF) >> (shift % 8);
        if (sourceByteIndex > 0 && shift % 8 != 0) {
          newByte = newByte | ((_replayWindow[sourceByteIndex - 1] & 0xFF) << (8 - shift % 8));
        }
      }
      
      _replayWindow[i] = (newByte & 0xFF);
    }
  }

  /// Extract nonce from combined payload
  (int, Uint8List) _extractNonceFromPayload(Uint8List combinedPayload) {
    // Extract 4-byte nonce (big-endian)
    int nonce = 0;
    for (int i = 0; i < _nonceSizeBytes; i++) {
      nonce = (nonce << 8) | combinedPayload[i];
    }
    
    // Extract ciphertext
    final ciphertext = combinedPayload.sublist(_nonceSizeBytes);
    
    return (nonce, ciphertext);
  }

  /// Convert nonce to 4-byte array (big-endian)
  void _nonceToBytes(int nonce, Uint8List buffer) {
    for (int i = _nonceSizeBytes - 1; i >= 0; i--) {
      buffer[i] = nonce & 0xFF;
      nonce = nonce >> 8;
    }
  }

  // ========== STATE QUERY METHODS ==========

  /// Check if session is established
  bool isEstablished() => _state == NoiseSessionState.established;

  /// Get current session state
  NoiseSessionState getState() => _state;

  /// Get remote static public key (null if handshake not complete)
  Uint8List? getRemoteStaticPublicKey() => _remoteStaticPublicKey;

  /// Get handshake hash (null if handshake not complete)
  Uint8List? getHandshakeHash() => _handshakeHash;

  /// Check if session needs rekeying
  bool needsRekey() {
    if (_state != NoiseSessionState.established || _sessionEstablishedTime == null) {
      return false;
    }
    
    // Time-based rekey
    final elapsed = DateTime.now().difference(_sessionEstablishedTime!).inMilliseconds;
    if (elapsed >= _rekeyTimeLimit) {
      _logger.info('[$peerID] Rekey needed: time limit reached');
      return true;
    }
    
    // Message count-based rekey
    if (_messagesSent >= _rekeyMessageLimit) {
      _logger.info('[$peerID] Rekey needed: message limit reached');
      return true;
    }
    
    return false;
  }

  /// Get session statistics
  Map<String, dynamic> getStats() {
    return {
      'peerID': peerID,
      'state': _state.name,
      'isInitiator': isInitiator,
      'messagesSent': _messagesSent,
      'messagesReceived': _messagesReceived,
      'needsRekey': needsRekey(),
      'sessionAge': _sessionEstablishedTime != null
          ? DateTime.now().difference(_sessionEstablishedTime!).inSeconds
          : 0,
    };
  }

  // ========== CLEANUP ==========

  /// Destroy session and clear sensitive data
  /// 
  /// Wipes all key material for forward secrecy.
  void destroy() {
    _logger.info('[$peerID] Destroying session');
    
    _handshakeState?.destroy();
    _handshakeStateKK?.destroy();
    _sendCipher?.destroy();
    _receiveCipher?.destroy();
    
    _localStaticPrivateKey.fillRange(0, _localStaticPrivateKey.length, 0);
    _remoteStaticPublicKey?.fillRange(0, _remoteStaticPublicKey!.length, 0);
    _remoteStaticPublicKeyForKK?.fillRange(0, _remoteStaticPublicKeyForKK.length, 0);
    _handshakeHash?.fillRange(0, _handshakeHash!.length, 0);
    _replayWindow.fillRange(0, _replayWindow.length, 0);
    
    _state = NoiseSessionState.uninitialized;
  }
}
