/// High-level Noise encryption service
/// 
/// Ports NoiseEncryptionService.kt from bitchat-android.
/// Manages identity, sessions, and provides simple API.
/// 
/// Reference: bitchat-android/noise/NoiseEncryptionService.kt (496 lines)
library;

import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'primitives/dh_state.dart';
import 'models/noise_models.dart';
import 'noise_session.dart';
import 'noise_session_manager.dart';

/// Main Noise encryption service
/// 
/// 100% compatible with bitchat-android implementation.
/// Manages static identity keys, sessions, and provides simple encrypt/decrypt API.
class NoiseEncryptionService {
  static final _logger = Logger('NoiseEncryptionService');
  
  // Secure storage keys
  static const String _keyStaticPrivate = 'noise_static_private';
  static const String _keyStaticPublic = 'noise_static_public';
  
  /// Secure storage for persistent keys
  final FlutterSecureStorage _secureStorage;
  
  /// Static identity keys (persistent across app restarts)
  late final Uint8List _staticIdentityPrivateKey;
  late final Uint8List _staticIdentityPublicKey;
  
  /// Session manager
  late final NoiseSessionManager _sessionManager;
  
  /// Initialization complete flag
  bool _initialized = false;
  
  /// Callbacks
  void Function(String peerID, String fingerprint)? onPeerAuthenticated;
  void Function(String peerID)? onHandshakeRequired;

  NoiseEncryptionService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  // ========== INITIALIZATION ==========

  /// Initialize service
  /// 
  /// Loads or generates static identity keys.
  /// Must be called before using any other methods.
  Future<void> initialize() async {
    if (_initialized) {
      _logger.warning('Already initialized');
      return;
    }

    _logger.info('Initializing Noise encryption service');
    
    // Load or generate static identity key
    await _loadOrGenerateStaticKey();
    
    // Initialize session manager
    _sessionManager = NoiseSessionManager(
      localStaticPrivateKey: _staticIdentityPrivateKey,
      localStaticPublicKey: _staticIdentityPublicKey,
    );
    
    // Set up callbacks
    _sessionManager.onSessionEstablished = _handleSessionEstablished;
    _sessionManager.onSessionFailed = _handleSessionFailed;
    
    _initialized = true;
    _logger.info('Noise encryption service initialized');
    _logger.info('Our fingerprint: ${getIdentityFingerprint()}');
  }

  /// Load or generate static identity key
  Future<void> _loadOrGenerateStaticKey() async {
    // Try to load existing key
    final privateKeyStr = await _secureStorage.read(key: _keyStaticPrivate);
    final publicKeyStr = await _secureStorage.read(key: _keyStaticPublic);
    
    if (privateKeyStr != null && publicKeyStr != null) {
      // Load existing keys
      _staticIdentityPrivateKey = _hexToBytes(privateKeyStr);
      _staticIdentityPublicKey = _hexToBytes(publicKeyStr);
      _logger.info('Loaded existing static identity key');
    } else {
      // Generate new key pair
      final dhState = DHState();
      dhState.generateKeyPair();
      
      _staticIdentityPrivateKey = dhState.getPrivateKey()!;
      _staticIdentityPublicKey = dhState.getPublicKey()!;
      
      // Save to secure storage
      await _secureStorage.write(
        key: _keyStaticPrivate,
        value: _bytesToHex(_staticIdentityPrivateKey),
      );
      await _secureStorage.write(
        key: _keyStaticPublic,
        value: _bytesToHex(_staticIdentityPublicKey),
      );
      
      dhState.destroy();
      _logger.info('Generated and saved new static identity key');
    }
  }

  /// Ensure service is initialized
  void _checkInitialized() {
    if (!_initialized) {
      throw StateError('NoiseEncryptionService not initialized - call initialize() first');
    }
  }

  // ========== PUBLIC INTERFACE ==========

  /// Get our static public key (32 bytes)
  Uint8List getStaticPublicKeyData() {
    _checkInitialized();
    return Uint8List.fromList(_staticIdentityPublicKey);
  }

