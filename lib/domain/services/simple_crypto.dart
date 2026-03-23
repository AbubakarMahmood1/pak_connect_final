import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';
import '../interfaces/i_contact_repository.dart';
import 'contact_crypto_service.dart';
import 'conversation_crypto_service.dart';
import 'legacy_payload_compat_service.dart';
import 'signing_crypto_service.dart';

part 'simple_crypto_verification_helper.dart';

class SimpleCrypto {
  static final _logger = Logger('SimpleCrypto');

  static void _log(Object? message, {Level level = Level.FINE}) {
    _logger.log(level, message);
  }

  /// Initializes the migration-only legacy compatibility decryptor.
  static void initialize() {
    LegacyPayloadCompatService.initialize();
  }

  static Map<String, int> getDeprecatedWrapperUsageCounts() =>
      LegacyPayloadCompatService.getDeprecatedWrapperUsageCounts();

  static void resetDeprecatedWrapperUsageCounts() =>
      LegacyPayloadCompatService.resetDeprecatedWrapperUsageCounts();

  /// Compatibility helper for legacy test fixtures and migration reads only.
  static String encodeLegacyPlaintext(String plaintext) {
    return LegacyPayloadCompatService.encodeLegacyPlaintext(plaintext);
  }

  /// Compatibility helper for legacy inbound payload migration only.
  static String decryptLegacyCompatible(String encryptedBase64) {
    return LegacyPayloadCompatService.decryptLegacyCompatible(encryptedBase64);
  }

  @Deprecated(
    'Use proper encryption methods (Noise, ECDH, or Pairing). '
    'This method does NOT provide real security.',
  )
  static String encrypt(String plaintext) {
    return LegacyPayloadCompatService.encrypt(plaintext);
  }

  @Deprecated('Use proper decryption methods (Noise, ECDH, or Pairing)')
  static String decrypt(String encryptedBase64) {
    return LegacyPayloadCompatService.decrypt(encryptedBase64);
  }

  static bool get isInitialized => LegacyPayloadCompatService.isInitialized;

  static void clear() {
    LegacyPayloadCompatService.clear();
    SigningCryptoService.clear();
  }

  static void initializeConversation(String publicKey, String sharedSecret) {
    ConversationCryptoService.initializeConversation(publicKey, sharedSecret);
  }

  static String encryptForConversation(String plaintext, String publicKey) {
    return ConversationCryptoService.encryptForConversation(
      plaintext,
      publicKey,
    );
  }

  static String decryptFromConversation(
    String encryptedBase64,
    String publicKey,
  ) {
    return ConversationCryptoService.decryptFromConversation(
      encryptedBase64,
      publicKey,
    );
  }

  static bool hasConversationKey(String publicKey) {
    return ConversationCryptoService.hasConversationKey(publicKey);
  }

  static void initializeSigning(String privateKeyHex, String publicKeyHex) {
    SigningCryptoService.initializeSigning(privateKeyHex, publicKeyHex);
  }

  static String? signMessage(String content) {
    return SigningCryptoService.signMessage(content);
  }

  static bool verifySignature(
    String content,
    String signatureHex,
    String senderPublicKeyHex,
  ) {
    return SigningCryptoService.verifySignature(
      content,
      signatureHex,
      senderPublicKeyHex,
    );
  }

  static bool get isSigningReady => SigningCryptoService.isSigningReady;

  static String? computeSharedSecret(String theirPublicKeyHex) {
    return SigningCryptoService.computeSharedSecret(theirPublicKeyHex);
  }

  static Future<String?> encryptForContact(
    String plaintext,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ContactCryptoService.encryptForContact(
    plaintext,
    contactPublicKey,
    contactRepo,
  );

  static Future<String?> decryptFromContact(
    String encryptedBase64,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ContactCryptoService.decryptFromContact(
    encryptedBase64,
    contactPublicKey,
    contactRepo,
  );

  static void clearConversationKey(String publicKey) {
    ConversationCryptoService.clearConversationKey(publicKey);
  }

  static void clearAllConversationKeys() {
    ConversationCryptoService.clearAllConversationKeys();
  }

  static String _deriveEnhancedContactKey(
    String ecdhSecret,
    String contactPublicKey,
  ) => ContactCryptoService.deriveEnhancedContactKey(
    ecdhSecret,
    contactPublicKey,
  );

  static Future<String?> getCachedOrComputeSharedSecret(
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ContactCryptoService.getCachedOrComputeSharedSecret(
    contactPublicKey,
    contactRepo,
  );

  /// Ensure conversation key synchronization to prevent race conditions
  static Future<void> ensureConversationKeySync(
    String publicKey,
    IContactRepository repo,
  ) => ContactCryptoService.ensureConversationKeySync(publicKey, repo);

  static Future<void> restoreConversationKey(
    String publicKey,
    String cachedSecret,
  ) =>
      ConversationCryptoService.restoreConversationKey(publicKey, cachedSecret);

  // === CRYPTO STANDARDS VERIFICATION ===

  /// Comprehensive crypto standards verification
  static Future<Map<String, dynamic>> verifyCryptoStandards(
    String? contactPublicKey,
    IContactRepository? repo,
  ) => _SimpleCryptoVerificationHelper.verifyCryptoStandards(
    contactPublicKey,
    repo,
  );

  /// Test ECDH key generation capability
  static Future<Map<String, dynamic>> _testECDHKeyGeneration() =>
      _SimpleCryptoVerificationHelper.testECDHKeyGeneration();

  /// Test AES encryption/decryption functionality
  static Future<Map<String, dynamic>> _testAESEncryption() =>
      _SimpleCryptoVerificationHelper.testAESEncryption();

  /// Test enhanced key derivation functionality
  static Future<Map<String, dynamic>> _testEnhancedKeyDerivation() =>
      _SimpleCryptoVerificationHelper.testEnhancedKeyDerivation();

  /// Test message signing and verification
  static Future<Map<String, dynamic>> _testMessageSigning() =>
      _SimpleCryptoVerificationHelper.testMessageSigning();

  /// Test key storage and retrieval
  static Future<Map<String, dynamic>> _testKeyStorage(
    String contactPublicKey,
    IContactRepository repo,
  ) => _SimpleCryptoVerificationHelper.testKeyStorage(contactPublicKey, repo);

  /// Test ECDH shared secret computation
  static Future<Map<String, dynamic>> _testECDHSharedSecret(
    String contactPublicKey,
  ) => _SimpleCryptoVerificationHelper.testECDHSharedSecret(contactPublicKey);

  /// Generate a test encrypted message for verification challenge
  static String generateVerificationChallenge() =>
      _SimpleCryptoVerificationHelper.generateVerificationChallenge();

  /// Test bidirectional encryption with a contact
  static Future<Map<String, dynamic>> testBidirectionalEncryption(
    String contactPublicKey,
    IContactRepository repo,
    String testMessage,
  ) => _SimpleCryptoVerificationHelper.testBidirectionalEncryption(
    contactPublicKey,
    repo,
    testMessage,
  );
}
