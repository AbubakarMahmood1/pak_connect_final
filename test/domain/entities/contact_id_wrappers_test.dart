import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/domain/models/security_level.dart';

void main() {
  final now = DateTime(2024, 1, 1);

  Contact buildContact({String? persistentPublicKey}) {
    return Contact(
      publicKey: 'pub-123',
      persistentPublicKey: persistentPublicKey,
      currentEphemeralId: 'ephemeral-abc',
      displayName: 'Alice',
      trustStatus: TrustStatus.newContact,
      securityLevel: SecurityLevel.low,
      firstSeen: now,
      lastSeen: now,
    );
  }

  test('typed IDs fall back to public key when no persistent key', () {
    final contact = buildContact();

    expect(contact.userId, const UserId('pub-123'));
    expect(contact.persistentUserId, isNull);
    expect(contact.chatUserId, const UserId('pub-123'));
    expect(contact.chatIdValue, const ChatId('pub-123'));
  });

  test('typed IDs prefer persistent key when present', () {
    final contact = buildContact(persistentPublicKey: 'persist-456');

    expect(contact.userId, const UserId('pub-123'));
    expect(contact.persistentUserId, const UserId('persist-456'));
    expect(contact.chatUserId, const UserId('persist-456'));
    expect(contact.chatIdValue, const ChatId('persist-456'));
  });
}
