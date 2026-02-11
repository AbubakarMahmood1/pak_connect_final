import 'i_ble_service_facade.dart';

/// Factory contract for creating BLE facade instances.
abstract interface class IBLEServiceFacadeFactory {
  IBLEServiceFacade create();
}
