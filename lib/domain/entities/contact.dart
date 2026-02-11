import '../models/security_level.dart';
import '../values/id_types.dart';

/// Trust status for a contact record.
///
/// Mirrors the enums used inside the data repositories but lives in the
/// domain layer so upper layers never have to import concrete repository files.
enum TrustStatus {
  newContact, // 👤 Identity: Never verified this person
  verified, // 👤 Identity: Confirmed this is really them
  keyChanged, // 👤 Identity: Their key changed (security warning)
}

/// Contact domain entity.
///
/// Represents a single secure contact and the metadata required by the Noise
/// protocol implementation. Previously defined in the data layer; now promoted
/// so interfaces and services can depend on the domain model without importing
/// repository implementations.
class Contact {
  final String
  publicKey; // IMMUTABLE: First contact ID (never changes, primary key)
  final String?
  persistentPublicKey; // Persistent identity (NULL at LOW, set at MEDIUM+)
  final String?
  currentEphemeralId; // Active Noise session ID (updates on reconnect)

  final String displayName;
  final TrustStatus trustStatus;
  final SecurityLevel securityLevel;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final DateTime? lastSecuritySync;

  // Noise Protocol fields (Phase 2 integration)
  final String?
  noisePublicKey; // Base64-encoded peer Noise static public key (44 chars)
  final String?
  noiseSessionState; // Session lifecycle state (uninitialized/handshaking/established/expired)
  final DateTime? lastHandshakeTime; // When Noise session was last established

  // Favorites support (Phase 2.5)
  final bool isFavorite; // True if user marked this contact as favorite

  const Contact({
    required this.publicKey,
    this.persistentPublicKey,
    this.currentEphemeralId,
    required this.displayName,
    required this.trustStatus,
    required this.securityLevel,
    required this.firstSeen,
    required this.lastSeen,
    this.lastSecuritySync,
    this.noisePublicKey,
    this.noiseSessionState,
    this.lastHandshakeTime,
    this.isFavorite = false,
  });

  /// 🔧 MODEL: Get the chat ID for this contact
  /// - At LOW: Use publicKey (first ephemeral ID, temporary chat)
  /// - At MEDIUM+: Use persistentPublicKey (permanent chat identity)
  String get chatId => persistentPublicKey ?? publicKey;

  /// 🔧 MODEL: Get the session ID for Noise Protocol lookup
  /// Noise sessions are ALWAYS indexed by currentEphemeralId
  String? get sessionIdForNoise => currentEphemeralId ?? publicKey;

  /// Strongly typed accessors for identity-based value objects
  UserId get userId => UserId(publicKey);

  UserId? get persistentUserId =>
      persistentPublicKey != null ? UserId(persistentPublicKey!) : null;

  /// Chat identity prefers persistent key when available, otherwise falls back to first key.
  UserId get chatUserId => persistentUserId ?? userId;

  /// ChatId value object that respects the same resolution as [chatId].
  ChatId get chatIdValue => ChatId(chatId);

