import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import '../../data/services/ble_service.dart';
import '../../data/services/seen_message_store.dart';
import '../../domain/services/mesh_networking_service.dart';
import '../../core/services/security_manager.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/archive_repository.dart';
import '../../data/repositories/chats_repository.dart';
import '../../data/repositories/preferences_repository.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/intro_hint_repository.dart';
import '../interfaces/i_repository_provider.dart';
import '../interfaces/i_seen_message_store.dart';
import '../interfaces/i_archive_repository.dart';
import '../interfaces/i_chats_repository.dart';
import '../interfaces/i_preferences_repository.dart';
import '../interfaces/i_group_repository.dart';
import '../interfaces/i_intro_hint_repository.dart';
import 'repository_provider_impl.dart';

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
/// **Phase 1 Part C**: Services are registered as singletons but initialized by AppCore
/// in correct dependency order (not at registration time).
Future<void> setupServiceLocator() async {
  _logger.info('🎯 Setting up service locator...');

  if (!USE_DI) {
    _logger.warning('⚠️ DI is disabled via USE_DI flag');
    return;
  }

  try {
    // If repositories are already registered, assume setup already ran.
    if (getIt.isRegistered<ContactRepository>() &&
        getIt.isRegistered<MessageRepository>() &&
        getIt.isRegistered<IRepositoryProvider>() &&
        getIt.isRegistered<ISeenMessageStore>()) {
      _logger.info(
        'ℹ️ Service locator already initialized — skipping re-registration',
      );
      return;
    }

    // ===========================
    // REPOSITORIES
    // ===========================
    // Register IContactRepository singleton
    if (!getIt.isRegistered<ContactRepository>()) {
      getIt.registerSingleton<ContactRepository>(ContactRepository());
      _logger.fine('✅ ContactRepository registered');
    } else {
      _logger.fine('ℹ️ ContactRepository already registered');
    }

    // Register IMessageRepository singleton
    if (!getIt.isRegistered<MessageRepository>()) {
      getIt.registerSingleton<MessageRepository>(MessageRepository());
      _logger.fine('✅ MessageRepository registered');
    } else {
      _logger.fine('ℹ️ MessageRepository already registered');
    }

    // Register ArchiveRepository singleton
    if (!getIt.isRegistered<ArchiveRepository>()) {
      getIt.registerSingleton<ArchiveRepository>(ArchiveRepository.instance);
      _logger.fine('✅ ArchiveRepository registered');
    } else {
      _logger.fine('ℹ️ ArchiveRepository already registered');
    }

    // Register ChatsRepository singleton
    if (!getIt.isRegistered<ChatsRepository>()) {
      getIt.registerSingleton<ChatsRepository>(ChatsRepository());
      _logger.fine('✅ ChatsRepository registered');
    } else {
      _logger.fine('ℹ️ ChatsRepository already registered');
    }

    // Register PreferencesRepository singleton
    if (!getIt.isRegistered<PreferencesRepository>()) {
      getIt.registerSingleton<PreferencesRepository>(PreferencesRepository());
      _logger.fine('✅ PreferencesRepository registered');
    } else {
      _logger.fine('ℹ️ PreferencesRepository already registered');
    }

    // Register GroupRepository singleton
    if (!getIt.isRegistered<GroupRepository>()) {
      getIt.registerSingleton<GroupRepository>(GroupRepository());
      _logger.fine('✅ GroupRepository registered');
    } else {
      _logger.fine('ℹ️ GroupRepository already registered');
    }

    // Register IntroHintRepository singleton
    if (!getIt.isRegistered<IntroHintRepository>()) {
      getIt.registerSingleton<IntroHintRepository>(IntroHintRepository());
      _logger.fine('✅ IntroHintRepository registered');
    } else {
      _logger.fine('ℹ️ IntroHintRepository already registered');
    }

    // ===========================
    // REPOSITORY INTERFACES (Phase 3 abstraction)
    // ===========================
    // Register IArchiveRepository for dependency injection
    if (!getIt.isRegistered<IArchiveRepository>()) {
      getIt.registerSingleton<IArchiveRepository>(getIt<ArchiveRepository>());
      _logger.fine('✅ IArchiveRepository registered (Phase 3)');
    }

    // Register IChatsRepository for dependency injection
    if (!getIt.isRegistered<IChatsRepository>()) {
      getIt.registerSingleton<IChatsRepository>(getIt<ChatsRepository>());
      _logger.fine('✅ IChatsRepository registered (Phase 3)');
    }

    // Register IPreferencesRepository for dependency injection
    if (!getIt.isRegistered<IPreferencesRepository>()) {
      getIt.registerSingleton<IPreferencesRepository>(
        getIt<PreferencesRepository>(),
      );
      _logger.fine('✅ IPreferencesRepository registered (Phase 3)');
    }

    // Register IGroupRepository for dependency injection
    if (!getIt.isRegistered<IGroupRepository>()) {
      getIt.registerSingleton<IGroupRepository>(getIt<GroupRepository>());
      _logger.fine('✅ IGroupRepository registered (Phase 3)');
    }

    // Register IIntroHintRepository for dependency injection
    if (!getIt.isRegistered<IIntroHintRepository>()) {
      getIt.registerSingleton<IIntroHintRepository>(
        getIt<IntroHintRepository>(),
      );
      _logger.fine('✅ IIntroHintRepository registered (Phase 3)');
    }

    // ===========================
    // REPOSITORY PROVIDER (Phase 3 abstraction)
    // ===========================
    // Register IRepositoryProvider singleton for Core layer DI
    // This allows Core services to depend on repositories through abstraction
    // instead of direct imports (fixes layer violations)
    if (!getIt.isRegistered<IRepositoryProvider>()) {
      getIt.registerSingleton<IRepositoryProvider>(
        RepositoryProviderImpl(
          contactRepository: getIt<ContactRepository>(),
          messageRepository: getIt<MessageRepository>(),
        ),
      );
      _logger.fine('✅ IRepositoryProvider registered (Phase 3)');
    } else {
      _logger.fine('ℹ️ IRepositoryProvider already registered');
    }

    // ===========================
    // SEEN MESSAGE STORE (Phase 3 abstraction)
    // ===========================
    // Register ISeenMessageStore singleton for Core layer DI
    // SeenMessageStore.instance is already a singleton, we wrap it
    if (!getIt.isRegistered<ISeenMessageStore>()) {
      getIt.registerSingleton<ISeenMessageStore>(SeenMessageStore.instance);
      _logger.fine('✅ ISeenMessageStore registered (Phase 3)');
    } else {
      _logger.fine('ℹ️ ISeenMessageStore already registered');
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
  required SecurityManager securityManager,
  required BLEService bleService,
  required MeshNetworkingService meshNetworkingService,
}) {
  _logger.info('📋 Registering initialized services...');

  try {
    // Register SecurityManager singleton
    getIt.registerSingleton<SecurityManager>(securityManager);
    _logger.fine('✅ SecurityManager registered in DI container');

    // Register BLEService singleton
    getIt.registerSingleton<BLEService>(bleService);
    _logger.fine('✅ BLEService registered in DI container');

    // Register MeshNetworkingService singleton
    getIt.registerSingleton<MeshNetworkingService>(meshNetworkingService);
    _logger.fine('✅ MeshNetworkingService registered in DI container');

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
