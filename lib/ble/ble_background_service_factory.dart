import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ble_background_service.dart';
import 'ble_background_service_pc.dart';

class BleBackgroundServiceFactory {
  static BleBackgroundService getService() {
    if (kIsWeb) {
      return BleBackgroundServicePC();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        return BleBackgroundServiceMobile();
      } catch (e) {
        print('Failed to initialize mobile BLE service: $e');
        return BleBackgroundServicePC();
      }
    }
    return BleBackgroundServicePC();
  }
}