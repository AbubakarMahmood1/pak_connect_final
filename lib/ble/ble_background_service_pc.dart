import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/ble_device.dart';
import 'ble_service.dart';
import 'ble_background_service.dart';
import 'ble_service_factory.dart';

class BleBackgroundServicePC implements BleBackgroundService {
  final BleService _bleService = getPlatformBleService();
  final _scanResultsController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStateController = StreamController<Map<String, dynamic>>.broadcast();
  final _bluetoothStateController = StreamController<Map<String, dynamic>>.broadcast();
  final _advertisingStateController = StreamController<Map<String, dynamic>>.broadcast();
  final _writeResultsController = StreamController<Map<String, dynamic>>.broadcast();
  final _readResultsController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectResultsController = StreamController<Map<String, dynamic>>.broadcast();
  final _disconnectResultsController = StreamController<Map<String, dynamic>>.broadcast();

  bool _isInitialized = false;

  @override
  Stream<Map<String, dynamic>> get scanResults => _scanResultsController.stream;
  @override
  Stream<Map<String, dynamic>> get connectionState => _connectionStateController.stream;
  @override
  Stream<Map<String, dynamic>> get bluetoothState => _bluetoothStateController.stream;
  @override
  Stream<Map<String, dynamic>> get advertisingState => _advertisingStateController.stream;
  @override
  Stream<Map<String, dynamic>> get writeResults => _writeResultsController.stream;
  @override
  Stream<Map<String, dynamic>> get readResults => _readResultsController.stream;
  @override
  Stream<Map<String, dynamic>> get connectResults => _connectResultsController.stream;
  @override
  Stream<Map<String, dynamic>> get disconnectResults => _disconnectResultsController.stream;

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await _bleService.initialize();
      _setupStreams();
      _isInitialized = true;
      print('BLE Background Service PC initialized');
    } catch (e) {
      print('Initialization error: $e');
      rethrow;
    }
  }

  void _setupStreams() {
    // Scan results
    _bleService.scanResults.listen(
          (devices) {
            final typedDevices = devices.cast<BleDevice>();
            final uniqueDevices = _removeDuplicateDevices(typedDevices);
        final formattedDevices = uniqueDevices
            .map((device) => {
          'deviceId': device.deviceId,
          'advertisedName': device.advertisedName,
          'rssi': device.rssi,
          'remoteId': device.device.remoteId.toString(),
        })
            .toList();

        _scanResultsController.add({
          'action': 'scanResults',
          'devices': formattedDevices,
        });
      },
      onError: (e) => _scanResultsController.add({
        'action': 'scanError',
        'error': e.toString(),
      }),
    );

    // Connection state
    _bleService.connectionState.listen(
          (update) {
        final connectionData = {
          'remoteId': update.device.remoteId.toString(),
          'deviceName': update.device.platformName,
          'state': update.state.toString(),
          'isConnected': update.isConnected,
        };

        _connectionStateController.add({
          'action': 'connectionState',
          'connection': connectionData,
        });
      },
      onError: (e) => _connectionStateController.add({
        'action': 'connectionError',
        'error': e.toString(),
      }),
    );

    // Bluetooth state
    _bleService.bluetoothState.listen(
          (state) {
        final stateData = {
          'state': state.toString(),
          'isOn': state == BluetoothAdapterState.on,
        };

        _bluetoothStateController.add({
          'action': 'bluetoothState',
          'state': stateData,
        });
      },
      onError: (e) => _bluetoothStateController.add({
        'action': 'bluetoothStateError',
        'error': e.toString(),
      }),
    );

    // Advertising state
    _bleService.advertisingState.listen(
          (isAdvertising) {
        _advertisingStateController.add({
          'action': 'advertisingState',
          'advertising': {'isAdvertising': isAdvertising},
        });
      },
      onError: (e) => _advertisingStateController.add({
        'action': 'advertisingError',
        'error': e.toString(),
      }),
    );
  }

  @override
  Future<bool> startService() async {
    // No background service on Windows; just ensure BLE is initialized
    if (!_isInitialized) {
      await initialize();
    }
    return true;
  }

  @override
  Future<bool> stopService() async {
    await _cleanupResources();
    return true;
  }

  @override
  Future<bool> isRunning() async {
    return _isInitialized;
  }

  @override
  void startScanning({List<String> services = const [], int timeout = 10}) {
    try {
      _bleService.startScanning(
        withServices: services,
        timeout: Duration(seconds: timeout),
      );
    } catch (e) {
      _scanResultsController.add({
        'action': 'scanError',
        'error': e.toString(),
      });
    }
  }

  @override
  void stopScanning() {
    try {
      _bleService.stopScanning();
    } catch (e) {
      _scanResultsController.add({
        'action': 'scanError',
        'error': e.toString(),
      });
    }
  }

  @override
  void startAdvertising(String deviceId, String serviceUuid) {
    try {
      _bleService.startAdvertising(deviceId, serviceUuid);
    } catch (e) {
      _advertisingStateController.add({
        'action': 'advertisingError',
        'error': e.toString(),
      });
    }
  }

  @override
  void stopAdvertising() {
    try {
      _bleService.stopAdvertising();
    } catch (e) {
      _advertisingStateController.add({
        'action': 'advertisingError',
        'error': e.toString(),
      });
    }
  }

  @override
  void connectToDevice(String remoteId, {int timeout = 15, int maxRetries = 3}) {
    try {
      final device = BluetoothDevice.fromId(remoteId);
      _bleService.connectToDevice(
        device,
        timeout: Duration(seconds: timeout),
        maxRetries: maxRetries,
      ).then((success) {
        _connectResultsController.add({
          'action': 'connectResult',
          'remoteId': remoteId,
          'success': success,
        });
      }).catchError((e) {
        _connectResultsController.add({
          'action': 'connectResult',
          'remoteId': remoteId,
          'success': false,
          'error': e.toString(),
        });
      });
    } catch (e) {
      _connectResultsController.add({
        'action': 'connectResult',
        'remoteId': remoteId,
        'success': false,
        'error': e.toString(),
      });
    }
  }

  @override
  void disconnectDevice(String remoteId) {
    try {
      final device = BluetoothDevice.fromId(remoteId);
      _bleService.disconnectDevice(device).then((success) {
        _disconnectResultsController.add({
          'action': 'disconnectResult',
          'remoteId': remoteId,
          'success': success,
        });
      }).catchError((e) {
        _disconnectResultsController.add({
          'action': 'disconnectResult',
          'remoteId': remoteId,
          'success': false,
          'error': e.toString(),
        });
      });
    } catch (e) {
      _disconnectResultsController.add({
        'action': 'disconnectResult',
        'remoteId': remoteId,
        'success': false,
        'error': e.toString(),
      });
    }
  }

  @override
  void writeCharacteristic(
      String remoteId,
      String serviceUuid,
      String characteristicUuid,
      String data, {
        String format = 'utf8',
        bool withResponse = true,
      }) {
    try {
      List<int> bytes;
      switch (format) {
        case 'hex':
          bytes = _hexToBytes(data);
          break;
        case 'base64':
          bytes = _base64ToBytes(data);
          break;
        case 'utf8':
        default:
          bytes = _stringToBytes(data);
          break;
      }
      final device = BluetoothDevice.fromId(remoteId);
      _bleService.writeCharacteristic(
        device,
        serviceUuid,
        characteristicUuid,
        bytes,
        withResponse: withResponse,
      ).then((success) {
        _writeResultsController.add({
          'action': 'writeResult',
          'remoteId': remoteId,
          'characteristicUuid': characteristicUuid,
          'success': success,
        });
      }).catchError((e) {
        _writeResultsController.add({
          'action': 'writeResult',
          'remoteId': remoteId,
          'characteristicUuid': characteristicUuid,
          'success': false,
          'error': e.toString(),
        });
      });
    } catch (e) {
      _writeResultsController.add({
        'action': 'writeResult',
        'remoteId': remoteId,
        'characteristicUuid': characteristicUuid,
        'success': false,
        'error': e.toString(),
      });
    }
  }

  @override
  void readCharacteristic(
      String remoteId,
      String serviceUuid,
      String characteristicUuid, {
        String format = 'utf8',
      }) {
    try {
      final device = BluetoothDevice.fromId(remoteId);
      _bleService.readCharacteristic(
        device,
        serviceUuid,
        characteristicUuid,
      ).then((data) {
        if (data != null) {
          String formattedData;
          switch (format) {
            case 'hex':
              formattedData = _bytesToHex(data);
              break;
            case 'base64':
              formattedData = _bytesToBase64(data);
              break;
            case 'utf8':
            default:
              formattedData = _bytesToString(data);
              break;
          }
          _readResultsController.add({
            'action': 'readResult',
            'remoteId': remoteId,
            'characteristicUuid': characteristicUuid,
            'data': formattedData,
            'success': true,
          });
        } else {
          _readResultsController.add({
            'action': 'readResult',
            'remoteId': remoteId,
            'characteristicUuid': characteristicUuid,
            'success': false,
            'error': 'No data received',
          });
        }
      }).catchError((e) {
        _readResultsController.add({
          'action': 'readResult',
          'remoteId': remoteId,
          'characteristicUuid': characteristicUuid,
          'success': false,
          'error': e.toString(),
        });
      });
    } catch (e) {
      _readResultsController.add({
        'action': 'readResult',
        'remoteId': remoteId,
        'characteristicUuid': characteristicUuid,
        'success': false,
        'error': e.toString(),
      });
    }
  }

  Future<void> _cleanupResources() async {
    try {
      _bleService.stopScanning();
      _bleService.stopAdvertising();
      _scanResultsController.close();
      _connectionStateController.close();
      _bluetoothStateController.close();
      _advertisingStateController.close();
      _writeResultsController.close();
      _readResultsController.close();
      _connectResultsController.close();
      _disconnectResultsController.close();
      _isInitialized = false;
      print('BLE resources cleaned up');
    } catch (e) {
      print('Error cleaning up resources: $e');
    }
  }

  List<BleDevice> _removeDuplicateDevices(List<BleDevice> devices) {
    final uniqueDevices = <String, BleDevice>{};
    for (final device in devices) {
      final key = device.deviceId.isNotEmpty ? device.deviceId : device.device.remoteId.toString();
      uniqueDevices[key] = device;
    }
    return uniqueDevices.values.toList();
  }

  List<int> _stringToBytes(String data) => utf8.encode(data);
  String _bytesToString(List<int> data) => utf8.decode(data, allowMalformed: true);
  List<int> _hexToBytes(String hex) {
    if (hex.isEmpty) throw FormatException('Empty hex string');
    hex = hex.replaceAll(' ', '');
    if (!RegExp(r'^[0-9A-Fa-f]*$').hasMatch(hex)) {
      throw FormatException('Invalid hex string: $hex');
    }
    if (hex.length % 2 != 0) hex = '0$hex';
    List<int> bytes = [];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  List<int> _base64ToBytes(String base64) => base64Decode(base64);
  String _bytesToBase64(List<int> bytes) => base64Encode(bytes);
}