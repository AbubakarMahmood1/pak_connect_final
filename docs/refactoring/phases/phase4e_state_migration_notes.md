# Phase 4E: State Migration Notes (ChatScreen)

## Current state (opt-in path)
- `chatSessionStateNotifierProvider` mirrors `ChatScreenController.state` for provider consumers.
- `ChatScreen` reads state via the notifier when `useSessionProviders` is true; default path still uses the controller state directly.
- Actions/listeners (send, delete, retry, reconnect, pairing, contact sync, connection/mesh listeners, scroll) route through `chatSessionActionsFromControllerProvider` under opt-in (same underlying controller implementations).

## Next steps to finish provider flip
1) Move state ownership into a provider-owned Notifier (in progress)
   - `ChatSessionOwnedStateNotifier` now receives state from the controller; UI defaults to using the owned notifier (provider path is default). Controller state getter prefers the owned notifier, and `_updateState` uses the provider-backed getter.
   - Next: stop writing to local `_state` and have the controller consume provider state (or remove it) after parity tests, making the owned notifier authoritative.
2) Retire ChangeNotifier path
   - After parity verification, make provider-backed path default and deprecate `chatScreenControllerProvider`.
   - Remove mirror providers once widgets no longer depend on ChangeNotifier.
3) Tests to add
   - Provider-backed ChatScreen integration (send/delete/retry/search/scroll/pairing).
   - State notifier unit tests to ensure updates propagate and dispose correctly.
   - Regression tests for connection/mesh listener side-effects.
