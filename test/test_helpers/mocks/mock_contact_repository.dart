import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/core/services/security_manager.dart';

/// Lightweight in-memory ContactRepository stub for tests.
class MockContactRepository extends ContactRepository {
  final Map<String, Contact> _store = {};

  @override
  Future<void> saveContact(String publicKey, String displayName) async {
    _store[publicKey] = Contact(
      publicKey: publicKey,
      displayName: displayName,
      trustStatus: TrustStatus.newContact,
      securityLevel: SecurityLevel.low,
      firstSeen: DateTime.now(),
      lastSeen: DateTime.now(),
    );
  }

  @override
  Future<Contact?> getContact(String publicKey) async => _store[publicKey];
}
