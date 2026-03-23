import 'package:pak_connect/core/di/app_services.dart';
import 'package:pak_connect/core/di/service_locator.dart' as di_service_locator;

/// Resolve a dependency from the runtime composition root fallback.
T resolveFromServiceLocator<T extends Object>({String? dependencyName}) {
  return di_service_locator.resolveRegistered<T>(
    dependencyName: dependencyName,
  );
}

T? maybeResolveFromServiceLocator<T extends Object>() {
  return di_service_locator.maybeResolveRegistered<T>();
}

/// Check whether a dependency is available in the fallback service locator.
bool isRegisteredInServiceLocator<T extends Object>() {
  return di_service_locator.isRegistered<T>();
}

/// Best-effort snapshot of the typed composition root.
///
/// Returns `null` while app bootstrap is incomplete.
AppServices? maybeResolveAppServices() {
  return AppRuntimeServicesRegistry.maybeCurrent();
}

/// Test-only hook used by presentation/widget tests to clear the runtime
/// composition snapshot between isolated registry setups.
void clearRuntimeAppServicesForTesting() {
  AppRuntimeServicesRegistry.clear();
}

/// Resolve dependencies from typed composition root first, then the service locator.
T resolveFromAppServicesOrServiceLocator<T extends Object>({
  required T Function(AppServices services) fromServices,
  String? dependencyName,
}) {
  final services = maybeResolveAppServices();
  if (services != null) {
    return fromServices(services);
  }
  return resolveFromServiceLocator<T>(dependencyName: dependencyName);
}

/// Resolve an optional dependency from typed composition root first, then the service locator.
T? maybeResolveFromAppServicesOrServiceLocator<T extends Object>({
  required T? Function(AppServices services) fromServices,
}) {
  final services = maybeResolveAppServices();
  if (services != null) {
    return fromServices(services);
  }
  return maybeResolveFromServiceLocator<T>();
}
