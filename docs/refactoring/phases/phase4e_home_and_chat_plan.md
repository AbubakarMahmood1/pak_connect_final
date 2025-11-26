# Phase 4E: Home/Chat Controller Refactor – Target Architecture (Milestone 1)

## Objectives
- Replace the remaining ChangeNotifier controllers with Riverpod-driven ViewModels while keeping behavior identical.
- Reduce `chat_screen_controller.dart` (1149 LOC) by isolating state, subscriptions, and UI helpers into testable units.
- Preserve BLE/Noise/mesh invariants (handshake sequencing, duplicate detection, message ID determinism) and keep backward-compatible facades until widgets are migrated.

## Current Pain Points
- ChatScreenController owns state, subscriptions, retry wiring, pairing flows, and UI helpers in one class.
- HomeScreenController mixes paging/search with BLE/discovery listeners and facade wiring.
- Manual StreamSubscription management increases leak risk; Riverpod providers exist but aren’t leveraged here.

## Target Structure (no behavior changes)
- `ChatSessionViewModel` (Riverpod Notifier)
  - Holds `ChatUIState` (messages, delivery state, typing, scroll intent).
  - Exposes commands: send/retry/delete, scroll-to-bottom intent, search trigger, mark-read.
  - Injects `ChatMessagingViewModel`, `ChatScrollingController`, `ChatSearchController`.
- `ChatSessionLifecycle` (service class)
  - Manages message/delivery subscriptions, repository retry handler, pairing dialog hooks, persistent chat load/save.
  - Owns retry helper wiring (uses existing `ChatRetryHelper`), buffers until initialized, respects connection state.
- `ChatScreenController` (compatibility facade)
  - Thin bridge for legacy widget entry points; delegates to ViewModel/Lifecycle; kept during migration, then deprecated.
- `HomeScreenViewModel` (Riverpod Notifier)
  - Paging/search state, performance markers, unread count stream exposure, nearby-device awareness.
  - Coordinates with `HomeScreenFacade` and `ChatManagementService` for initialization and refresh.
- `ChatListController` (helper/adapter)
  - Pure list transforms (filters, sorting, dedupe, merging discovery data); unit-testable without BLE.

## Provider Plan
- Add Riverpod providers for the new ViewModels/Lifecycle objects; keep existing `ble_providers.dart` wiring as the injection point for connection services, repositories, and facades.
- Preserve legacy constructors while widgets migrate; deprecate only after UI is switched to providers.

## Invariants to Protect
- Noise/BLE phases remain untouched: no encryption before handshake completion; MTU negotiation stays in Phase 0; relay delivery before forwarding; sequential nonces and replay protection intact.
- Identity resolution: use `persistentPublicKey ?? publicKey`; `Contact.publicKey` is immutable.
- Message ID generation and duplicate window (5 minutes) remain unchanged.
- No new StreamControllers; reuse Riverpod streams or existing injected streams.

## Testing Strategy (for later milestones)
- Unit tests for ViewModels (state transitions, commands) and ChatSessionLifecycle (subscription + retry flow with fakes).
- Widget/riverpod integration tests for ChatScreen and HomeScreen to ensure behavior parity (send, retry, paging, search, unread count).
- Regression checks on scroll-to-bottom triggers, pairing dialog flow, and retry backoffs.

## Definition of Done for Phase 4E (future milestones)
- ChatScreen and HomeScreen consume new providers; ChangeNotifier controllers removed or only thin facades.
- No manual subscription leaks; disposal verified in tests.
- UI behavior matches pre-refactor (message load/send/retry, paging/search/unread counts, pairing prompts).

