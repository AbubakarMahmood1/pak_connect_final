import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

class KeyStorage {
  static final KeyStorage _instance = KeyStorage._internal();
  factory KeyStorage() => _instance;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  KeyStorage._internal();

  // Store private key securely
  Future<void> storePrivateKey(ECPrivateKey privateKey, String deviceId) async {
    final keyData = privateKey.d!.toRadixString(16);
    await _secureStorage.write(key: 'private_key_$deviceId', value: keyData);
  }

  // Retrieve private key
  Future<ECPrivateKey?> retrievePrivateKey(String deviceId) async {
    final keyData = await _secureStorage.read(key: 'private_key_$deviceId');
    if (keyData == null) return null;

    final domainParams = ECDomainParameters('prime256v1');
    final d = BigInt.parse(keyData, radix: 16);

    return ECPrivateKey(d, domainParams);
  }

  // Store shared secret for a device
  Future<void> storeSharedSecret(Uint8List secret, String deviceId) async {
    final base64Secret = base64Encode(secret);
    await _secureStorage.write(key: 'shared_secret_$deviceId', value: base64Secret);
  }

  // Retrieve shared secret for a device
  Future<Uint8List?> retrieveSharedSecret(String deviceId) async {
    final base64Secret = await _secureStorage.read(key: 'shared_secret_$deviceId');
    if (base64Secret == null) return null;

    return Uint8List.fromList(base64Decode(base64Secret));
  }

  // Check if we already have a shared secret for a device
  Future<bool> hasSharedSecret(String deviceId) async {
    final secret = await _secureStorage.read(key: 'shared_secret_$deviceId');
    return secret != null;
  }

  // Delete all keys for a device
  Future<void> clearKeysForDevice(String deviceId) async {
    await _secureStorage.delete(key: 'private_key_$deviceId');
    await _secureStorage.delete(key: 'shared_secret_$deviceId');
  }
}