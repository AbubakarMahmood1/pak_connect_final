# CLAUDE.md

`AGENTS.md` is the canonical repo contract. Read it first.

Use this file as the Claude-specific overlay for workflow and document lookup,
not as a second source of truth.

## Default Workflow

1. Read `AGENTS.md`.
2. If the task is non-trivial, create or update `PLANS.md`.
3. Load only the relevant surviving repo docs for the area you are touching.
4. Implement with narrow changes.
5. Verify with `flutter analyze`, targeted `flutter test`, or a full suite when
   warranted.

## On-Demand Repo Docs

Load only what you need:
- `CONTRIBUTING.md` for branch/review expectations and high-scrutiny areas
- `README.md` for the current architecture and runtime summary
- `ThreatModel.md` for attacker model and trust boundaries
- `docs/security/security_overview.md` for the current security map
- `docs/security/security_guarantees.md` for implemented guarantees
- `TESTING_STRATEGY.md` and `docs/testing/QUICK_START_TESTING.md` for
  verification flow
- `docs/srs/README.md` for requirements context

## Claude-Specific Guidance

- Keep explanations terse and technical.
- Treat the user as experienced.
- Prefer code and concrete changes over generic advice.
- For reviews, list findings first with file/line references.

## Confidence Triggers

Before modifying critical systems, run a quick confidence check:
- Root cause understood?
- Existing architecture respected?
- Relevant docs checked?
- Verification plan defined?

If confidence is low, slow down and plan before editing.

## Codex Collaboration

Use Codex as a second opinion when:
- Confidence is low
- Security is involved
- BLE/Noise/mesh behavior is unclear
- The task is drifting into architecture design

Do not assume a specific Codex MCP binding or API-key-only flow. Native Codex
surfaces and optional API-based MCP integrations are separate concerns.
