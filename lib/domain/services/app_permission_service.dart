import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Centralizes runtime permission checks so UI and BLE runtime code stay aligned.
class AppPermissionService {
  const AppPermissionService();

  Future<bool> hasRequiredBlePermissions() async {
    final permissions = await requiredBlePermissions();
    if (permissions.isEmpty) {
      return true;
    }

    final statuses = await Future.wait(
      permissions.map((permission) => permission.status),
    );
    return statuses.every((status) => status.isGranted);
  }

  Future<Map<Permission, PermissionStatus>> requestRequiredBlePermissions()
  async {
    final permissions = await requiredBlePermissions();
    if (permissions.isEmpty) {
      return const <Permission, PermissionStatus>{};
    }
    return permissions.request();
  }

  Future<bool> hasBleAdvertisePermission() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final sdkInt = await _androidSdkInt();
    if (sdkInt == null || sdkInt < 31) {
      return true;
    }

    return (await Permission.bluetoothAdvertise.status).isGranted;
  }

  Future<bool> hasNotificationPermission() async {
    final permission = await _notificationPermission();
    if (permission == null) {
      return true;
    }

    final status = await permission.status;
    return status.isGranted;
  }

  Future<bool> requestNotificationPermission() async {
    final permission = await _notificationPermission();
    if (permission == null) {
      return true;
    }

    final status = await permission.request();
    return status.isGranted;
  }

  Future<List<Permission>> requiredBlePermissions() async {
    if (!Platform.isAndroid) {
      return const <Permission>[];
    }

    final sdkInt = await _androidSdkInt();
    if (sdkInt != null && sdkInt >= 31) {
      return const <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ];
    }

    return const <Permission>[Permission.locationWhenInUse];
  }

  Future<Permission?> _notificationPermission() async {
    if (Platform.isAndroid) {
      final sdkInt = await _androidSdkInt();
      if (sdkInt != null && sdkInt < 33) {
        return null;
      }
      return Permission.notification;
    }

    if (Platform.isIOS) {
      return Permission.notification;
    }

    return null;
  }

  Future<int?> _androidSdkInt() async {
    if (!Platform.isAndroid) {
      return null;
    }

    final info = await DeviceInfoPlugin().androidInfo;
    return info.version.sdkInt;
  }
}
