import 'dart:io';
import 'ble_service.dart';
import 'ble_service_mobile.dart' if (dart.library.html) 'ble_service_unsupported.dart';
import 'ble_service_windows.dart' if (dart.library.html) 'ble_service_unsupported.dart';
import 'ble_service_unsupported.dart';

/// Returns the platform-specific BLE service implementation
BleService getPlatformBleService() {
  if (Platform.isAndroid || Platform.isIOS) {
    return BleServiceMobile();
  } else if (Platform.isWindows) {
    return BleServiceWindows();
  } else {
    return BleServiceUnsupported();
  }
}