import '../../domain/interfaces/i_notification_handler.dart';
import '../../domain/interfaces/i_preferences_repository.dart';
import 'notification_service.dart';

INotificationHandler createPlatformBackgroundNotificationHandler({
  required IPreferencesRepository preferencesRepository,
}) =>
    ForegroundNotificationHandler(preferencesRepository: preferencesRepository);
