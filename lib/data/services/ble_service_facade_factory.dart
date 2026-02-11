import 'package:pak_connect/domain/interfaces/i_ble_service_facade.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade_factory.dart';

import 'ble_service.dart';

class DataBleServiceFacadeFactory implements IBLEServiceFacadeFactory {
  const DataBleServiceFacadeFactory();

  @override
  IBLEServiceFacade create() => BLEService();
}
