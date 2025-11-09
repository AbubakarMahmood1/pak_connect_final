/// Noise Protocol implementation for pak_connect
///
/// Ported from bitchat-android's production-ready Noise Protocol implementation.
/// Provides XX pattern handshake with forward secrecy and replay protection.
///
/// ## Usage
///
/// ```dart
/// // Initialize service
/// final noiseService = NoiseEncryptionService();
/// await noiseService.initialize();
///
/// // Get our fingerprint
/// final myFingerprint = noiseService.getIdentityFingerprint();
///
/// // Initiate handshake
/// final message1 = await noiseService.initiateHandshake(peerID);
///
/// // Process handshake messages
/// final response = await noiseService.processHandshakeMessage(data, peerID);
///
/// // Encrypt after handshake complete
/// final encrypted = await noiseService.encrypt(plaintext, peerID);
///
/// // Decrypt
/// final decrypted = await noiseService.decrypt(encrypted, peerID);
/// ```
library;

// Export main service
export 'noise_encryption_service.dart';

// Export session classes
export 'noise_session.dart';
export 'noise_session_manager.dart';

// Export models
export 'models/noise_models.dart';

// Export exceptions
export 'noise_handshake_exception.dart';

// Export primitives for advanced usage
export 'primitives/dh_state.dart';
export 'primitives/cipher_state.dart';
export 'primitives/symmetric_state.dart';
export 'primitives/handshake_state.dart';
export 'primitives/handshake_state_kk.dart';
