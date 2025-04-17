import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pointycastle/export.dart';

import 'KeyPairManager.dart';
import 'KeyStorage.dart';

class KeyExchangeService {
  static final KeyExchangeService _instance = KeyExchangeService._internal();
  factory KeyExchangeService() => _instance;

  final KeyPairManager _keyPairManager = KeyPairManager();
  final KeyStorage _keyStorage = KeyStorage();

  // UUIDs for key exchange service and characteristics
  static const String KEY_EXCHANGE_SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0";
  static const String PUBLIC_KEY_CHARACTERISTIC_UUID = "12345678-1234-5678-1234-56789abcdef1";
  static const String KEY_EXCHANGE_STATUS_UUID = "12345678-1234-5678-1234-56789abcdef2";

  KeyExchangeService._internal();

  // Check if a device supports key exchange
  Future<bool> deviceSupportsKeyExchange(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      return services.any((service) =>
      service.uuid.toString() == KEY_EXCHANGE_SERVICE_UUID);
    } catch (e) {
      print('Error checking key exchange support: $e');
      return false;
    }
  }

  // Perform key exchange with a connected device
  Future<bool> performKeyExchange(BluetoothDevice device) async {
    try {
      // Check if we already have a shared secret for this device
      if (await _keyStorage.hasSharedSecret(device.remoteId.toString())) {
        print('Already have a shared secret for this device');
        return true;
      }

      // Generate our key pair
      final keyPair = _keyPairManager.generateKeyPair();
      final privateKey = keyPair.privateKey as ECPrivateKey;
      final publicKey = keyPair.publicKey as ECPublicKey;

      // Store our private key
      await _keyStorage.storePrivateKey(privateKey, device.remoteId.toString());

      // Encode our public key for transmission
      final encodedPublicKey = _keyPairManager.encodePublicKey(publicKey);

      // Get the key exchange service
      final services = await device.discoverServices();
      final keyExchangeService = services.firstWhere(
            (service) => service.uuid.toString() == KEY_EXCHANGE_SERVICE_UUID,
        orElse: () => throw Exception('Key exchange service not found'),
      );

      // Get the public key characteristic
      final publicKeyChar = keyExchangeService.characteristics.firstWhere(
            (char) => char.uuid.toString() == PUBLIC_KEY_CHARACTERISTIC_UUID,
        orElse: () => throw Exception('Public key characteristic not found'),
      );

      // Send our public key
      await publicKeyChar.write(encodedPublicKey, withoutResponse: false);

      // Read their public key
      final response = await publicKeyChar.read();
      final theirPublicKey = _keyPairManager.decodePublicKey(Uint8List.fromList(response));

      // Compute shared secret
      final sharedSecret = _keyPairManager.computeSharedSecret(privateKey, theirPublicKey);

      // Store the shared secret
      await _keyStorage.storeSharedSecret(sharedSecret, device.remoteId.toString());

      return true;
    } catch (e) {
      print('Error during key exchange: $e');
      return false;
    }
  }
}