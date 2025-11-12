import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// GetIt service locator instance
final getIt = GetIt.instance;

/// Feature flag to enable/disable DI (for gradual migration)
const bool USE_DI = true;

final _logger = Logger('ServiceLocator');

/// Sets up the dependency injection container
///
/// This function registers all services, repositories, and managers with GetIt.
///
/// **Registration Strategy**:
/// - Singletons: For stateful services that should have one instance
/// - Lazy Singletons: For services that may not be immediately needed
/// - Factories: For services that should be recreated on each request
///
/// **Phase 1 Note**: Currently empty - services will be registered incrementally
/// to maintain backward compatibility during migration.
Future<void> setupServiceLocator() async {
  _logger.info('🎯 Setting up service locator...');

  if (!USE_DI) {
    _logger.warning('⚠️ DI is disabled via USE_DI flag');
    return;
  }

  try {
    // ===========================
    // REPOSITORIES
    // ===========================
    // TODO: Register IContactRepository
    // getIt.registerSingleton<IContactRepository>(ContactRepositoryImpl());

    // TODO: Register IMessageRepository
    // getIt.registerSingleton<IMessageRepository>(MessageRepositoryImpl());

    // TODO: Register other repositories

    // ===========================
    // CORE SERVICES
    // ===========================
    // TODO: Register ISecurityManager
    // getIt.registerLazySingleton<ISecurityManager>(() => SecurityManagerImpl());

    // TODO: Register IMeshNetworkingService
    // getIt.registerLazySingleton<IMeshNetworkingService>(() => MeshNetworkingServiceImpl());

    // ===========================
    // DATA SERVICES
    // ===========================
    // TODO: Register IBLEService
    // getIt.registerLazySingleton<IBLEService>(() => BLEServiceImpl());

    _logger.info('✅ Service locator setup complete');
  } catch (e, stackTrace) {
    _logger.severe('❌ Failed to setup service locator', e, stackTrace);
    rethrow;
  }
}

/// Resets the service locator (useful for testing)
Future<void> resetServiceLocator() async {
  _logger.info('🔄 Resetting service locator...');
  await getIt.reset();
  _logger.info('✅ Service locator reset complete');
}

/// Checks if a service is registered
bool isRegistered<T extends Object>() {
  return getIt.isRegistered<T>();
}
