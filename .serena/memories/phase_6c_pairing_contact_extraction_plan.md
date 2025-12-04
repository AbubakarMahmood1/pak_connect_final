# Phase 6C: Pairing/Contact Request Extraction Plan

## Current State Analysis

### Methods to Evaluate for Extraction

1. **userRequestedPairing()** (lines 651-661)
   - ✅ **EXTRACTABLE**: No UI concerns, just delegates to lifecycle
   - Current: Uses ref to get ConnectionService and ConnectionInfo
   - Target: Move to ViewModel with callback for ConnectionService access

2. **handleIdentityReceived()** (lines 810-869) - 60 LOC
   - ❌ **NOT EXTRACTABLE (Phase 6C)**: Complex UI lifecycle concerns
   - Has: WidgetsBinding.instance.addPostFrameCallback() - UI lifecycle
   - Creates: New scroll/search controllers with state mutations
   - Manages: Persistent chat manager registration/unregistration
   - Deferred to Phase 6E (separate identity migration extraction)

3. **_setupContactRequestListener()** (lines 908-954) - 47 LOC
   - ❌ **NOT EXTRACTABLE (Phase 6C)**: UI dialog concerns
   - Has: showDialog() with AlertDialog
   - Uses: context.mounted check
   - Shows: Contact request acceptance/rejection dialog
   - Deferred to Phase 6E (separate UI dialog extraction)

4. **handleAsymmetricContact()** (lines 956-961)
   - ✅ **ALREADY DELEGATING**: Just calls lifecycle method
   - No extraction needed

5. **addAsVerifiedContact()** (lines 963-964)
   - ✅ **ALREADY DELEGATING**: Just calls lifecycle method
   - No extraction needed

## Realistic Phase 6C Scope

### What CAN Be Extracted
1. **userRequestedPairing()** → ViewModel
   - Extract pairing request orchestration
   - Add callback for ConnectionService
   - Move ref dependency access handling

### What MUST Remain in Controller
1. **Identity migration** - Requires WidgetsBinding and controller state management
2. **Contact request dialogs** - Requires context and UI lifecycle
3. **Setup listeners** - Requires context and ref for provider invalidation

## Revised Phase 6C Strategy

**Focus**: Extract minimal but meaningful pairing request logic

**M1**: Audit pairing/contact methods (DONE)
**M2**: Extract userRequestedPairing() to ViewModel
**M3**: Add callback for ConnectionService
**M4**: Create Controller delegator
**M5**: Validate and commit

## Metrics Targets
- Controller: 941 → 910 LOC (-31)
- ViewModel: 441 → 470 LOC (+29)
- Tests: +1352 -5 (no regressions)

## Alternative: Larger Phase 6C

If we want bigger extraction, we could do:
1. **Option 1 (Current)**: Just userRequestedPairing() (~30 LOC)
2. **Option 2**: Extract pairing dialog controller setup to ViewModel
   - But requires context injection (architectural concern)
3. **Option 3**: Wait and do full identity/contact in Phase 6E

**Recommendation**: Proceed with Option 1 (userRequestedPairing only)
- Clean extraction with callback pattern
- Keeps UI concerns in Controller
- Consistent with Phase 6A/6B approach

Then user can decide: Continue with Phase 6D (StreamController audit) or Phase 6E (identity/contact dialogs).