  Map<String, dynamic> toJson() => {
    'publicKey': publicKey,
    'persistentPublicKey': persistentPublicKey,
    'currentEphemeralId': currentEphemeralId,
    'displayName': displayName,
    'trustStatus': trustStatus.index,
    'securityLevel': securityLevel.index,
    'firstSeen': firstSeen.millisecondsSinceEpoch,
    'lastSeen': lastSeen.millisecondsSinceEpoch,
    'lastSecuritySync': lastSecuritySync?.millisecondsSinceEpoch,
    'noisePublicKey': noisePublicKey,
    'noiseSessionState': noiseSessionState,
    'lastHandshakeTime': lastHandshakeTime?.millisecondsSinceEpoch,
    'isFavorite': isFavorite,
  };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    publicKey: json['publicKey'] ?? json['public_key'],
    persistentPublicKey:
        json['persistentPublicKey'] ?? json['persistent_public_key'],
    currentEphemeralId:
        json['currentEphemeralId'] ?? json['current_ephemeral_id'],
    displayName: json['displayName'] ?? json['display_name'],
    trustStatus:
        TrustStatus.values[json['trustStatus'] ?? json['trust_status'] ?? 0],
    securityLevel: SecurityLevel
        .values[json['securityLevel'] ?? json['security_level'] ?? 0],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(
      json['firstSeen'] ?? json['first_seen'],
    ),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(
      json['lastSeen'] ?? json['last_seen'],
    ),
    lastSecuritySync: json['lastSecuritySync'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['lastSecuritySync'])
        : (json['last_security_sync'] != null
              ? DateTime.fromMillisecondsSinceEpoch(json['last_security_sync'])
              : null),
    noisePublicKey: json['noisePublicKey'] ?? json['noise_public_key'],
    noiseSessionState: json['noiseSessionState'] ?? json['noise_session_state'],
    lastHandshakeTime: json['lastHandshakeTime'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['lastHandshakeTime'])
        : (json['last_handshake_time'] != null
              ? DateTime.fromMillisecondsSinceEpoch(json['last_handshake_time'])
              : null),
    isFavorite: (json['isFavorite'] ?? json['is_favorite'] ?? 0) == 1,
  );

  /// Convert to database row format
  Map<String, dynamic> toDatabase() => {
    'public_key': publicKey,
    'persistent_public_key': persistentPublicKey,
    'current_ephemeral_id': currentEphemeralId,
    'display_name': displayName,
    'trust_status': trustStatus.index,
    'security_level': securityLevel.index,
    'first_seen': firstSeen.millisecondsSinceEpoch,
    'last_seen': lastSeen.millisecondsSinceEpoch,
    'last_security_sync': lastSecuritySync?.millisecondsSinceEpoch,
    'noise_public_key': noisePublicKey,
    'noise_session_state': noiseSessionState,
    'last_handshake_time': lastHandshakeTime?.millisecondsSinceEpoch,
    'is_favorite': isFavorite ? 1 : 0,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  };

  /// Create from database row
  factory Contact.fromDatabase(Map<String, dynamic> row) => Contact(
    publicKey: row['public_key'] as String,
    persistentPublicKey: row['persistent_public_key'] as String?,
    currentEphemeralId: row['current_ephemeral_id'] as String?,
    displayName: row['display_name'] as String,
    trustStatus: TrustStatus.values[row['trust_status'] as int],
    securityLevel: SecurityLevel.values[row['security_level'] as int],
    firstSeen: DateTime.fromMillisecondsSinceEpoch(row['first_seen'] as int),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(row['last_seen'] as int),
    lastSecuritySync: row['last_security_sync'] != null
        ? DateTime.fromMillisecondsSinceEpoch(row['last_security_sync'] as int)
        : null,
    noisePublicKey: row['noise_public_key'] as String?,
    noiseSessionState: row['noise_session_state'] as String?,
    lastHandshakeTime: row['last_handshake_time'] != null
        ? DateTime.fromMillisecondsSinceEpoch(row['last_handshake_time'] as int)
        : null,
    isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
  );

  Contact copyWithSecurityLevel(SecurityLevel newLevel) => Contact(
    publicKey: publicKey,
    persistentPublicKey: persistentPublicKey,
    currentEphemeralId: currentEphemeralId,
    displayName: displayName,
    trustStatus: trustStatus,
    securityLevel: newLevel,
    firstSeen: firstSeen,
    lastSeen: DateTime.now(),
    lastSecuritySync: DateTime.now(),
    noisePublicKey: noisePublicKey,
    noiseSessionState: noiseSessionState,
    lastHandshakeTime: lastHandshakeTime,
    isFavorite: isFavorite,
  );

  bool get isSecurityStale =>
      lastSecuritySync == null ||
      DateTime.now().difference(lastSecuritySync!).inHours > 24;
}
