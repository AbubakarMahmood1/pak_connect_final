import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../domain/services/mesh/mesh_network_health_monitor.dart';
import '../../domain/services/mesh/mesh_queue_sync_coordinator.dart';
import '../../domain/services/mesh/mesh_relay_coordinator.dart';
import '../../domain/interfaces/i_handshake_coordinator_factory.dart';
import '../../domain/interfaces/i_mesh_relay_engine_factory.dart';
import '../../domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_ble_service.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_networking_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_chat_connection_manager_factory.dart';
import 'package:pak_connect/domain/interfaces/i_chat_list_coordinator_factory.dart';
import '../bluetooth/handshake_coordinator_factory.dart';
import '../messaging/mesh_relay_engine_factory.dart';
import '../services/app_core_shared_message_queue_provider.dart';
import '../services/home_screen_facade_factory.dart';
import '../services/chat_connection_manager_factory.dart';
import '../services/chat_list_coordinator_factory.dart';
import 'repository_provider_impl.dart';

/// GetIt service locator instance
final getIt = GetIt.instance;

/// Feature flag to enable/disable DI (for gradual migration)
const bool useDi = true;

final _logger = Logger('ServiceLocator');

typedef DataLayerRegistrar = Future<void> Function(GetIt getIt, Logger logger);

DataLayerRegistrar? _dataLayerRegistrar;

/// Configure a callback that registers concrete data-layer services.
///
/// This keeps core DI wiring dependent on domain contracts while delegating
/// concrete repository/service bindings to the data layer.
void configureDataLayerRegistrar(DataLayerRegistrar registrar) {
  _dataLayerRegistrar = registrar;
}

/// Sets up the dependency injection container
///
/// This function registers all services, repositories, and managers with GetIt.
///
/// **Registration Strategy**:
/// - Singletons: For stateful services that should have one instance
/// - Lazy Singletons: For services that may not be immediately needed
/// - Factories: For services that should be recreated on each request
///
/// **Phase 1 Part C**: Services are registered as singletons but initialized by AppCore
/// in correct dependency order (not at registration time).
Future<void> setupServiceLocator() async {
  _logger.info('🎯 Setting up service locator...');

  if (!useDi) {
    _logger.warning('⚠️ DI is disabled via useDi flag');
    return;
  }

  try {
    // If core-facing contracts are already registered, assume setup already ran.
    if (getIt.isRegistered<IContactRepository>() &&
        getIt.isRegistered<IMessageRepository>() &&
        getIt.isRegistered<IRepositoryProvider>() &&
        getIt.isRegistered<IBLEMessageHandlerFacade>() &&
        getIt.isRegistered<IHandshakeCoordinatorFactory>() &&
        getIt.isRegistered<IMeshRelayEngineFactory>() &&
        getIt.isRegistered<IBLEServiceFacadeFactory>()) {
      _logger.info(
        'ℹ️ Service locator already initialized — skipping re-registration',
      );
      return;
    }

    // Register shared queue provider first (used by data-layer registrations).
    if (!getIt.isRegistered<ISharedMessageQueueProvider>()) {
      getIt.registerSingleton<ISharedMessageQueueProvider>(
        AppCoreSharedMessageQueueProvider(),
      );
      _logger.fine('✅ ISharedMessageQueueProvider registered');
    } else {
      _logger.fine('ℹ️ ISharedMessageQueueProvider already registered');
    }

    final registrar = _dataLayerRegistrar;
    if (registrar == null) {
      throw StateError(
        'Data layer registrar is not configured. '
        'Call configureDataLayerRegistrar(...) before setupServiceLocator().',
      );
    }

    await registrar(getIt, _logger);

    if (!getIt.isRegistered<IContactRepository>() ||
        !getIt.isRegistered<IMessageRepository>()) {
      throw StateError(
        'Data layer registrar must register IContactRepository and IMessageRepository.',
      );
    }

    // ===========================
    // REPOSITORY PROVIDER (Core abstraction)
    // ===========================
    if (!getIt.isRegistered<IRepositoryProvider>()) {
      getIt.registerSingleton<IRepositoryProvider>(
        RepositoryProviderImpl(
          contactRepository: getIt<IContactRepository>(),
          messageRepository: getIt<IMessageRepository>(),
        ),
      );
      _logger.fine('✅ IRepositoryProvider registered (Phase 3)');
    } else {
      _logger.fine('ℹ️ IRepositoryProvider already registered');
    }

    if (!getIt.isRegistered<IHomeScreenFacadeFactory>()) {
      getIt.registerLazySingleton<IHomeScreenFacadeFactory>(
        () => const HomeScreenFacadeFactory(),
      );
      _logger.fine('✅ IHomeScreenFacadeFactory registered');
    } else {
      _logger.fine('ℹ️ IHomeScreenFacadeFactory already registered');
    }

    if (!getIt.isRegistered<IChatConnectionManagerFactory>()) {
      getIt.registerLazySingleton<IChatConnectionManagerFactory>(
        () => const ChatConnectionManagerFactory(),
      );
      _logger.fine('✅ IChatConnectionManagerFactory registered');
    } else {
      _logger.fine('ℹ️ IChatConnectionManagerFactory already registered');
    }

    if (!getIt.isRegistered<IChatListCoordinatorFactory>()) {
      getIt.registerLazySingleton<IChatListCoordinatorFactory>(
        () => const ChatListCoordinatorFactory(),
      );
      _logger.fine('✅ IChatListCoordinatorFactory registered');
    } else {
      _logger.fine('ℹ️ IChatListCoordinatorFactory already registered');
    }

    if (!getIt.isRegistered<IHandshakeCoordinatorFactory>()) {
      getIt.registerLazySingleton<IHandshakeCoordinatorFactory>(
        () => const CoreHandshakeCoordinatorFactory(),
      );
      _logger.fine('✅ IHandshakeCoordinatorFactory registered');
    } else {
      _logger.fine('ℹ️ IHandshakeCoordinatorFactory already registered');
    }

    if (!getIt.isRegistered<IMeshRelayEngineFactory>()) {
      getIt.registerLazySingleton<IMeshRelayEngineFactory>(
        () => const CoreMeshRelayEngineFactory(),
      );
      _logger.fine('✅ IMeshRelayEngineFactory registered');
    } else {
      _logger.fine('ℹ️ IMeshRelayEngineFactory already registered');
    }

    // ===========================
    // CORE SERVICES (initialized by AppCore, not here)
    // ===========================
    // SecurityManager: Registered as singleton instance (lazy init by AppCore)
    // Note: SecurityManager is initialized in AppCore._initializeCoreServices()
    // We access it via SecurityManager.instance to maintain backward compatibility
    _logger.fine('🔐 SecurityManager will be initialized by AppCore');

    // BLEService: Will be registered by AppCore after initialization
    _logger.fine('📡 BLEService will be registered by AppCore');

    // MeshNetworkingService: Will be registered by AppCore after initialization
    _logger.fine('🌐 MeshNetworkingService will be registered by AppCore');

    _logger.info(
      '✅ Service locator setup complete (includes Phase 3 abstractions)',
    );
  } catch (e, stackTrace) {
    _logger.severe('❌ Failed to setup service locator', e, stackTrace);
    rethrow;
  }
}

