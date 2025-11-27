# Claude Code Documentation Structure

This directory contains detailed documentation for working with PakConnect, organized by topic. The main `CLAUDE.md` file in the project root acts as an orchestrator that references these files on-demand.

## File Organization

| File | Size | Purpose |
|------|------|---------|
| `architecture-ble.md` | 3.1 KB | BLE handshake, dual-role, fragmentation, power management |
| `architecture-noise.md` | 2.6 KB | Noise protocol, security levels, identity model |
| `architecture-mesh.md` | 3.5 KB | Mesh relay, routing, message flow |
| `architecture-riverpod.md` | 6.0 KB | Riverpod state management, StreamController migration |
| `architecture-database.md` | 2.1 KB | Database schema, SQLCipher configuration |
| `development-guide.md` | 5.7 KB | Commands, testing, debugging, common tasks |
| `confidence-protocol.md` | 6.0 KB | Confidence assessment checklist (mandatory for critical areas) |
| `codex-integration.md` | 10.9 KB | Codex MCP usage, common mistakes, examples |
| `performance.md` | 1.2 KB | Performance tips and known limitations |

## Design Philosophy

**Problem**: The original CLAUDE.md was 43.4 KB, causing performance warnings (>40 KB threshold).

**Solution**: Split into an orchestrator + detailed reference docs:
- **CLAUDE.md** (7.4 KB): Core invariants, quick reference, tells Claude when to read detailed docs
- **Detailed docs** (9 files, 41.2 KB total): Architecture deep dives, loaded on-demand

## How Claude Uses These Docs

Claude automatically reads detailed docs when:
- Working on BLE issues → reads `architecture-ble.md`
- Debugging security/encryption → reads `architecture-noise.md`
- Refactoring state management → reads `architecture-riverpod.md`
- Before modifying critical areas → reads `confidence-protocol.md`
- Using Codex for second opinions → reads `codex-integration.md`

## Total Size Comparison

| Version | Size | Performance Impact |
|---------|------|-------------------|
| **Original CLAUDE.md** | 43.4 KB | ⚠️ Performance warning |
| **New CLAUDE.md** | 7.4 KB | ✅ Well under 40 KB threshold |
| **All docs (total)** | 48.6 KB | ✅ Only loaded when needed |

**Result**: **83% reduction** in always-loaded context, with detailed docs available on-demand.
