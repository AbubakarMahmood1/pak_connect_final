import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/models/identity_reveal_info.dart';
import 'package:pak_connect/domain/models/security_level.dart';

Contact _contact({
  required String publicKey,
  required String persistentKey,
  required String name,
}) {
  return Contact(
    publicKey: publicKey,
    persistentPublicKey: persistentKey,
    currentEphemeralId: 'current-$publicKey',
    displayName: name,
    trustStatus: TrustStatus.verified,
    securityLevel: SecurityLevel.medium,
    firstSeen: DateTime(2026, 1, 1),
    lastSeen: DateTime(2026, 1, 2),
  );
}

void main() {
  test('captures stable chat identity independently of duplicate names', () {
    final aliceOne = IdentityRevealInfo.fromVerifiedContact(
      verifiedPersistentPublicKey: 'persistent-a',
      contact: _contact(
        publicKey: 'first-a',
        persistentKey: 'persistent-a',
        name: 'Alice',
      ),
    );
    final aliceTwo = IdentityRevealInfo.fromVerifiedContact(
      verifiedPersistentPublicKey: 'persistent-b',
      contact: _contact(
        publicKey: 'first-b',
        persistentKey: 'persistent-b',
        name: 'Alice',
      ),
    );

    expect(aliceOne.contactName, aliceTwo.contactName);
    expect(aliceOne.chatId.value, 'persistent-a');
    expect(aliceTwo.chatId.value, 'persistent-b');
    expect(aliceOne.contactPublicKey, 'first-a');
    expect(aliceTwo.contactPublicKey, 'first-b');
  });

  test('rejects a resolved contact that is bound to another identity', () {
    expect(
      () => IdentityRevealInfo.fromVerifiedContact(
        verifiedPersistentPublicKey: 'spoofed-key',
        contact: _contact(
          publicKey: 'first-a',
          persistentKey: 'persistent-a',
          name: 'Alice',
        ),
      ),
      throwsStateError,
    );
  });
}
