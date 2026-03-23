import '../interfaces/i_contact_repository.dart';
import 'contact_crypto_service.dart';
import 'conversation_crypto_service.dart';
import 'signing_crypto_service.dart';

/// Canonical convenience facade over the active crypto services.
///
/// Runtime production code should depend on the narrower services directly
/// instead of extending this facade.
class ActiveCryptoFacade {
  /// Kept as a no-op so older tests can continue to call setup hooks safely.
  static void initialize() {}

  /// Deprecated wrapper telemetry always stays at zero because the legacy
  /// wrapper/decrypt lane has been removed.
  static Map<String, int> getDeprecatedWrapperUsageCounts() => const {
    'encrypt': 0,
    'decrypt': 0,
    'total': 0,
  };

  static void resetDeprecatedWrapperUsageCounts() {}

  static bool get isInitialized => false;

  static void clear() {
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
}

/// Backward-compatible wrapper kept for historical tests and imports.
///
/// New code should prefer [ActiveCryptoFacade] so the old `SimpleCrypto` name
/// can eventually disappear without another large rename pass.
class SimpleCrypto {
  static void initialize() => ActiveCryptoFacade.initialize();

  static Map<String, int> getDeprecatedWrapperUsageCounts() =>
      ActiveCryptoFacade.getDeprecatedWrapperUsageCounts();

  static void resetDeprecatedWrapperUsageCounts() =>
      ActiveCryptoFacade.resetDeprecatedWrapperUsageCounts();

  static bool get isInitialized => ActiveCryptoFacade.isInitialized;

  static void clear() => ActiveCryptoFacade.clear();

  static void initializeConversation(String publicKey, String sharedSecret) =>
      ActiveCryptoFacade.initializeConversation(publicKey, sharedSecret);

  static String encryptForConversation(String plaintext, String publicKey) =>
      ActiveCryptoFacade.encryptForConversation(plaintext, publicKey);

  static String decryptFromConversation(
    String encryptedBase64,
    String publicKey,
  ) => ActiveCryptoFacade.decryptFromConversation(encryptedBase64, publicKey);

  static bool hasConversationKey(String publicKey) =>
      ActiveCryptoFacade.hasConversationKey(publicKey);

  static void initializeSigning(String privateKeyHex, String publicKeyHex) =>
      ActiveCryptoFacade.initializeSigning(privateKeyHex, publicKeyHex);

  static String? signMessage(String content) =>
      ActiveCryptoFacade.signMessage(content);

  static bool verifySignature(
    String content,
    String signatureHex,
    String senderPublicKeyHex,
  ) => ActiveCryptoFacade.verifySignature(
    content,
    signatureHex,
    senderPublicKeyHex,
  );

  static bool get isSigningReady => ActiveCryptoFacade.isSigningReady;

  static String? computeSharedSecret(String theirPublicKeyHex) =>
      ActiveCryptoFacade.computeSharedSecret(theirPublicKeyHex);

  static Future<String?> encryptForContact(
    String plaintext,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ActiveCryptoFacade.encryptForContact(
    plaintext,
    contactPublicKey,
    contactRepo,
  );

  static Future<String?> decryptFromContact(
    String encryptedBase64,
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ActiveCryptoFacade.decryptFromContact(
    encryptedBase64,
    contactPublicKey,
    contactRepo,
  );

  static void clearConversationKey(String publicKey) =>
      ActiveCryptoFacade.clearConversationKey(publicKey);

  static void clearAllConversationKeys() =>
      ActiveCryptoFacade.clearAllConversationKeys();

  static Future<String?> getCachedOrComputeSharedSecret(
    String contactPublicKey,
    IContactRepository contactRepo,
  ) => ActiveCryptoFacade.getCachedOrComputeSharedSecret(
    contactPublicKey,
    contactRepo,
  );

  static Future<void> ensureConversationKeySync(
    String publicKey,
    IContactRepository repo,
  ) => ActiveCryptoFacade.ensureConversationKeySync(publicKey, repo);

  static Future<void> restoreConversationKey(
    String publicKey,
    String cachedSecret,
  ) => ActiveCryptoFacade.restoreConversationKey(publicKey, cachedSecret);
}