  /// Get our identity fingerprint
  /// 
  /// Returns SHA-256 hash of static public key as hex string.
  /// Matches bitchat calculateFingerprint().
  String getIdentityFingerprint() {
    _checkInitialized();
    final digest = sha256.convert(_staticIdentityPublicKey);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  /// Get peer's public key (if session established)
  Uint8List? getPeerPublicKeyData(String peerID) {
    _checkInitialized();
    return _sessionManager.getRemoteStaticKey(peerID);
  }

  /// Calculate fingerprint for public key
  /// 
  /// [publicKey] 32-byte public key
  /// Returns SHA-256 hash as hex string
  static String calculateFingerprint(Uint8List publicKey) {
    final digest = sha256.convert(publicKey);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }

  // ========== HANDSHAKE MANAGEMENT ==========

  /// Initiate handshake with peer
  /// 
  /// [peerID] Peer identifier
  /// [pattern] Noise pattern to use (defaults to XX for first-time contacts)
  /// [remoteStaticPublicKey] Remote's static public key (REQUIRED for KK pattern)
  /// 
  /// For XX pattern: Returns first handshake message (32 bytes)
  /// For KK pattern: Returns first handshake message (96 bytes)
  Future<Uint8List?> initiateHandshake(
    String peerID, {
    NoisePattern pattern = NoisePattern.xx,
    Uint8List? remoteStaticPublicKey,
  }) async {
    _checkInitialized();
    
    try {
      return await _sessionManager.initiateHandshake(
        peerID,
        pattern: pattern,
        remoteStaticPublicKey: remoteStaticPublicKey,
      );
    } catch (e) {
      _logger.severe('Failed to initiate ${pattern.name.toUpperCase()} handshake with $peerID: $e');
      return null;
    }
  }

  /// Process incoming handshake message
  /// 
  /// [data] Handshake message bytes
  /// [peerID] Peer identifier
  /// Returns response message if needed, null if complete/failed
  Future<Uint8List?> processHandshakeMessage(Uint8List data, String peerID) async {
    _checkInitialized();
    
    try {
      return await _sessionManager.processHandshakeMessage(peerID, data);
    } catch (e) {
      _logger.severe('Failed to process handshake from $peerID: $e');
      return null;
    }
  }

  /// Check if session established with peer
  bool hasEstablishedSession(String peerID) {
    _checkInitialized();
    return _sessionManager.hasEstablishedSession(peerID);
  }

  /// Get session state for peer
  NoiseSessionState getSessionState(String peerID) {
    _checkInitialized();
    return _sessionManager.getSessionState(peerID);
  }

  // ========== ENCRYPTION / DECRYPTION ==========

  /// Encrypt data for peer
  /// 
  /// Requires established session.
  /// 
  /// [data] Plaintext bytes
  /// [peerID] Peer identifier
  /// Returns encrypted bytes with nonce, null if session not ready
  Future<Uint8List?> encrypt(Uint8List data, String peerID) async {
    _checkInitialized();
    
    if (!hasEstablishedSession(peerID)) {
      _logger.warning('No established session with $peerID - handshake required');
      onHandshakeRequired?.call(peerID);
      return null;
    }
    
    try {
      return await _sessionManager.encrypt(data, peerID);
    } catch (e) {
      _logger.severe('Failed to encrypt for $peerID: $e');
      return null;
    }
  }

  /// Decrypt data from peer
  /// 
  /// Requires established session.
  /// 
  /// [encryptedData] Ciphertext bytes with nonce
  /// [peerID] Peer identifier
  /// Returns plaintext bytes, null if session not ready or decryption failed
  Future<Uint8List?> decrypt(Uint8List encryptedData, String peerID) async {
    _checkInitialized();
    
    if (!hasEstablishedSession(peerID)) {
      _logger.warning('No established session with $peerID when trying to decrypt');
      return null;
    }
    
    try {
      return await _sessionManager.decrypt(encryptedData, peerID);
    } catch (e) {
      _logger.severe('Failed to decrypt from $peerID: $e');
      return null;
    }
  }

  // ========== SESSION MANAGEMENT ==========

  /// Check sessions and trigger rekey if needed
  /// 
  /// Returns list of peer IDs that need rekeying.
  List<String> checkForRekeyNeeded() {
    _checkInitialized();
    return _sessionManager.getSessionsNeedingRekey();
  }

  /// Remove session for peer
  /// 
  /// Useful for forcing rekey or cleanup.
  void removeSession(String peerID) {
    _checkInitialized();
    _sessionManager.removeSession(peerID);
  }

  /// Clear all sessions (for testing)
  void clearAllSessions() {
    _checkInitialized();
    _sessionManager.clearAllSessions();
  }

  /// Get all session statistics
  Map<String, Map<String, dynamic>> getAllSessionStats() {
    _checkInitialized();
    return _sessionManager.getAllStats();
  }

  // ========== CALLBACKS ==========

  void _handleSessionEstablished(String peerID, Uint8List remoteStaticKey) {
    final fingerprint = calculateFingerprint(remoteStaticKey);
    _logger.info('Session established with $peerID (fingerprint: $fingerprint)');
    onPeerAuthenticated?.call(peerID, fingerprint);
  }

  void _handleSessionFailed(String peerID, Exception error) {
    _logger.severe('Session failed with $peerID: $error');
  }

  // ========== CLEANUP ==========

  /// Clear persistent identity (DANGEROUS - for panic mode only)
  /// 
  /// Deletes static keys from secure storage.
  /// Service must be re-initialized after this.
  Future<void> clearPersistentIdentity() async {
    _logger.warning('Clearing persistent identity!');
    
    await _secureStorage.delete(key: _keyStaticPrivate);
    await _secureStorage.delete(key: _keyStaticPublic);
    
    _initialized = false;
  }

  /// Shutdown service
  /// 
  /// Destroys all sessions and clears memory.
  void shutdown() {
    if (_initialized) {
      _logger.info('Shutting down Noise encryption service');
      _sessionManager.shutdown();
      _initialized = false;
    }
  }

  // ========== UTILITIES ==========

  /// Convert hex string to bytes
  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// Convert bytes to hex string
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
  }
}
