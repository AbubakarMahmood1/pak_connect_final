import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/ble_device.dart';
import 'ble_service.dart';
import 'ble_background_service.dart';
import 'ble_service_factory.dart';

class BleCommands {
  static const String startScanning = 'startScanning';
  static const String stopScanning = 'stopScanning';
  static const String startAdvertising = 'startAdvertising';
  static const String stopAdvertising = 'stopAdvertising';
  static const String connectToDevice = 'connectToDevice';
  static const String disconnectDevice = 'disconnectDevice';
  static const String writeCharacteristic = 'writeCharacteristic';
  static const String readCharacteristic = 'readCharacteristic';
  static const String stopService = 'stopService';
  static const String updateResults = 'updateResults';
  static const String updateConnectionState = 'updateConnectionState';
  static const String updateBluetoothState = 'updateBluetoothState';
}

class BleBackgroundServiceMobile implements BleBackgroundService {
  static const String _notificationChannelId = 'ble_scanner_foreground';
  static BleService _bleService = getPlatformBleService();
  static final Map<String, StreamSubscription> _subscriptions = {};
  static Timer? _resultsUpdateTimer;
  static Timer? _connectionStateTimer;
  static Timer? _bluetoothStateTimer;

  // Streams for UI communication
  static final _scanResultsController = StreamController<Map<String, dynamic>>.broadcast();
  static final _connectionStateController = StreamController<Map<String, dynamic>>.broadcast();
  static final _bluetoothStateController = StreamController<Map<String, dynamic>>.broadcast();
  static final _advertisingStateController = StreamController<Map<String, dynamic>>.broadcast();
  static final _writeResultsController = StreamController<Map<String, dynamic>>.broadcast();
  static final _readResultsController = StreamController<Map<String, dynamic>>.broadcast();
  static final _connectResultsController = StreamController<Map<String, dynamic>>.broadcast();
  static final _disconnectResultsController = StreamController<Map<String, dynamic>>.broadcast();

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
    final service = FlutterBackgroundService();
    await _configureAndroidForegroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'BLE Scanner Service',
        initialNotificationContent: 'Initializing',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.connectedDevice],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: _onBackgroundIOS,
      ),
    );
  }

  Future<void> _configureAndroidForegroundService() async {
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _notificationChannelId,
      'BLE Scanner Service',
      description: 'Notification channel for BLE scanner background service',
      importance: Importance.low,
    );
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  @override
  Future<bool> startService() async {
    final service = FlutterBackgroundService();
    bool running = await service.isRunning();
    if (running) return true;
    return await service.startService();
  }

  @override
  Future<bool> stopService() async {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.stopService);
    await Future.delayed(const Duration(milliseconds: 500));
    return !(await service.isRunning());
  }

  @override
  Future<bool> isRunning() async {
    final service = FlutterBackgroundService();
    return await service.isRunning();
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    final SendPort? sendPort =
    IsolateNameServer.lookupPortByName('ble_service_port');
    await _bleService.initialize();

    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: 'BLE Scanner Running',
        content: 'Monitoring BLE devices',
      );
    }

    _setupStreamSubscriptions(service, sendPort);
    _setupCommandHandlers(service, sendPort);
  }

  static void _setupStreamSubscriptions(ServiceInstance service, SendPort? sendPort) {
    // Clear existing subscriptions
    _subscriptions.forEach((key, subscription) => subscription.cancel());
    _subscriptions.clear();

    // Set up scan results subscription
    _subscriptions['scanResults'] = _bleService.scanResults.listen((devices) {
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

      service.invoke(
        BleCommands.updateResults,
        {
          'devices': formattedDevices,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );

      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'BLE Scanner Running',
          content: 'Found ${uniqueDevices.length} nearby devices',
        );
      }
    });

    // Set up connection state subscription
    _subscriptions['connectionState'] = _bleService.connectionState.listen((update) {
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

      service.invoke(
        BleCommands.updateConnectionState,
        {
          'connection': connectionData,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );
    });

    // Set up bluetooth state subscription
    _subscriptions['bluetoothState'] = _bleService.bluetoothState.listen((state) {
      final stateData = {
        'state': state.toString(),
        'isOn': state == BluetoothAdapterState.on,
      };

      _bluetoothStateController.add({
        'action': 'bluetoothState',
        'state': stateData,
      });

      service.invoke(
        BleCommands.updateBluetoothState,
        {
          'state': stateData,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );
    });

    // Set up advertising state subscription
    _subscriptions['advertisingState'] = _bleService.advertisingState.listen((isAdvertising) {
      final advertisingData = {'isAdvertising': isAdvertising};

      _advertisingStateController.add({
        'action': 'advertisingState',
        'advertising': advertisingData,
      });

      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'BLE Service Running',
          content: isAdvertising ? 'Broadcasting BLE signal' : 'Monitoring BLE devices',
        );
      }
    });
  }

  static void _setupCommandHandlers(ServiceInstance service, SendPort? sendPort) {
    service.on(BleCommands.stopService).listen((event) {
      _cleanupResources();
      service.stopSelf();
    });

    service.on(BleCommands.startScanning).listen((event) async {
      final String? servicesToScan = event?['services'];
      final List<String> servicesList =
      servicesToScan != null ? servicesToScan.split(',') : [];
      final int timeout = event?['timeout'] ?? 10;

      await _bleService.startScanning(
        withServices: servicesList,
        timeout: Duration(seconds: timeout),
      );

      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'BLE Scanner Running',
          content: 'Scanning for nearby devices',
        );
      }
    });

    service.on(BleCommands.stopScanning).listen((event) async {
      await _bleService.stopScanning();
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'BLE Scanner Running',
          content: 'Scanner paused',
        );
      }
    });

    service.on(BleCommands.startAdvertising).listen((event) async {
      final String? deviceId = event?['deviceId'];
      final String? serviceUuid = event?['serviceUuid'];
      if (deviceId != null && serviceUuid != null) {
        await _bleService.startAdvertising(deviceId, serviceUuid);
        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: 'BLE Service Running',
            content: 'Broadcasting as MyApp-$deviceId',
          );
        }
      }
    });

    service.on(BleCommands.stopAdvertising).listen((event) async {
      await _bleService.stopAdvertising();
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'BLE Service Running',
          content: 'Advertising stopped',
        );
      }
    });

    service.on(BleCommands.connectToDevice).listen((event) async {
      final String? remoteId = event?['remoteId'];
      final int timeout = event?['timeout'] ?? 15;
      final int maxRetries = event?['maxRetries'] ?? 3;

      if (remoteId != null) {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          final success = await _bleService.connectToDevice(
            device,
            timeout: Duration(seconds: timeout),
            maxRetries: maxRetries,
          );
          final result = {
            'action': 'connectResult',
            'remoteId': remoteId,
            'success': success,
          };
          _connectResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        } catch (e) {
          print('Error connecting to device: $e');
          final result = {
            'action': 'connectResult',
            'remoteId': remoteId,
            'success': false,
            'error': e.toString(),
          };
          _connectResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        }
      }
    });

    service.on(BleCommands.disconnectDevice).listen((event) async {
      final String? remoteId = event?['remoteId'];
      if (remoteId != null) {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          final success = await _bleService.disconnectDevice(device);
          final result = {
            'action': 'disconnectResult',
            'remoteId': remoteId,
            'success': success,
          };
          _disconnectResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        } catch (e) {
          print('Error disconnecting device: $e');
          final result = {
            'action': 'disconnectResult',
            'remoteId': remoteId,
            'success': false,
            'error': e.toString(),
          };
          _disconnectResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        }
      }
    });

    service.on(BleCommands.writeCharacteristic).listen((event) async {
      final String? remoteId = event?['remoteId'];
      final String? serviceUuid = event?['serviceUuid'];
      final String? characteristicUuid = event?['characteristicUuid'];
      final String? dataString = event?['data'];
      final bool withResponse = event?['withResponse'] ?? true;

      if (remoteId != null &&
          serviceUuid != null &&
          characteristicUuid != null &&
          dataString != null) {
        try {
          List<int> data;
          final String format = event?['format'] ?? 'utf8';
          switch (format) {
            case 'hex':
              data = _hexToBytes(dataString);
              break;
            case 'base64':
              data = _base64ToBytes(dataString);
              break;
            case 'utf8':
            default:
              data = _stringToBytes(dataString);
              break;
          }
          final device = BluetoothDevice.fromId(remoteId);
          final success = await _bleService.writeCharacteristic(
            device,
            serviceUuid,
            characteristicUuid,
            data,
            withResponse: withResponse,
          );
          final result = {
            'action': 'writeResult',
            'remoteId': remoteId,
            'characteristicUuid': characteristicUuid,
            'success': success,
          };
          _writeResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        } catch (e) {
          print('Error writing characteristic: $e');
          final result = {
            'action': 'writeResult',
            'remoteId': remoteId,
            'characteristicUuid': characteristicUuid,
            'success': false,
            'error': e.toString(),
          };
          _writeResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        }
      }
    });

    service.on(BleCommands.readCharacteristic).listen((event) async {
      final String? remoteId = event?['remoteId'];
      final String? serviceUuid = event?['serviceUuid'];
      final String? characteristicUuid = event?['characteristicUuid'];

      if (remoteId != null && serviceUuid != null && characteristicUuid != null) {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          final data = await _bleService.readCharacteristic(
            device,
            serviceUuid,
            characteristicUuid,
          );
          final String? format = event?['format'] ?? 'utf8';
          String formattedData = '';
          if (data != null) {
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
          }
          final result = {
            'action': 'readResult',
            'remoteId': remoteId,
            'characteristicUuid': characteristicUuid,
            'data': formattedData,
            'success': data != null,
          };
          _readResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        } catch (e) {
          print('Error reading characteristic: $e');
          final result = {
            'action': 'readResult',
            'remoteId': remoteId,
            'characteristicUuid': characteristicUuid,
            'success': false,
            'error': e.toString(),
          };
          _readResultsController.add(result);
          if (sendPort != null) {
            sendPort.send(result);
          }
        }
      }
    });
  }

  @pragma('vm:entry-point')
  static bool _onBackgroundIOS(ServiceInstance service) {
    print('[BLE Service] Running in iOS background mode.');
    return true;
  }

  static void _cleanupResources() {
    _resultsUpdateTimer?.cancel();
    _connectionStateTimer?.cancel();
    _bluetoothStateTimer?.cancel();

    // Cancel all subscriptions
    _subscriptions.forEach((key, subscription) => subscription.cancel());
    _subscriptions.clear();

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
  }

  static List<BleDevice> _removeDuplicateDevices(List<BleDevice> devices) {
    final uniqueDevices = <String, BleDevice>{};
    for (final device in devices) {
      final key = device.deviceId.isNotEmpty ? device.deviceId : device.device.remoteId.toString();
      uniqueDevices[key] = device;
    }
    return uniqueDevices.values.toList();
  }

  static List<int> _stringToBytes(String data) => utf8.encode(data);
  static String _bytesToString(List<int> data) => utf8.decode(data, allowMalformed: true);
  static List<int> _hexToBytes(String hex) {
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

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  static List<int> _base64ToBytes(String base64) => base64Decode(base64);
  static String _bytesToBase64(List<int> bytes) => base64Encode(bytes);

  @override
  void startScanning({List<String> services = const [], int timeout = 10}) {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.startScanning, {
      'services': services.join(','),
      'timeout': timeout,
    });
  }

  @override
  void stopScanning() {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.stopScanning);
  }

  @override
  void startAdvertising(String deviceId, String serviceUuid) {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.startAdvertising, {
      'deviceId': deviceId,
      'serviceUuid': serviceUuid,
    });
  }

  @override
  void stopAdvertising() {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.stopAdvertising);
  }

  @override
  void connectToDevice(String remoteId, {int timeout = 15, int maxRetries = 3}) {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.connectToDevice, {
      'remoteId': remoteId,
      'timeout': timeout,
      'maxRetries': maxRetries,
    });
  }

  @override
  void disconnectDevice(String remoteId) {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.disconnectDevice, {
      'remoteId': remoteId,
    });
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
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.writeCharacteristic, {
      'remoteId': remoteId,
      'serviceUuid': serviceUuid,
      'characteristicUuid': characteristicUuid,
      'data': data,
      'format': format,
      'withResponse': withResponse,
    });
  }

  @override
  void readCharacteristic(
      String remoteId,
      String serviceUuid,
      String characteristicUuid, {
        String format = 'utf8',
      }) {
    final service = FlutterBackgroundService();
    service.invoke(BleCommands.readCharacteristic, {
      'remoteId': remoteId,
      'serviceUuid': serviceUuid,
      'characteristicUuid': characteristicUuid,
      'format': format,
    });
  }
}