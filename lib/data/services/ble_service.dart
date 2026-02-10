import 'ble_service_facade.dart';
import 'ble_state_manager.dart';
import 'ble_state_manager_facade.dart';

export 'ble_service_facade.dart' show BLEServiceFacade;

/// Compatibility wrapper so existing imports can continue to refer to
/// `BLEService` while the real implementation lives in [BLEServiceFacade].
class BLEService extends BLEServiceFacade {
  BLEService({
    super.platformHost,
    super.connectionService,
    super.messagingService,
    super.discoveryService,
    super.advertisingService,
    super.handshakeService,
    BLEStateManagerFacade? stateManagerFacade,
    BLEStateManager? stateManager,
    super.messageHandler,
    super.hintScanner,
    super.introHintRepository,
    super.bluetoothStateMonitor,
    super.connectionManager,
    super.peripheralInitializer,
    super.advertisingManager,
  }) : super(
         stateManager: stateManagerFacade,
         legacyStateManager: stateManager,
       );
}
