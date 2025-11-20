import '../../core/interfaces/i_ble_advertising_service.dart';
import '../../core/interfaces/i_ble_connection_service.dart';
import '../../core/interfaces/i_ble_discovery_service.dart';
import '../../core/interfaces/i_ble_handshake_service.dart';
import '../../core/interfaces/i_ble_messaging_service.dart';
import '../../core/interfaces/i_ble_platform_host.dart';
import '../../core/bluetooth/advertising_manager.dart';
import '../../core/bluetooth/peripheral_initializer.dart';
import '../../core/bluetooth/bluetooth_state_monitor.dart';
import 'ble_connection_manager.dart';
import 'ble_connection_service.dart';
import 'ble_message_handler.dart';
import 'ble_service_facade.dart';
import 'ble_state_manager.dart';
import '../../core/services/hint_scanner_service.dart';
import '../repositories/intro_hint_repository.dart';

export 'ble_service_facade.dart' show BLEServiceFacade;

/// Compatibility wrapper so existing imports can continue to refer to
/// `BLEService` while the real implementation lives in [BLEServiceFacade].
class BLEService extends BLEServiceFacade {
  BLEService({
    IBLEPlatformHost? platformHost,
    BLEConnectionService? connectionService,
    IBLEMessagingService? messagingService,
    IBLEDiscoveryService? discoveryService,
    IBLEAdvertisingService? advertisingService,
    IBLEHandshakeService? handshakeService,
    BLEStateManager? stateManager,
    BLEMessageHandler? messageHandler,
    HintScannerService? hintScanner,
    IntroHintRepository? introHintRepository,
    BluetoothStateMonitor? bluetoothStateMonitor,
    BLEConnectionManager? connectionManager,
    PeripheralInitializer? peripheralInitializer,
    AdvertisingManager? advertisingManager,
  }) : super(
         platformHost: platformHost,
         connectionService: connectionService,
         messagingService: messagingService,
         discoveryService: discoveryService,
         advertisingService: advertisingService,
         handshakeService: handshakeService,
         stateManager: stateManager,
         messageHandler: messageHandler,
         hintScanner: hintScanner,
         introHintRepository: introHintRepository,
         bluetoothStateMonitor: bluetoothStateMonitor,
         connectionManager: connectionManager,
         peripheralInitializer: peripheralInitializer,
         advertisingManager: advertisingManager,
       );
}
