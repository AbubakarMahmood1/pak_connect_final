import 'dart:typed_data';

import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/encryption_method.dart';
import 'package:pak_connect/domain/models/security_level.dart';

/// Domain contract for encryption/decryption and security level selection.
abstract class ISecurityService {
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  });

  void unregisterIdentityMapping(String persistentPublicKey);

  Future<SecurityLevel> getCurrentLevel(
    String publicKey, [
    IContactRepository? repo,
  ]);

  Future<EncryptionMethod> getEncryptionMethod(
    String publicKey,
    IContactRepository repo,
  );

  Future<String> encryptMessage(
    String message,
    String publicKey,
    IContactRepository repo,
  );

  Future<String> decryptMessage(
    String encryptedMessage,
    String publicKey,
    IContactRepository repo,
  );

  Future<Uint8List> encryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  );

  Future<Uint8List> decryptBinaryPayload(
    Uint8List data,
    String publicKey,
    IContactRepository repo,
  );

  bool hasEstablishedNoiseSession(String peerSessionId);
}