/// Register services after they're initialized by AppCore
/// Called by AppCore during initialization sequence
void registerInitializedServices({
  required ISecurityService securityService,
  required IConnectionService connectionService,
  required MeshNetworkingService meshNetworkingService,
  MeshRelayCoordinator? meshRelayCoordinator,
  MeshQueueSyncCoordinator? meshQueueSyncCoordinator,
  MeshNetworkHealthMonitor? meshHealthMonitor,
}) {
  _logger.info('📋 Registering initialized services...');

  try {
    // Register security interface
    if (!getIt.isRegistered<ISecurityService>()) {
      getIt.registerSingleton<ISecurityService>(securityService);
      _logger.fine('✅ ISecurityService registered in DI container');
    }

    // Register BLE/IConnectionService abstractions
    if (!getIt.isRegistered<IMeshBleService>()) {
      getIt.registerSingleton<IMeshBleService>(connectionService);
      _logger.fine('✅ IMeshBleService registered in DI container');
    }
    if (!getIt.isRegistered<IConnectionService>()) {
      getIt.registerSingleton<IConnectionService>(connectionService);
      _logger.fine('✅ IConnectionService registered in DI container');
    }
    if (connectionService is IBLEServiceFacade &&
        !getIt.isRegistered<IBLEServiceFacade>()) {
      getIt.registerSingleton<IBLEServiceFacade>(
        connectionService as IBLEServiceFacade,
      );
      _logger.fine('✅ IBLEServiceFacade registered in DI container');
    }

    // Register MeshNetworkingService singleton + interface
    if (!getIt.isRegistered<MeshNetworkingService>()) {
      getIt.registerSingleton<MeshNetworkingService>(meshNetworkingService);
      _logger.fine('✅ MeshNetworkingService registered in DI container');
    }
    if (!getIt.isRegistered<IMeshNetworkingService>()) {
      getIt.registerSingleton<IMeshNetworkingService>(meshNetworkingService);
      _logger.fine('✅ IMeshNetworkingService registered in DI container');
    }

    if (meshRelayCoordinator != null &&
        !getIt.isRegistered<MeshRelayCoordinator>()) {
      getIt.registerSingleton<MeshRelayCoordinator>(meshRelayCoordinator);
      _logger.fine('✅ MeshRelayCoordinator registered in DI container');
    }
    if (meshQueueSyncCoordinator != null &&
        !getIt.isRegistered<MeshQueueSyncCoordinator>()) {
      getIt.registerSingleton<MeshQueueSyncCoordinator>(
        meshQueueSyncCoordinator,
      );
      _logger.fine('✅ MeshQueueSyncCoordinator registered in DI container');
    }
    if (meshHealthMonitor != null &&
        !getIt.isRegistered<MeshNetworkHealthMonitor>()) {
      getIt.registerSingleton<MeshNetworkHealthMonitor>(meshHealthMonitor);
      _logger.fine('✅ MeshNetworkHealthMonitor registered in DI container');
    }

    _logger.info(
      '✅ All initialized services registered (includes Phase 3 interfaces)',
    );
  } catch (e, stackTrace) {
    _logger.severe('❌ Failed to register initialized services', e, stackTrace);
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
