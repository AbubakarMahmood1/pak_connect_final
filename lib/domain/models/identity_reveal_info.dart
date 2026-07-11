import '../entities/contact.dart';
import '../values/id_types.dart';

/// Stable identity captured after a FRIEND_REVEAL proof has been verified.
///
/// Display names are presentation only. Navigation and chat lookup must use
/// [chatId] / [persistentPublicKey], so duplicate names and later disconnects
/// cannot redirect the action to a different peer.
class IdentityRevealInfo {
  const IdentityRevealInfo({
    required this.contactName,
    required this.persistentPublicKey,
    required this.contactPublicKey,
    required this.chatId,
  });

  factory IdentityRevealInfo.fromVerifiedContact({
    required String verifiedPersistentPublicKey,
    required Contact contact,
  }) {
    final boundIdentity = contact.persistentPublicKey ?? contact.publicKey;
    if (boundIdentity != verifiedPersistentPublicKey) {
      throw StateError(
        'Verified reveal key is not bound to the resolved contact',
      );
    }

    return IdentityRevealInfo(
      contactName: contact.displayName,
      persistentPublicKey: verifiedPersistentPublicKey,
      contactPublicKey: contact.publicKey,
      chatId: contact.chatIdValue,
    );
  }

  final String contactName;
  final String persistentPublicKey;
  final String contactPublicKey;
  final ChatId chatId;
}
