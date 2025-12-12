import '../../core/models/protocol_message.dart';

/// Interface for protocol message handling
///
/// Responsibilities:
/// - Parsing and validating protocol messages (contact requests, verifications, queue sync, etc.)
/// - Dispatching protocol messages to appropriate handlers
/// - Identity resolution (determining who sent the message and who it's for)
/// - Crypto verification request/response handling
/// - Queue synchronization message processing
/// - Friend reveal (spy mode identity disclosure)
/// - QR introduction claims and verification
abstract interface class IProtocolMessageHandler {
  /// Processes a received protocol message
  ///
  /// Handles:
  /// - Protocol message parsing
  /// - Message type dispatch
  /// - Contact requests/accepts/rejects
  /// - Crypto verification requests/responses
  /// - Queue sync messages
  /// - Friend reveals (spy mode)
  /// - Direct protocol messages
  ///
  /// Returns:
  /// - Message ID if processed successfully
  /// - null if processing failed
  Future<String?> processProtocolMessage({
    required ProtocolMessage message,
    required String fromDeviceId,
    required String fromNodeId,
    String? transportMessageId,
  });

  /// Processes a complete protocol message (all fragments received)
  ///
  /// After reassembly completes, this processes the final message
  Future<String?> processCompleteProtocolMessage({
    required String content,
    required String fromDeviceId,
    required String fromNodeId,
    required Map<String, dynamic>? messageData,
    String? transportMessageId,
  });

  /// Handles direct protocol messages (not relayed)
  ///
  /// These are messages meant for this device (not mesh relay)
  Future<String?> handleDirectProtocolMessage({
    required ProtocolMessage message,
    required String fromDeviceId,
    String? transportMessageId,
  });

  /// Handles QR code introduction claim
  ///
  /// When two devices scan each other's QR codes, they exchange identity info
  Future<void> handleQRIntroductionClaim({
    required String claimJson,
    required String fromDeviceId,
  });

  /// Checks if QR introduction matches (for identity verification)
  ///
  /// Verifies that both devices saw the same QR data
  Future<bool> checkQRIntroductionMatch({
    required String receivedHash,
    required String expectedHash,
  });

  /// Determines encryption method for a message
  ///
  /// Returns: 'ecdh', 'conversation', 'global', or 'none'
  Future<String> getMessageEncryptionMethod({
    required String senderKey,
    required String recipientKey,
  });

  /// Resolves message sender and recipient identities
  ///
  /// Handles:
  /// - Converting ephemeral IDs to persistent keys
  /// - Detecting spy mode scenarios (asymmetric relationships)
  /// - Retrieving contact display names
  ///
  /// Returns:
  /// - Map with 'originalSender', 'intendedRecipient', 'isSpyMode' flags
  Future<Map<String, dynamic>> resolveMessageIdentities({
    required String? encryptionSenderKey,
    required String? meshSenderKey,
    required String? intendedRecipient,
  });

  /// Checks if message is intended for this device
  ///
  /// Returns true if:
  /// - intendedRecipient matches our node ID
  /// - intendedRecipient is null (broadcast)
  Future<bool> isMessageForMe(String? intendedRecipient);

  /// Sets encryption method for outgoing messages
  ///
  /// Used to mark which encryption scheme to use for next send
  void setEncryptionMethod(String method);

  /// Gets current encryption method setting
  String getEncryptionMethod();

  /// Registers callback for emitting ACK protocol messages after successful
  /// handling of inbound frames.
  void onSendAckMessage(Function(ProtocolMessage message) callback);

  /// Registers callback for contact request events
  void onContactRequestReceived(
    Function(String contactKey, String displayName) callback,
  );

  /// Registers callback for contact accept events
  void onContactAcceptReceived(
    Function(String contactKey, String displayName) callback,
  );

  /// Registers callback for contact reject events
  void onContactRejectReceived(Function() callback);

  /// Registers callback for crypto verification requests
  void onCryptoVerificationReceived(
    Function(String verificationId, String contactKey) callback,
  );

  /// Registers callback for crypto verification responses
  void onCryptoVerificationResponseReceived(
    Function(
      String verificationId,
      String contactKey,
      bool isVerified,
      Map<String, dynamic>? data,
    )
    callback,
  );

  /// Registers callback for friend reveal (spy mode identity disclosure)
  void onIdentityRevealed(Function(String contactName) callback);
}
