import 'dart:async';
import 'dart:developer' as developer;

/// Coordinates the safe disposal of services in the correct order
/// to prevent navigation corruption and memory leaks
class ServiceDisposalCoordinator {
  static final _instance = ServiceDisposalCoordinator._internal();
  factory ServiceDisposalCoordinator() => _instance;
  ServiceDisposalCoordinator._internal();

  final List<DisposableService> _registeredServices = [];
  bool _isDisposing = false;

  /// Register a service for coordinated disposal
  void registerService(DisposableService service) {
    if (!_registeredServices.contains(service)) {
      _registeredServices.add(service);
      developer.log('Service registered for disposal: ${service.serviceName}');
    }
  }

  /// Unregister a service (when it's disposed independently)
  void unregisterService(DisposableService service) {
    _registeredServices.remove(service);
    developer.log('Service unregistered: ${service.serviceName}');
  }

  /// Dispose all services in the correct order
  Future<void> disposeAllServices() async {
    if (_isDisposing) {
      developer.log('Disposal already in progress, ignoring request');
      return;
    }

    _isDisposing = true;
    developer.log('Starting coordinated service disposal...');

    try {
      // Sort services by disposal priority (higher priority disposed first)
      _registeredServices.sort(
        (a, b) => b.disposalPriority.compareTo(a.disposalPriority),
      );

      // Dispose services in priority order
      for (final service in _registeredServices) {
        try {
          developer.log(
            'Disposing service: ${service.serviceName} (priority: ${service.disposalPriority})',
          );
          await service.dispose();
        } catch (e) {
          developer.log(
            'Error disposing ${service.serviceName}: $e',
            level: 1000,
          );
        }
      }

      _registeredServices.clear();
      developer.log('✅ All services disposed successfully');
    } catch (e) {
      developer.log('❌ Error during coordinated disposal: $e', level: 1000);
    } finally {
      _isDisposing = false;
    }
  }

  /// Get disposal status
  bool get isDisposing => _isDisposing;

  /// Get registered services count
  int get registeredServicesCount => _registeredServices.length;
}

/// Interface for services that can be disposed in a coordinated manner
abstract class DisposableService {
  /// Name of the service for logging purposes
  String get serviceName;

  /// Priority for disposal order (higher priority disposed first)
  /// UI Services: 100-199
  /// Business Logic Services: 50-99
  /// Data Services: 10-49
  /// Core Services: 1-9
  int get disposalPriority;

  /// Dispose the service
  Future<void> dispose();
}

/// Disposal priorities for different service types
class DisposalPriority {
  static const int ui = 150;
  static const int businessLogic = 75;
  static const int dataServices = 25;
  static const int coreServices = 5;
}
