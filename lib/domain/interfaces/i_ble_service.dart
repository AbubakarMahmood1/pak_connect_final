import 'package:pak_connect/domain/interfaces/i_ble_service_facade.dart';

/// Legacy BLE service contract kept for compatibility.
///
/// New code should depend on [IBLEServiceFacade] or [IConnectionService].
@Deprecated('Use IBLEServiceFacade instead.')
typedef IBLEService = IBLEServiceFacade;
