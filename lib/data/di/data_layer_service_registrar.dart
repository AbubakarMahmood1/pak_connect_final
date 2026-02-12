import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_provider.dart';
import 'package:pak_connect/data/repositories/archive_repository.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/group_repository.dart';
import 'package:pak_connect/data/repositories/intro_hint_repository.dart';
import 'package:pak_connect/data/repositories/message_repository.dart';
import 'package:pak_connect/data/repositories/preferences_repository.dart';
import 'package:pak_connect/data/repositories/user_preferences.dart';
import 'package:pak_connect/data/services/ble_message_handler.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade.dart';
import 'package:pak_connect/data/services/ble_message_handler_facade_impl.dart';
import 'package:pak_connect/data/services/ble_handshake_service.dart';
import 'package:pak_connect/data/services/ble_service_facade.dart';
import 'package:pak_connect/data/services/ble_service_facade_factory.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'package:pak_connect/data/services/ble_state_manager_facade.dart';
import 'package:pak_connect/data/services/ephemeral_contact_cleaner.dart';
import 'package:pak_connect/data/services/export_import/export_service_adapter.dart';
import 'package:pak_connect/data/services/export_import/import_service_adapter.dart';
import 'package:pak_connect/data/services/mesh_routing_service.dart';
import 'package:pak_connect/data/services/mesh_relay_handler.dart';
import 'package:pak_connect/data/services/protocol_message_handler.dart';
import 'package:pak_connect/data/services/relay_coordinator.dart';
import 'package:pak_connect/data/services/seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_message_handler_facade.dart';
import 'package:pak_connect/domain/interfaces/i_ble_service_facade_factory.dart';
import 'package:pak_connect/domain/interfaces/i_ble_state_manager_facade.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_database_provider.dart';
import 'package:pak_connect/domain/interfaces/i_export_service.dart';
import 'package:pak_connect/domain/interfaces/i_group_repository.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/interfaces/i_import_service.dart';
import 'package:pak_connect/domain/interfaces/i_intro_hint_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_queue_repository.dart';
import 'package:pak_connect/domain/interfaces/i_handshake_coordinator_factory.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/interfaces/i_mesh_routing_service.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/interfaces/i_user_preferences.dart';

