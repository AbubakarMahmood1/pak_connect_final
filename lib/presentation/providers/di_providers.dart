import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/core/di/app_services.dart';

/// Single presentation-layer bridge to the app service locator.
///
/// Pass 0 DI guardrail: presentation code should not import `get_it` directly
/// outside this file.
final getItProvider = Provider<GetIt>((ref) => GetIt.instance);

/// Access the service locator outside provider/ref contexts.
GetIt getServiceLocator() => GetIt.instance;

/// Resolve a dependency from GetIt through Riverpod.
T resolveFromGetIt<T extends Object>(Ref ref, {String? dependencyName}) {
  final locator = ref.read(getItProvider);
  if (locator.isRegistered<T>()) {
    return locator<T>();
  }

  final label = dependencyName ?? T.toString();
  throw StateError('$label is not registered in GetIt');
}

/// Resolve a dependency from GetIt without a Riverpod Ref.
T resolveFromServiceLocator<T extends Object>({String? dependencyName}) {
  final locator = getServiceLocator();
  if (locator.isRegistered<T>()) {
    return locator<T>();
  }

  final label = dependencyName ?? T.toString();
  throw StateError('$label is not registered in GetIt');
}

/// Resolve an optional dependency from GetIt through Riverpod.
T? maybeResolveFromGetIt<T extends Object>(Ref ref) {
  final locator = ref.read(getItProvider);
  if (!locator.isRegistered<T>()) {
    return null;
  }
  return locator<T>();
}

/// Resolve an optional dependency from GetIt without a Riverpod Ref.
T? maybeResolveFromServiceLocator<T extends Object>() {
  final locator = getServiceLocator();
  if (!locator.isRegistered<T>()) {
    return null;
  }
  return locator<T>();
}

/// Check whether a dependency is available in GetIt.
bool isRegisteredInServiceLocator<T extends Object>() {
  return getServiceLocator().isRegistered<T>();
}

/// Best-effort snapshot of the typed composition root.
///
/// Returns `null` while app bootstrap is incomplete.
AppServices? maybeResolveAppServices() {
  final locator = getServiceLocator();
  if (!locator.isRegistered<AppServices>()) {
    return null;
  }
  return locator<AppServices>();
}

/// Resolve dependencies from typed composition root first, then GetIt.
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

/// Resolve an optional dependency from typed composition root first, then GetIt.
T? maybeResolveFromAppServicesOrServiceLocator<T extends Object>({
  required T? Function(AppServices services) fromServices,
}) {
  final services = maybeResolveAppServices();
  if (services != null) {
    return fromServices(services);
  }
  return maybeResolveFromServiceLocator<T>();
}
