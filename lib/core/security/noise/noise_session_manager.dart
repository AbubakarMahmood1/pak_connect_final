/// Noise session manager for multiple peers
/// 
/// Ports NoiseSessionManager.kt from bitchat-android.
/// Manages sessions for multiple peers with lifecycle handling.
/// 
/// Reference: bitchat-android/noise/NoiseSessionManager.kt (227 lines)
library;

import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'models/noise_models.dart';
import 'noise_session.dart';

/// Callback when session is established
typedef SessionEstablishedCallback = void Function(String peerID, Uint8List remoteStaticKey);

/// Callback when session fails
typedef SessionFailedCallback = void Function(String peerID, Exception error);

/// Manager for multiple Noise sessions
/// 
/// Tracks one session per peer, handles handshake initiation/response.
class NoiseSessionManager {
  static final _logger = Logger('NoiseSessionManager');
  
  /// Our static private key (32 bytes)
  final Uint8List _localStaticPrivateKey;
  
  /// Our static public key (32 bytes)
  final Uint8List _localStaticPublicKey;
  
  /// Active sessions: peerID → NoiseSession
  final Map<String, NoiseSession> _sessions = {};
  
  /// Callbacks
  SessionEstablishedCallback? onSessionEstablished;
  SessionFailedCallback? onSessionFailed;

  /// Create session manager
  /// 
  /// [localStaticPrivateKey] Our 32-byte static private key
  /// [localStaticPublicKey] Our 32-byte static public key
  NoiseSessionManager({
    required Uint8List localStaticPrivateKey,
    required Uint8List localStaticPublicKey,
  })  : _localStaticPrivateKey = Uint8List.fromList(localStaticPrivateKey),
        _localStaticPublicKey = Uint8List.fromList(localStaticPublicKey);

  // ========== SESSION MANAGEMENT ==========

  /// Add new session for a peer
  void addSession(String peerID, NoiseSession session) {
    _sessions[peerID] = session;
    _logger.fine('Added session for $peerID');
  }

  /// Get existing session for a peer
  NoiseSession? getSession(String peerID) {
    return _sessions[peerID];
  }

  /// Remove session for a peer
  void removeSession(String peerID) {
    final session = _sessions.remove(peerID);
    session?.destroy();
    _logger.fine('Removed session for $peerID');
  }

  /// Remove all sessions (for testing)
  void clearAllSessions() {
    for (var session in _sessions.values) {
      session.destroy();
    }
    _sessions.clear();
    _logger.fine('Cleared all sessions');
  }

  /// Check if session exists and is established
  bool hasEstablishedSession(String peerID) {
    final session = _sessions[peerID];
    return session != null && session.isEstablished();
  }

  // ========== HANDSHAKE METHODS ==========

  /// Initiate handshake with peer
  /// 
  /// Creates new session as initiator and returns first message.
  /// Removes any existing session first.
  /// 
  /// [peerID] Peer identifier
  /// [pattern] Noise pattern to use (defaults to XX)
  /// [remoteStaticPublicKey] Remote's static public key (REQUIRED for KK pattern)
  /// 
  /// For XX pattern: Returns Message 1 (32 bytes)
  /// For KK pattern: Returns Message 1 (96 bytes)
  Future<Uint8List> initiateHandshake(
    String peerID, {
    NoisePattern pattern = NoisePattern.xx,
    Uint8List? remoteStaticPublicKey,
  }) async {
    _logger.info('Initiating ${pattern.name.toUpperCase()} handshake with $peerID');
    
    // Validate KK requirements
    if (pattern == NoisePattern.kk && remoteStaticPublicKey == null) {
      throw ArgumentError('KK pattern requires remoteStaticPublicKey');
    }
    
    // Remove any existing session
    removeSession(peerID);
    
    // Create new session as initiator
    final session = NoiseSession(
      peerID: peerID,
      isInitiator: true,
      pattern: pattern,
      localStaticPrivateKey: _localStaticPrivateKey,
      localStaticPublicKey: _localStaticPublicKey,
      remoteStaticPublicKey: remoteStaticPublicKey,
    );
    
    addSession(peerID, session);
    
    try {
      final message = await session.startHandshake();
      _logger.info('Started ${pattern.name.toUpperCase()} handshake with $peerID as INITIATOR');
      return message;
    } catch (e) {
      _logger.severe('Failed to start handshake with $peerID: $e');
      removeSession(peerID);
      rethrow;
    }
  }

