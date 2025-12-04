# 🎯 Confidence Protocol (MANDATORY for Critical Areas)

**Purpose**: Prevent regressions and 7-day debugging rabbit holes by verifying approach BEFORE implementation.

Before modifying these systems, run confidence assessment (0.0-1.0):

## Critical Areas (≥90% confidence required):

- **BLE handshake phases** (CONNECTION_READY → IDENTITY_EXCHANGE → NOISE_HANDSHAKE → CONTACT_STATUS_SYNC)
- **Noise session state machine** (especially XX/KK pattern selection, nonce sequencing)
- **Identity resolution** (publicKey vs persistentPublicKey vs currentEphemeralId)
- **Mesh relay routing** (MeshRelayEngine, SmartMeshRouter, SeenMessageStore)
- **Message fragmentation/defragmentation** (MessageFragmenter with sequence numbers)
- **Database schema migrations** (MUST test backwards compatibility)

## Confidence Checklist:

- [ ] **No Duplicates (20%)**: Is this functionality already implemented elsewhere?
  - Example: Don't add new identity storage if Contact model already handles it
  - Check: BLEService, SecurityManager, MeshRelayEngine, ContactRepository

- [ ] **Architecture Compliance (20%)**: Does this follow existing patterns?
  - Layered architecture: Presentation → Domain → Core → Data
  - Repository pattern for data access
  - Provider pattern (Riverpod 3.0) for state
  - Service layer for business logic

- [ ] **Official Docs Verified (15%)**: Have I checked authoritative sources?
  - BLE GATT specification (for handshake timing)
  - Noise Protocol spec (for XX/KK patterns, rekeying)
  - Flutter BLE package docs (for MTU negotiation)
  - ChaCha20-Poly1305 AEAD spec (for encryption/decryption)

- [ ] **Working Reference (15%)**: Have I found proven implementation?
  - GitHub search: "BLE mesh relay Dart"
  - GitHub search: "Noise Protocol Flutter"
  - Stack Overflow: Specific error messages (e.g., "ChaCha20 PAD error")

- [ ] **Root Cause Identified (15%)**: Do I understand WHY, not just WHAT?
  - Self-connection: Is this MAC address filtering? Ephemeral ID collision? Peripheral advertising logic?
  - Notification failure: Is this Phase 0 vs Phase 1 timing? Characteristic caching? BLE state issue?
  - PAD errors: Is this Noise AEAD layer? Fragmentation reassembly? Nonce sequencing?

- [ ] **Codex Second Opinion (15%)**: Have I consulted GPT-5 for unbiased perspective?
  - **When to trigger**: Score <70% OR critical areas (security, concurrency, architecture)
  - **Reasoning effort**: Use `high` for security/critical, `medium` for standard review
  - **What to ask**: "Review this approach for [security vulnerabilities / edge cases / alternative solutions]"
  - **Value**: Fresh perspective without my implementation bias, catches blind spots

## Scoring:

- **≥90%**: ✅ Proceed immediately with implementation (optional: Codex review after completion)
- **70-89%**: ⚠️ Present 2-3 alternative approaches with trade-offs, **then consult Codex** for unbiased evaluation
- **<70%**: ❌ STOP - Ask clarifying questions, research more, **consult Codex for alternative approaches**, don't guess

## Codex Integration Workflow:

**Automatic Triggers** (I'll call Codex without asking):
1. **Confidence score <70%**: Get second opinion before asking user questions
2. **Critical areas** (BLE handshake, Noise, mesh routing, security): Review approach before implementation
3. **Multi-day debugging**: If stuck >2 hours, escalate to Codex for fresh perspective
4. **Architecture changes**: Consult on trade-offs before proposing to user

**Manual Triggers** (User requests):
- "Have Codex review this"
- "Ask Codex about [topic]"
- "Get a second opinion on [approach]"

**Reasoning Effort Selection**:
- **High**: Security audits, cryptography, race conditions, critical bugs
- **Medium**: Code reviews, refactoring, architecture discussions (default)
- **Low**: Simple questions, explanations, documentation lookups

## Usage Example:

**User**: "Fix Device A showing Device B on both central AND peripheral sides"

**Confidence Check**:
- [ ] No duplicates? ❌ (dual-role BLE issue, not simple self-connection) = 0%
- [ ] Architecture compliance? ⚠️ (need to check central/peripheral role separation) = 10%
- [ ] Official docs? ❌ (BLE GATT spec for dual-role connection tracking) = 0%
- [ ] Working reference? ❌ (no dual-role device appearance example found) = 0%
- [ ] Root cause? ❌ (could be discovered device list, MAC filtering, or connection tracking) = 0%
- [ ] Codex opinion? ⏳ (not consulted yet) = 0%

**Score: 0% + 10% + 0% + 0% + 0% + 0% = 10% < 70%**

**Action**: ❌ STOP - Consult Codex first, then ask user questions:

**Step 1 - Codex Consultation** (automatic):
```
Me → Codex (medium reasoning):
"BLE dual-role device issue: Device A initiates central connection to Device B.
Bug: Device A incorrectly shows Device B on BOTH central side (correct) AND peripheral side (wrong).
Symptoms: Dual-role UI badge appears, notifications not subscribed on connected device.
What causes a dual-role BLE device to incorrectly list centrally-connected peers as peripheral discoveries?"

Codex → Returns patterns from dual-role BLE implementations (connection tracking, deduplication logic)
```

**Step 2 - User Questions** (informed by Codex):
1. "Can you share logs showing Device A's connection to Device B and which side(s) it appears?"
2. "Does Device B also incorrectly show Device A twice, or only Device A is affected?"
3. "When you tap Device B in Device A's peripheral list, does the same chat open?"
4. "Are notification subscriptions set up for connections made by each device role?"

## ROI:

Spending 200 tokens on confidence check prevents 20,000 tokens debugging wrong layer (like spending 7 days on PAD errors that were actually Noise AEAD vs fragmentation layer confusion).

**Think of it like unit tests**: You wouldn't skip tests for PakConnect - don't skip confidence checks either.
