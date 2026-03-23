import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import '../../domain/services/archive_management_service.dart';
import '../../domain/services/archive_search_service.dart';
import '../../domain/services/chat_management_service.dart';
import '../../domain/services/contact_management_service.dart';
import '../../domain/services/security_service_locator.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../services/security_manager.dart';
import '../../domain/services/mesh/mesh_network_health_monitor.dart';
import '../../domain/services/mesh/mesh_queue_sync_coordinator.dart';
import '../../domain/services/mesh/mesh_relay_coordinator.dart';
import '../../domain/interfaces/i_handshake_coordinator_factory.dart';
import '../../domain/interfaces/i_mesh_relay_engine_factory.dart';
import '../../domain/interfaces/i_service_registry.dart';
import '../../domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_connection_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_home_screen_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_chat_connection_manager_factory.dart';
import 'package:pak_connect/domain/interfaces/i_chat_list_coordinator_factory.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_export_service.dart';
import 'package:pak_connect/domain/interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/interfaces/i_import_service.dart';
import 'package:pak_connect/domain/interfaces/i_intro_hint_repository.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';
import '../bluetooth/handshake_coordinator_factory.dart';
import '../bluetooth/handshake_coordinator.dart';
import '../bluetooth/smart_handshake_manager.dart';
import '../messaging/mesh_relay_engine.dart';
import '../messaging/mesh_relay_engine_factory.dart';
import '../services/app_core_shared_message_queue_provider.dart';
import '../services/home_screen_facade_factory.dart';
import '../services/chat_connection_manager_factory.dart';
import '../services/chat_list_coordinator_factory.dart';
import 'app_services.dart';
import 'repository_provider_impl.dart';

/// GetIt service locator instance
final getIt = GetIt.instance;

/// Feature flag to enable/disable DI (for gradual migration)
const bool useDi = true;

final _logger = Logger('ServiceLocator');

class _GetItServiceRegistry implements IServiceRegistry {
  const _GetItServiceRegistry(this._getIt);

  final GetIt _getIt;

  @override
  bool isRegistered<T extends Object>() => _getIt.isRegistered<T>();

  @override
  T resolve<T extends Object>({String? dependencyName}) {
    if (_getIt.isRegistered<T>()) {
      return _getIt.get<T>();
    }

    final label = dependencyName ?? T.toString();
    throw StateError('$label is not registered in service locator');
  }

  @override
  T? maybeResolve<T extends Object>() {
    if (!_getIt.isRegistered<T>()) {
      return null;
    }
    return _getIt.get<T>();
  }

  @override
  void registerSingleton<T extends Object>(T instance) {
    _getIt.registerSingleton<T>(instance);
  }

  @override
  void registerLazySingleton<T extends Object>(T Function() factory) {
    _getIt.registerLazySingleton<T>(factory);
  }

  @override
  void unregister<T extends Object>() {
    if (_getIt.isRegistered<T>()) {
      _getIt.unregister<T>();
    }
  }
}

final IServiceRegistry _registry = _GetItServiceRegistry(getIt);

typedef DataLayerRegistrar = Future<void> Function(
  IServiceRegistry services,
  Logger logger,
);

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

    await registrar(_registry, _logger);

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
          contactRepository: getIt.get<IContactRepository>(),
          messageRepository: getIt.get<IMessageRepository>(),
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
    // We keep compatibility with the legacy static singleton accessor.
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

AppBootstrapServices resolveAppBootstrapServices() {
  return AppBootstrapServices(
    contactRepository: _registry.resolve<IContactRepository>(),
    messageRepository: _registry.resolve<IMessageRepository>(),
    archiveRepository: _registry.resolve<IArchiveRepository>(),
    chatsRepository: _registry.resolve<IChatsRepository>(),
    userPreferences: _registry.resolve<IUserPreferences>(),
    preferencesRepository: _registry.resolve<IPreferencesRepository>(),
    repositoryProvider: _registry.resolve<IRepositoryProvider>(),
    sharedMessageQueueProvider: _registry.resolve<ISharedMessageQueueProvider>(),
    databaseProvider: _registry.resolve<IDatabaseProvider>(),
    seenMessageStore: _registry.resolve<ISeenMessageStore>(),
    bleServiceFacadeFactory: _registry.resolve<IBLEServiceFacadeFactory>(),
    meshRelayEngineFactory: _registry.resolve<IMeshRelayEngineFactory>(),
    bleServiceFacade: _registry.maybeResolve<IBLEServiceFacade>(),
    groupRepository: _registry.maybeResolve<IGroupRepository>(),
    introHintRepository: _registry.maybeResolve<IIntroHintRepository>(),
    exportService: _registry.maybeResolve<IExportService>(),
    importService: _registry.maybeResolve<IImportService>(),
    homeScreenFacadeFactory: _registry.maybeResolve<IHomeScreenFacadeFactory>(),
    chatConnectionManagerFactory:
        _registry.maybeResolve<IChatConnectionManagerFactory>(),
    chatListCoordinatorFactory:
        _registry.maybeResolve<IChatListCoordinatorFactory>(),
  );
}

void publishAppServices(AppServices services) {
  AppRuntimeServicesRegistry.publish(services);
}

void clearPublishedAppServices() {
  AppRuntimeServicesRegistry.clear();
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
  _logger.info('📋 Publishing initialized runtime services...');

  try {
    SecurityServiceLocator.configureServiceResolver(() => securityService);
    AppRuntimeServicesRegistry.publishBindings(
      AppRuntimeBindings(
        securityService: securityService,
        connectionService: connectionService,
        meshNetworkingService: meshNetworkingService,
        meshRelayCoordinator: meshRelayCoordinator,
        meshQueueSyncCoordinator: meshQueueSyncCoordinator,
        meshHealthMonitor: meshHealthMonitor,
      ),
    );

    _logger.info(
      '✅ Initialized runtime services published outside GetIt',
    );
  } catch (e, stackTrace) {
    _logger.severe('❌ Failed to publish initialized runtime services', e, stackTrace);
    rethrow;
  }
}

/// Resets the service locator (useful for testing)
Future<void> resetServiceLocator() async {
  _logger.info('🔄 Resetting service locator...');
  ContactManagementService.clearDependencyResolvers();
  ArchiveManagementService.clearArchiveRepositoryResolver();
  ArchiveSearchService.clearArchiveRepositoryResolver();
  ChatManagementService.clearDependencyResolvers();
  SecurityServiceLocator.clearServiceResolver();
  SecurityManager.clearContactRepositoryResolver();
  HandshakeCoordinator.clearRepositoryProviderResolver();
  SmartHandshakeManager.clearRepositoryProviderResolver();
  MeshRelayEngine.clearDependencyResolvers();
  AppRuntimeServicesRegistry.clear();
  await getIt.reset();
  _logger.info('✅ Service locator reset complete');
}

/// Checks if a service is registered
bool isRegistered<T extends Object>() {
  return AppRuntimeServicesRegistry.has<T>() || getIt.isRegistered<T>();
}

T resolveRegistered<T extends Object>({String? dependencyName}) {
  final runtimeValue = AppRuntimeServicesRegistry.maybeResolve<T>();
  if (runtimeValue != null) {
    return runtimeValue;
  }
  return _registry.resolve<T>(dependencyName: dependencyName);
}

T? maybeResolveRegistered<T extends Object>() {
  final runtimeValue = AppRuntimeServicesRegistry.maybeResolve<T>();
  return runtimeValue ?? _registry.maybeResolve<T>();
}
