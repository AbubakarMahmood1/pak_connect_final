import 'offline_message_queue_platform_bootstrap_stub.dart'
    if (dart.library.io) 'offline_message_queue_platform_bootstrap_io.dart'
    as bootstrap;

Future<void> ensureOfflineQueueDatabaseFactoryReady() =>
    bootstrap.ensureOfflineQueueDatabaseFactoryReady();
