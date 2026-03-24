import 'package:pak_connect/core/di/service_locator.dart' as di_service_locator;

typedef TestServiceRegistry = di_service_locator.ServiceRegistry;

final TestServiceRegistry testServiceRegistry =
    di_service_locator.serviceRegistry;

final TestServiceRegistry serviceRegistry = testServiceRegistry;
