import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

class ChatScreenConfig {
  final Peripheral? device;
  final Central? central;
  final String? chatId;
  final String? contactName;
  final String? contactPublicKey;

  const ChatScreenConfig({
    this.device,
    this.central,
    this.chatId,
    this.contactName,
    this.contactPublicKey,
  });

  bool get isRepositoryMode => chatId != null;
  bool get isCentralMode => device != null;
  bool get isPeripheralMode => central != null;
}