## Milestone 2: ChatScreen Extraction Plan (detailed)
- **Current responsibilities (chat_screen_controller.dart, 1149 LOC)**
  - Initialization & persistence: loads messages, syncs unread counts, persists scroll state, buffers incoming until ready.
  - Messaging flows: send/retry/delete via `ChatMessagingViewModel`, `MessageRetryCoordinator`, repository retry handler, and mesh/router paths.
  - Subscriptions: connectionService `receivedMessages`, mesh delivery stream, retry auto-trigger, scroll events, pairing dialog callbacks.
  - Context/identity: calculates chatId, caches contact public key, handles chatId migration + message migration.
  - UI helpers: scroll-to-bottom, unread separator, search navigation, toast/log helpers.
  - Pairing flow: delegates to `ChatPairingDialogController`, with guardrails for connection state.
  - Lifecycle: manages timers/subscriptions disposal; tracks `_disposed` and `_initialized`.
- **Extraction seams**
  - `ChatSessionViewModel` (Riverpod Notifier)
    - Owns `ChatUIState`, chatId, contact display name; exposes commands: send, delete, mark-read, scroll intent, retry trigger.
    - Pure state transitions; no direct StreamSubscriptions.
  - `ChatSessionLifecycle`
    - Owns subscriptions (message, delivery), buffering, initialization timeout, retry wiring, pairing hooks, persistent chat load/save.
    - Calls into ViewModel and keeps `ChatRetryHelper` + repository retry handler intact.
  - `ChatScreenController` facade
    - Thin bridge for legacy consumers; delegates to ViewModel/Lifecycle; slated for removal post-widget migration.
- **Provider wiring (no behavior change)**
  - Add providers for `ChatSessionViewModel` and `ChatSessionLifecycle` backed by existing repo/services from `ble_providers.dart`.
  - Keep current constructor paths functioning; controllers can resolve providers internally during migration.
- **Migration steps (safe, incremental)**
  1) Scaffold new classes/providers with dependency injection signatures only; keep existing controller untouched.
  2) Move pure state mutation helpers (_updateMessageStatus, _upsertMessage, scroll intents) into ViewModel; have controller call through.
  3) Move subscription setup/teardown and buffering into Lifecycle; controller delegates but retains public API.
  4) Swap ChatScreen widget to use providers; retain facade shims for tests/legacy paths; then remove duplicate fields.
  5) Add unit tests for ViewModel and Lifecycle (Arrange-Act-Assert) and widget/provider integration tests for ChatScreen.
- **Risk controls**
  - Preserve sequencing: do not change initialization order (retry coordinator before subscriptions; message buffer flushed after init).
  - Keep repository retry handler behavior and mesh/send fallbacks identical.
  - Maintain pairing safeguards (blocked when disconnected; respect handshake state).
  - Ensure scroll controller disposal ordering remains safe to avoid Flutter scroll errors.

## Milestone 2 status (scaffolding complete)
- Added scaffolding classes (no behavior change):
  - `lib/presentation/viewmodels/chat_session_view_model.dart`
  - `lib/presentation/controllers/chat_session_lifecycle.dart`
  - Provider families: `lib/presentation/providers/chat_session_providers.dart`