/// Registers concrete data-layer implementations into [GetIt].
///
/// Core DI setup should call this hook instead of importing concrete data types.
Future<void> registerDataLayerServices(GetIt getIt, Logger logger) async {
  BLEHandshakeService.configureCoordinatorFactoryResolver(
    () => getIt.get<IHandshakeCoordinatorFactory>(),
  );
  BLEServiceFacade.configureHandshakeServiceRegistrar((handshakeService) {
    if (!getIt.isRegistered<IBLEHandshakeService>()) {
      getIt.registerSingleton<IBLEHandshakeService>(handshakeService);
    }
  });
  BLEMessageHandlerFacade.configureDependencyResolvers(
    handshakeServiceResolver: () {
      if (getIt.isRegistered<IBLEHandshakeService>()) {
        return getIt.get<IBLEHandshakeService>();
      }
      return null;
    },
    seenMessageStoreResolver: () {
      if (getIt.isRegistered<ISeenMessageStore>()) {
        return getIt.get<ISeenMessageStore>();
      }
      return null;
    },
  );
  BLEMessageHandlerFacadeImpl.configureDependencyResolvers(
    legacyStateManagerResolver: () {
      if (getIt.isRegistered<BLEStateManagerFacade>()) {
        return getIt.get<BLEStateManagerFacade>().legacyStateManager;
      }
      if (getIt.isRegistered<IBLEStateManagerFacade>()) {
        final facade = getIt.get<IBLEStateManagerFacade>();
        if (facade is BLEStateManagerFacade) {
          return facade.legacyStateManager;
        }
      }
      if (getIt.isRegistered<BLEStateManager>()) {
        return getIt.get<BLEStateManager>();
      }
      return null;
    },
    sharedQueueProviderResolver: () {
      if (getIt.isRegistered<ISharedMessageQueueProvider>()) {
        return getIt.get<ISharedMessageQueueProvider>();
      }
      return null;
    },
  );
  ProtocolMessageHandler.configureIdentityManagerResolver(() {
    if (getIt.isRegistered<IIdentityManager>()) {
      return getIt.get<IIdentityManager>();
    }
    return null;
  });
  RelayCoordinator.configureDependencyResolvers(
    sharedQueueProviderResolver: () {
      if (getIt.isRegistered<ISharedMessageQueueProvider>()) {
        return getIt.get<ISharedMessageQueueProvider>();
      }
      return null;
    },
    relayEngineFactoryResolver: () => getIt.get<IMeshRelayEngineFactory>(),
  );
  MeshRelayHandler.configureRelayEngineFactoryResolver(
    () => getIt.get<IMeshRelayEngineFactory>(),
  );
  EphemeralContactCleaner.configureQueueRepositoryResolver(() {
    if (getIt.isRegistered<IMessageQueueRepository>()) {
      return getIt.get<IMessageQueueRepository>();
    }
    return null;
  });

  // ===========================
  // REPOSITORIES
  // ===========================
  if (!getIt.isRegistered<ContactRepository>()) {
    getIt.registerSingleton<ContactRepository>(ContactRepository());
    logger.fine('✅ ContactRepository registered');
  } else {
    logger.fine('ℹ️ ContactRepository already registered');
  }

  if (!getIt.isRegistered<IContactRepository>()) {
    getIt.registerSingleton<IContactRepository>(getIt.get<ContactRepository>());
    logger.fine('✅ IContactRepository registered (data registrar)');
  }

  if (!getIt.isRegistered<MessageRepository>()) {
    getIt.registerSingleton<MessageRepository>(MessageRepository());
    logger.fine('✅ MessageRepository registered');
  } else {
    logger.fine('ℹ️ MessageRepository already registered');
  }

  if (!getIt.isRegistered<IMessageRepository>()) {
    getIt.registerSingleton<IMessageRepository>(getIt.get<MessageRepository>());
    logger.fine('✅ IMessageRepository registered (data registrar)');
  }

  if (!getIt.isRegistered<ArchiveRepository>()) {
    getIt.registerSingleton<ArchiveRepository>(ArchiveRepository());
    logger.fine('✅ ArchiveRepository registered');
  } else {
    logger.fine('ℹ️ ArchiveRepository already registered');
  }

  if (!getIt.isRegistered<ChatsRepository>()) {
    getIt.registerSingleton<ChatsRepository>(ChatsRepository());
    logger.fine('✅ ChatsRepository registered');
  } else {
    logger.fine('ℹ️ ChatsRepository already registered');
  }

  if (!getIt.isRegistered<PreferencesRepository>()) {
    getIt.registerSingleton<PreferencesRepository>(PreferencesRepository());
    logger.fine('✅ PreferencesRepository registered');
  } else {
    logger.fine('ℹ️ PreferencesRepository already registered');
  }

  if (!getIt.isRegistered<GroupRepository>()) {
    getIt.registerSingleton<GroupRepository>(GroupRepository());
    logger.fine('✅ GroupRepository registered');
  } else {
    logger.fine('ℹ️ GroupRepository already registered');
  }

  if (!getIt.isRegistered<IntroHintRepository>()) {
    getIt.registerSingleton<IntroHintRepository>(IntroHintRepository());
    logger.fine('✅ IntroHintRepository registered');
  } else {
    logger.fine('ℹ️ IntroHintRepository already registered');
  }

  if (!getIt.isRegistered<MeshRoutingService>()) {
    getIt.registerSingleton<MeshRoutingService>(MeshRoutingService());
    logger.fine('✅ MeshRoutingService registered');
  } else {
    logger.fine('ℹ️ MeshRoutingService already registered');
  }

  // ===========================
  // INTERFACE BINDINGS
  // ===========================
  if (!getIt.isRegistered<IMeshRoutingService>()) {
    getIt.registerSingleton<IMeshRoutingService>(getIt.get<MeshRoutingService>());
    logger.fine('✅ IMeshRoutingService registered');
  }

  if (!getIt.isRegistered<IArchiveRepository>()) {
    getIt.registerSingleton<IArchiveRepository>(getIt.get<ArchiveRepository>());
    logger.fine('✅ IArchiveRepository registered');
  }

  if (!getIt.isRegistered<IChatsRepository>()) {
    getIt.registerSingleton<IChatsRepository>(getIt.get<ChatsRepository>());
    logger.fine('✅ IChatsRepository registered');
  }

  if (!getIt.isRegistered<IPreferencesRepository>()) {
    getIt.registerSingleton<IPreferencesRepository>(
      getIt.get<PreferencesRepository>(),
    );
    logger.fine('✅ IPreferencesRepository registered');
  }

  if (!getIt.isRegistered<IUserPreferences>()) {
    getIt.registerSingleton<IUserPreferences>(UserPreferences());
    logger.fine('✅ IUserPreferences registered');
  }

  if (!getIt.isRegistered<IGroupRepository>()) {
    getIt.registerSingleton<IGroupRepository>(getIt.get<GroupRepository>());
    logger.fine('✅ IGroupRepository registered');
  }

  if (!getIt.isRegistered<IIntroHintRepository>()) {
    getIt.registerSingleton<IIntroHintRepository>(getIt.get<IntroHintRepository>());
    logger.fine('✅ IIntroHintRepository registered');
  }

  if (!getIt.isRegistered<IExportService>()) {
    getIt.registerLazySingleton<IExportService>(
      () => const ExportServiceAdapter(),
    );
    logger.fine('✅ IExportService registered');
  }

  if (!getIt.isRegistered<IImportService>()) {
    getIt.registerLazySingleton<IImportService>(
      () => const ImportServiceAdapter(),
    );
    logger.fine('✅ IImportService registered');
  }

  if (!getIt.isRegistered<ISeenMessageStore>()) {
    getIt.registerSingleton<ISeenMessageStore>(SeenMessageStore());
    logger.fine('✅ ISeenMessageStore registered');
  }

  if (!getIt.isRegistered<IDatabaseProvider>()) {
    getIt.registerSingleton<IDatabaseProvider>(DatabaseProvider());
    logger.fine('✅ IDatabaseProvider registered');
  }

  if (!getIt.isRegistered<ISharedMessageQueueProvider>()) {
    throw StateError(
      'ISharedMessageQueueProvider must be registered before data services.',
    );
  }

  if (!getIt.isRegistered<IBLEMessageHandlerFacade>()) {
    getIt.registerLazySingleton<IBLEMessageHandlerFacade>(
      () => BLEMessageHandlerFacadeImpl(
        BLEMessageHandler(),
        getIt.get<ISeenMessageStore>(),
        sharedQueueProvider: getIt.get<ISharedMessageQueueProvider>(),
      ),
    );
    logger.fine('✅ IBLEMessageHandlerFacade registered');
  }

  if (!getIt.isRegistered<IBLEServiceFacadeFactory>()) {
    getIt.registerLazySingleton<IBLEServiceFacadeFactory>(
      () => const DataBleServiceFacadeFactory(),
    );
    logger.fine('✅ IBLEServiceFacadeFactory registered');
  }
}

