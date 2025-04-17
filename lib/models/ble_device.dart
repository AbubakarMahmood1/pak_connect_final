import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleDevice {
  final BluetoothDevice device;
  final int rssi;
  final String advertisedName;
  final String deviceId;

  BleDevice({
    required this.device,
    required this.rssi,
    this.advertisedName = '',
    required this.deviceId,
  });
}