- Began delegation: message-state helpers (`applyMessageStatus`, `applyMessageUpdate`, scroll state sync) now live in `ChatSessionViewModel`; `ChatScreenController` calls them while retaining its state/notifications.
- Continued delegation: search mode/query, loading flag, message list updates, append/remove message helpers, unread count updates, mesh status banners, and "clear new while scrolled up" now flow through `ChatSessionViewModel`. Retry flows now update UI state via the ViewModel helpers as well.
- Lifecycle integration started: delivery subscription routed through `ChatSessionLifecycle`; lifecycle now tracks managed subscriptions and provides buffering/flush helpers. Controller now writes/flushes via lifecycle buffers while keeping the same listener branching (persistent chat manager vs direct stream). Mesh initialization status/timeout handling routed through lifecycle helpers. Direct message stream subscription uses lifecycle attachment (controller still decides persistent-vs-direct path).
- Auto-retry scheduling: connection-change delayed auto-retries now scheduled through `ChatSessionLifecycle` timers (same delays/guards).
- Retry helper ownership & orchestration: controller initializes `ChatRetryHelper`, lifecycle owns the reference and now exposes auto/fallback retry methods; controller delegates calls.
- Persistent listener handling: controller sets lifecycle’s `persistentChatManager` and delegates register/unregister and stream setup to lifecycle (behavior preserved, including existing persistent-vs-direct branching).
- Compatibility providers: added providers to access `ChatSessionViewModel` and `ChatSessionLifecycle` via the existing `chatScreenControllerProvider` so widgets can migrate incrementally without touching ChangeNotifier internals.
- ChatScreen opt-in: `ChatScreen` now accepts `useSessionProviders` (default false) to pre-resolve the provider-backed session objects during incremental migration; default path remains unchanged.
- Added `chatSessionStateFromControllerProvider` so widgets can read `ChatUIState` via providers while still driven by the legacy controller (step toward provider-only wiring).
- ChatScreen now pre-watches ViewModel/Lifecycle providers when `useSessionProviders` is true (still unused for behavior to keep parity); next step is to bind UI/actions to providers under the opt-in flag.
- Partial UI binding: when `useSessionProviders` is true, ChatScreen now uses the provider-resolved search/scroll controllers and state (same underlying instances) to keep parity while exercising the provider path.
- Actions routed via provider facade: send/delete/toggle search now call through `chatSessionActionsFromControllerProvider` when opt-in is enabled (still backed by the controller for parity).
- Reconnect action routed via provider facade under opt-in (still same controller implementation).
- Retry action routed via provider facade under opt-in; default path unchanged.
- Pairing/contact sync actions routed via provider facade under opt-in (same controller impl beneath).
- Scroll-to-bottom action now uses provider facade under opt-in (same controller impl beneath).
- Connection/mesh listeners now call through the provider facade under opt-in (still the same controller implementations).
- Provider-backed state notifier (`chatSessionStateNotifierProvider`) is defined in `lib/presentation/notifiers/chat_session_state_notifier.dart` and used in opt-in mode to mirror controller state for provider consumers. Owned state notifier scaffolded; controller now publishes state into it for future provider ownership.
- Aggregated handle provider (`chatSessionHandleProvider`) supplies state, actions, view model, and lifecycle for the opt-in path to simplify binding and keep parity.
- `ChatScreen.useSessionProviders` now defaults to true (provider path default); ChangeNotifier remains as underlying shim until fully retired.
- Local controller state is now a fallback only; publishes to owned notifier for provider-first reads. Remaining cleanup (M3): remove ChangeNotifier shim after parity tests.
- Milestone 2 (ChatScreen extraction) is functionally complete: provider-backed path is default, owned notifier supplies UI state, and all actions/listeners route through provider facades. Remaining cleanup is Milestone 3 work (remove ChangeNotifier shim after parity tests).

## Milestone 3: Flip ChatScreen to providers (plan)
- When `useSessionProviders` is true, swap UI bindings to read from `ChatSessionViewModel`/Lifecycle providers instead of the ChangeNotifier controller.
- Introduce a Notifier-backed session state holder (or have the controller publish state into the ViewModel) so provider reads reflect live state.
- Keep controller as a thin facade during rollout; deprecate it after widgets no longer consume ChangeNotifier.
- Add widget/provider integration tests for the provider-backed path (send, retry, search, scroll, pairing prompts).
- Remaining tasks before default flip:
  - Move connection/mesh listeners to lifecycle/provider under opt-in.
  - Publish state into a Riverpod Notifier (or migrate ChatUIState ownership) so providers own state.
  - Switch UI actions (retry/pairing already routed) to provider-owned implementations once state migrates.
  - Remove ChangeNotifier-only entrypoints after parity tests pass.
  - Make the owned notifier the single source of truth (stop mirroring; have controller consume or be removed), then set provider path as default.
- Provider wiring plan (pending flip):
  - Use `chatSessionViewModelProvider` + `chatSessionLifecycleProvider` with dependencies from `ble_providers.dart` and `mesh_networking_provider.dart`.
  - Keep `ChatScreenController` as facade until widgets are switched to providers; then deprecate legacy ChangeNotifier path.
- Next change: migrate additional pure helpers and subscription orchestration into ViewModel/Lifecycle while keeping the controller as the public entry point until widget wiring flips to providers.
