// Enhanced main.dart with comprehensive feature integration and proper initialization

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // Added for kDebugMode
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

import 'core/app_core.dart';
import 'core/utils/app_logger.dart';
import 'core/services/navigation_service.dart';
import 'presentation/theme/app_theme.dart';
import 'presentation/screens/permission_screen.dart';
import 'presentation/screens/home_screen.dart';
import 'presentation/screens/group_list_screen.dart';
import 'presentation/screens/create_group_screen.dart';
import 'presentation/screens/group_chat_screen.dart';
import 'presentation/screens/chat_screen.dart';
import 'presentation/screens/contacts_screen.dart';
import 'presentation/providers/ble_providers.dart';
import 'presentation/providers/theme_provider.dart';
import 'presentation/widgets/spy_mode_listener.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Setup logging with AppLogger (handles debug/release modes automatically)
  AppLogger.initialize();

  runApp(const ProviderScope(child: PakConnectApp()));
}

class PakConnectApp extends ConsumerWidget {
  const PakConnectApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch theme mode from persistent settings
    final themeMode = ref.watch(themeModeProvider);

    return SpyModeListener(
      child: MaterialApp(
        title: 'PakConnect - Enhanced Secure Messaging',

        // Global navigator key for background navigation (e.g., from notifications)
        navigatorKey: NavigationService.navigatorKey,

        // Enhanced Material Design 3.0 theme with dark/light support
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeMode, // Uses persistent user preference
        // Accessibility and internationalization
        debugShowCheckedModeBanner: false,

        // Enhanced navigation with theme support
        home: const AppWrapper(),

        // Named routes for navigation
        routes: {
          '/groups': (context) => const GroupListScreen(),
          '/create-group': (context) => const CreateGroupScreen(),
        },
        onGenerateRoute: (settings) {
          // Handle routes with arguments
          if (settings.name == '/group-chat') {
            final groupId = settings.arguments as String;
            return MaterialPageRoute(
              builder: (context) => GroupChatScreen(groupId: groupId),
            );
          }
          return null;
        },

        // Theme transitions
        themeAnimationDuration: const Duration(milliseconds: 300),
        themeAnimationCurve: Curves.easeInOut,
      ),
    );
  }
}

class AppWrapper extends ConsumerStatefulWidget {
  const AppWrapper({super.key});

  @override
  ConsumerState<AppWrapper> createState() => _AppWrapperState();
}

class _AppWrapperState extends ConsumerState<AppWrapper>
    with WidgetsBindingObserver {
  static final _logger = Logger('AppWrapper');
  bool _initializationStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _logger.info('Enhanced PakConnect app started with comprehensive features');
    _initializeApp();
  }

  /// Initialize the app core properly
  void _initializeApp() {
    if (_initializationStarted) return;
    _initializationStarted = true;

    _logger.info('Starting app initialization...');

    // Initialize on the next frame to ensure widget is built
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await AppCore.instance.initialize();
        _logger.info('✅ App core initialized successfully from AppWrapper');

        // 🧭 Register navigation callbacks (fix Core → Presentation layer violation)
        NavigationService.setChatScreenBuilder(
          ({
            required String chatId,
            required String contactName,
            required String contactPublicKey,
          }) => ChatScreen.fromChatData(
            chatId: chatId,
            contactName: contactName,
            contactPublicKey: contactPublicKey,
          ),
        );

        NavigationService.setContactsScreenBuilder(
          () => const ContactsScreen(),
        );
        _logger.info('✅ Navigation callbacks registered');
      } catch (e) {
        _logger.severe('❌ Failed to initialize app core from AppWrapper: $e');
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppCore.instance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Only interact with power manager if initialized
    if (AppCore.instance.isInitialized) {
      // Fixed: use isInitialized getter
      switch (state) {
        case AppLifecycleState.paused:
          _logger.info(
            'App paused - power management handled by burst scanning controller',
          );
          // Note: Power management is now handled automatically by BurstScanningController
          break;
        case AppLifecycleState.resumed:
          _logger.info(
            'App resumed - power management handled by burst scanning controller',
          );
          // Note: Power management is now handled automatically by BurstScanningController
          break;
        case AppLifecycleState.detached:
          _logger.info('App detached - performing cleanup');
          AppCore.instance.dispose();
          break;
        default:
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<AppStatus>(
      stream: AppCore.instance.statusStream,
      initialData: AppStatus.initializing, // Set proper initial data
      builder: (context, snapshot) {
        final status = snapshot.data ?? AppStatus.initializing;

        _logger.info('Current app status: $status');

        switch (status) {
          case AppStatus.initializing:
            return _buildLoadingScreen(theme);
          case AppStatus.error:
            return _buildErrorScreen(theme);
          case AppStatus.ready:
          case AppStatus.running:
            return _buildAppWithBurstScanning();
          case AppStatus.disposing:
            return _buildDisposingScreen(theme);
        }
      },
    );
  }

  /// Build loading screen during initialization
  Widget _buildLoadingScreen(ThemeData theme) {
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App logo/icon
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                Icons.message,
                size: 60,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),

            const SizedBox(height: 32),

            Text(
              'PakConnect',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),

            const SizedBox(height: 8),

            Text(
              'Secure • Private • Battery Efficient',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 48),

            // Enhanced loading indicator
            SizedBox(
              width: 200,
              child: Column(
                children: [
                  LinearProgressIndicator(
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(
                      theme.colorScheme.primary,
                    ),
                  ),

                  const SizedBox(height: 16),

                  Text(
                    'Initializing enhanced security and power management...',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 16),

                  // Debug info in debug mode
                  if (kDebugMode)
                    Text(
                      'Status: initializing...',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(),
                      ),
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build error screen
  Widget _buildErrorScreen(ThemeData theme) {
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 80, color: theme.colorScheme.error),

            const SizedBox(height: 24),

            Text(
              'Initialization Failed',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),

            const SizedBox(height: 16),

            Text(
              'Failed to initialize enhanced messaging features.\nCheck logs for details.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 32),

            FilledButton.icon(
              onPressed: () async {
                try {
                  _logger.info('Retrying initialization...');
                  await AppCore.instance.initialize();
                } catch (e) {
                  _logger.severe('Retry initialization failed: $e');
                }
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry Initialization'),
            ),
          ],
        ),
      ),
    );
  }

  /// Build disposing screen
  Widget _buildDisposingScreen(ThemeData theme) {
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: theme.colorScheme.primary),

            const SizedBox(height: 24),

            Text(
              'Shutting down...',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build app with burst scanning eagerly initialized and smart navigation
  Widget _buildAppWithBurstScanning() {
    return Consumer(
      builder: (context, ref, child) {
        // Eagerly initialize burst scanning
        ref.watch(eagerBurstScanningProvider);

        // Check BLE state to determine initial screen
        final bleStateAsync = ref.watch(bleStateProvider);

        return bleStateAsync.when(
          data: (state) {
            // If Bluetooth is already ready, skip permission screen
            if (state == BluetoothLowEnergyState.poweredOn) {
              return const HomeScreen();
            }
            // Otherwise show permission screen
            return const PermissionScreen();
          },
          loading: () => _buildLoadingScreen(Theme.of(context)),
          error: (error, stack) => const PermissionScreen(),
        );
      },
    );
  }
}
