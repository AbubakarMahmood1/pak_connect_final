import 'package:logging/logging.dart';
import '../models/spy_mode_info.dart';
import '../models/protocol_message.dart';
import '../services/simple_crypto.dart';
import '../../domain/values/id_types.dart';

/// Holds session-scoped identity information for a connected peer.
class IdentitySessionState {
  IdentitySessionState({Logger? logger})
    : _logger = logger ?? Logger('IdentitySessionState');

  final Logger _logger;

  String? currentSessionId;
  String? theirEphemeralId;
  String? theirPersistentKey;
  String? lastKnownDisplayName;
  final Map<String, String> ephemeralToPersistent = {};

  UserId? get theirPersistentUserId =>
      theirPersistentKey != null ? UserId(theirPersistentKey!) : null;

  UserId? get currentSessionUserId =>
      currentSessionId != null ? UserId(currentSessionId!) : null;

  /// Store the peer ephemeral ID and initialize session ID if missing.
  void setTheirEphemeralId(String ephemeralId) {
    _logger.fine('Storing their ephemeral ID: $ephemeralId');
    theirEphemeralId = ephemeralId;
    currentSessionId ??= ephemeralId;
  }

  void setTheirEphemeralUserId(UserId ephemeralId) =>
      setTheirEphemeralId(ephemeralId.value);

  void setTheirPersistentKey(String persistentKey) {
    _logger.fine('Storing their persistent key: ${_truncateId(persistentKey)}');
    theirPersistentKey = persistentKey;
    currentSessionId ??= persistentKey;
  }

  void setTheirPersistentUserId(UserId persistentId) =>
      setTheirPersistentKey(persistentId.value);

  void setPersistentAssociation({
    required String persistentKey,
    String? ephemeralId,
  }) {
    setTheirPersistentKey(persistentKey);
    if (ephemeralId != null && ephemeralId.isNotEmpty) {
      mapEphemeralToPersistent(ephemeralId, persistentKey);
    }
  }

  void setPersistentAssociationUser({
    required UserId persistentId,
    UserId? ephemeralId,
  }) => setPersistentAssociation(
    persistentKey: persistentId.value,
    ephemeralId: ephemeralId?.value,
  );

  void setCurrentSessionId(String? sessionId) {
    currentSessionId = sessionId;
  }

  void setCurrentSessionUserId(UserId? sessionId) =>
      setCurrentSessionId(sessionId?.value);

  void rememberDisplayName(String? displayName) {
    lastKnownDisplayName = displayName;
  }

  void mapEphemeralToPersistent(String ephemeralId, String persistentKey) {
    ephemeralToPersistent[ephemeralId] = persistentKey;
  }

  String? getPersistentKeyFromEphemeral(String ephemeralId) {
    return ephemeralToPersistent[ephemeralId];
  }

  /// Determine which ID should be used for addressing this peer.
  String? getRecipientId() {
    if (theirPersistentKey != null) return theirPersistentKey;
    return currentSessionId;
  }

  bool get isPaired => theirPersistentKey != null;

  String getIdType() {
    return isPaired ? 'persistent' : 'ephemeral';
  }

  /// Clear session identity; optionally keep persistent ID for navigation flows.
  void clear({bool preservePersistentId = false}) {
    if (!preservePersistentId) {
      currentSessionId = null;
      theirPersistentKey = null;
      lastKnownDisplayName = null;
    }
    theirEphemeralId = null;
  }

  /// Reset the mapping cache (used when rotating ephemerals across sessions).
  void clearMappings() {
    ephemeralToPersistent.clear();
  }

  Future<void> detectSpyMode({
    required String persistentKey,
    required Future<String?> Function(String persistentKey)
    getContactDisplayName,
    required Future<bool> Function() hintsEnabledFetcher,
    void Function(SpyModeInfo info)? onSpyModeDetected,
  }) async {
    final contactName = await getContactDisplayName(persistentKey);

    if (contactName == null) {
      _logger.info('👥 NEW CONTACT: Not in our contact list yet');
      return;
    }

    final hintsEnabled = await hintsEnabledFetcher();
    if (!hintsEnabled && theirEphemeralId != null) {
      _logger.info(
        '🕵️ SPY MODE: Connected to friend $contactName anonymously',
      );
      onSpyModeDetected?.call(
        SpyModeInfo(
          contactName: contactName,
          ephemeralID: theirEphemeralId!,
          persistentKey: persistentKey,
        ),
      );
    } else {
      _logger.info('👤 NORMAL MODE: Connected to friend $contactName');
    }
  }

  Future<ProtocolMessage?> createRevealMessage({
    required String myPersistentKey,
    String Function(String message)? sign,
    required int Function() nowMillis,
  }) async {
    if (theirEphemeralId == null) {
      _logger.warning('🕵️ Cannot reveal identity - no active session');
      return null;
    }

    final timestamp = nowMillis();
    final challenge = '${theirEphemeralId}_$timestamp';
    final proof = (sign ?? SimpleCrypto.signMessage).call(challenge) ?? '';

    if (proof.isEmpty) {
      _logger.severe('🕵️ Failed to generate cryptographic proof');
      return null;
    }

    final revealMessage = ProtocolMessage.friendReveal(
      myPersistentKey: myPersistentKey,
      proof: proof,
      timestamp: timestamp,
    );

    _logger.info('🕵️ Created FRIEND_REVEAL message');
    return revealMessage;
  }

  Future<String?> recoverDisplayName(
    Future<String?> Function(String publicKey) fetchDisplayName,
  ) async {
    if (currentSessionId == null) return null;
    final displayName = await fetchDisplayName(currentSessionId!);
    if (displayName != null && displayName.isNotEmpty) {
      rememberDisplayName(displayName);
    }
    return displayName;
  }

  String _truncateId(String? id, {int maxLength = 16}) {
    if (id == null) return 'null';
    if (id.length <= maxLength) return id;
    return '${id.substring(0, maxLength)}...';
  }
}