  /// Process incoming handshake message
  /// 
  /// Creates responder session if needed, processes message.
  /// Returns response message if needed, null if complete.
  /// 
  /// [peerID] Peer identifier
  /// [message] Handshake message bytes
  Future<Uint8List?> processHandshakeMessage(
    String peerID,
    Uint8List message,
  ) async {
    _logger.fine('Processing handshake message from $peerID (${message.length} bytes)');
    
    try {
      var session = getSession(peerID);
      
      // Create responder session if needed
      if (session == null) {
        _logger.info('Creating new RESPONDER session for $peerID');
        
        session = NoiseSession(
          peerID: peerID,
          isInitiator: false,
          localStaticPrivateKey: _localStaticPrivateKey,
          localStaticPublicKey: _localStaticPublicKey,
        );
        
        addSession(peerID, session);
      }
      
      // Process message
      final response = await session.processHandshakeMessage(message);
      
      // Check if session established
      if (session.isEstablished()) {
        _logger.info('✅ Session ESTABLISHED with $peerID');
        
        final remoteStaticKey = session.getRemoteStaticPublicKey();
        if (remoteStaticKey != null) {
          onSessionEstablished?.call(peerID, remoteStaticKey);
        }
      }
      
      return response;
      
    } catch (e) {
      _logger.severe('Handshake failed with $peerID: $e');
      removeSession(peerID);
      
      if (e is Exception) {
        onSessionFailed?.call(peerID, e);
      } else {
        onSessionFailed?.call(peerID, Exception(e.toString()));
      }
      
      rethrow;
    }
  }

  // ========== TRANSPORT ENCRYPTION ==========

  /// Encrypt data for peer
  /// 
  /// [data] Plaintext bytes
  /// [peerID] Peer identifier
  /// Returns encrypted bytes with nonce
  Future<Uint8List> encrypt(Uint8List data, String peerID) async {
    final session = getSession(peerID);
    
    if (session == null) {
      throw StateError('No session found for $peerID');
    }
    
    if (!session.isEstablished()) {
      throw StateError('Session not established with $peerID');
    }
    
    return session.encrypt(data);
  }

  /// Decrypt data from peer
  /// 
  /// [encryptedData] Ciphertext bytes with nonce
  /// [peerID] Peer identifier
  /// Returns plaintext bytes
  Future<Uint8List> decrypt(Uint8List encryptedData, String peerID) async {
    final session = getSession(peerID);
    
    if (session == null) {
      _logger.severe('No session found for $peerID when trying to decrypt');
      throw StateError('No session found for $peerID');
    }
    
    if (!session.isEstablished()) {
      _logger.severe('Session not established with $peerID when trying to decrypt');
      throw StateError('Session not established with $peerID');
    }
    
    return session.decrypt(encryptedData);
  }

  // ========== SESSION QUERIES ==========

  /// Get session state for peer
  NoiseSessionState getSessionState(String peerID) {
    return getSession(peerID)?.getState() ?? NoiseSessionState.uninitialized;
  }

  /// Get remote static key for peer
  Uint8List? getRemoteStaticKey(String peerID) {
    return getSession(peerID)?.getRemoteStaticPublicKey();
  }

  /// Get handshake hash for peer
  Uint8List? getHandshakeHash(String peerID) {
    return getSession(peerID)?.getHandshakeHash();
  }

  /// Get sessions needing rekey
  List<String> getSessionsNeedingRekey() {
    return _sessions.entries
        .where((entry) => entry.value.isEstablished() && entry.value.needsRekey())
        .map((entry) => entry.key)
        .toList();
  }

  /// Get number of active sessions
  int getActiveSessionCount() => _sessions.length;

  /// Get all session statistics
  Map<String, Map<String, dynamic>> getAllStats() {
    return Map.fromEntries(
      _sessions.entries.map((e) => MapEntry(e.key, e.value.getStats())),
    );
  }

  // ========== CLEANUP ==========

  /// Shutdown manager and destroy all sessions
  void shutdown() {
    _logger.info('Shutting down Noise session manager');
    
    for (final session in _sessions.values) {
      session.destroy();
    }
    
    _sessions.clear();
    _logger.info('All sessions destroyed');
  }

  /// Get debug information
  String getDebugInfo() {
    final buffer = StringBuffer();
    buffer.writeln('=== Noise Session Manager Debug ===');
    buffer.writeln('Active sessions: ${_sessions.length}');
    buffer.writeln('');
    
    if (_sessions.isNotEmpty) {
      buffer.writeln('Sessions:');
      for (final entry in _sessions.entries) {
        final stats = entry.value.getStats();
        buffer.writeln('  ${entry.key}: ${stats['state']} '
            '(sent: ${stats['messagesSent']}, received: ${stats['messagesReceived']})');
      }
    }
    
    return buffer.toString();
  }
}
