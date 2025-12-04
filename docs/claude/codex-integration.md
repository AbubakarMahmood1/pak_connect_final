# Codex MCP Configuration & Usage Guide

**Codex** is a Claude 3.7 Sonnet MCP (Model Context Protocol) server configured to provide deep analysis, code reviews, and architectural guidance.

## What is Codex?

Codex is an external reasoning service that Claude can call for:
- **Fresh perspectives** on architectural decisions
- **Security audits** of cryptographic implementations
- **Code reviews** with specialized expertise
- **Debugging guidance** for complex multi-day issues
- **Alternative approaches** when confidence is low

Think of it as a "second opinion from a smarter Claude" - it has access to newer models and extended reasoning capabilities.

## How to Invoke Codex (For Users)

**You can explicitly request Codex in any message:**

```
"Have Codex review this approach for security vulnerabilities"
"Ask Codex about the best pattern for [problem]"
"Get a second opinion on [my proposal] from Codex"
"Use Codex to analyze why [this is failing]"
```

## How Claude Uses Codex (Automatic Triggers)

Claude automatically invokes Codex in these situations:

1. **Low Confidence** (`<70%`): When confidence assessment on critical work is below 70%
2. **Critical Areas**: BLE handshake, Noise Protocol, mesh relay routing, security operations
3. **Stuck Debugging** (>2 hours): If investigating an issue without resolution
4. **Architecture Changes**: Before proposing significant refactoring

## MCP Server Details

**Server Name**: `mcp__codex__codex` (or `mcp__codex__codex-reply` for follow-ups)

**Configuration Status**:
- ✅ Configured in your environment
- ✅ Accessible to Claude
- ⚠️ Requires proper parameter formatting to work correctly

**Parameters Required**:

```
{
  "prompt": "The actual question/request for Codex",
  "model": "opus" or "sonnet" (optional, defaults to sonnet),
  "sandbox": "read-only" or "workspace-write" (optional),
  "base-instructions": "Custom system prompt" (optional),
  "cwd": "Working directory" (optional)
}
```

## Common Mistakes (and fixes)

**❌ MISTAKE #1: Wrong Parameter Names**
```
WRONG: mcp__codex__codex with "question" field
WRONG: mcp__codex__codex with "query" field
WRONG: mcp__codex__codex with "text" field

✅ CORRECT: mcp__codex__codex with "prompt" field
```

**❌ MISTAKE #2: Calling the Wrong Tool or Wrong conversationId Format**
```
WRONG: mcp__codex__codex for follow-up messages
✅ CORRECT: mcp__codex__codex-reply for follow-ups (requires valid conversationId)

WRONG: conversationId = "test-123" (arbitrary string)
✅ CORRECT: conversationId must be UUID format
  Example: "550e8400-e29b-41d4-a716-446655440000"
  Error if format wrong: "Failed to parse conversation_id: invalid character"
```

**❌ MISTAKE #3: Overly Vague Prompts (Less Effective)**
```
Less effective: "Why is my BLE code failing?"
  → Codex will still answer, but may make broad assumptions

Better: "Why is my BLE code failing?
  Context: Handshake with ephemeralId, then discover persistentKey,
  then try to decrypt with persistentKey but NoiseSessionManager
  throws 'No session found' because it's keyed by ephemeralId not persistentKey."
  → Codex gives precise root cause + exact file/line references

Best: "Review this identity resolution pattern for race conditions:
  1. Ephemeral session during handshake
  2. Discover persistent key
  3. Switch to persistent key for decryption
  Is this a race or architectural issue? What's the fix?"
  → Codex explains the architecture + provides exact solutions
```

**❌ MISTAKE #4: Not Specifying Reasoning Effort**
The "reasoning" effort is controlled implicitly by prompt complexity:

```
For HIGH reasoning (security-critical):
  - Use detailed prompts with context
  - Ask for multiple perspectives
  - Explicitly ask for edge case analysis

For MEDIUM reasoning (standard):
  - Ask for code review or architecture feedback
  - Include specific requirements/constraints

For LOW reasoning (lookups):
  - Don't use Codex for simple questions
  - Use Codex only when you need deep analysis
```

**❌ MISTAKE #5: Not Including Enough Context**
```
WRONG: "Why is this failing?"
✅ CORRECT: "BLE handshake is failing at Phase 1.5 (Noise XX pattern).
  - Device A sends message 1 (e + s)
  - Device B should respond with (e + dhee + s + dhse + payload)
  - Actual: Device B logs NoiseException('Invalid nonce')
  - Database shows currentEphemeralId matches, so identity is correct
  - Error occurs 3/5 connection attempts (intermittent)

  What causes intermittent Noise handshake failures with valid identities?
  Is this nonce sequencing, timestamp synchronization, or session state?"
```

**❌ MISTAKE #6: Wrong Response Format Assumption**
Codex returns **plain text directly**, NOT JSON structures:
```
✅ ACTUAL FORMAT:
Codex: "Root cause sits in the identity resolution...
[detailed analysis with file paths and line numbers]"

❌ NOT JSON:
{
  "type": "text",
  "content": "..."
}
```

The response is immediately usable plain text - no parsing needed.

## When to Use Codex

✅ **USE CODEX FOR**:
- Security audits (Noise, ChaCha20, key derivation)
- Architecture reviews (dual-role BLE, state management)
- Complex debugging (multi-day stuck issues)
- Alternative approaches (when <70% confidence)
- Performance optimization decisions
- Edge case analysis

❌ **DON'T USE CODEX FOR**:
- Simple API lookups (check docs instead)
- Quick syntax questions
- File reading/writing (Claude has tools for this)
- Test execution (Claude can run Flutter tests)
- Basic debugging (grep logs, read code first)
- Quick explanations

## Response Patterns to Expect

**Pattern 1: Confirmatory Response**
```
Codex: "Your approach is sound. Here's why:
  1. [Confirms your understanding]
  2. [Identifies what you got right]
  3. [Suggests one improvement]"

→ Proceed with implementation immediately
```

**Pattern 2: Alternative Approaches**
```
Codex: "Your approach works, but consider these alternatives:
  Approach A: [Pros/cons] (Better for X)
  Approach B: [Pros/cons] (Better for Y)
  Recommended: Approach B because [reasoning]"

→ Present options to you with pros/cons
```

**Pattern 3: Critical Issue Found**
```
Codex: "Your approach has a flaw:
  [Description of the problem]
  Likely cause: [Root cause]
  Fix: [Recommended solution]"

→ STOP implementation, ask clarifying questions, pivot approach
```

**Pattern 4: Needs More Context**
```
Codex: "Can you clarify:
  1. [Question A]
  2. [Question B]"

→ Claude asks YOU these clarifying questions
```

## Example: Proper Codex Usage

**User Says**: "Fix the Noise handshake intermittent failures"

**Confidence Check**: ~45% (intermittent + cryptography = high complexity)

**Action**: Call Codex BEFORE asking you questions

**Codex Prompt**:
```
"BLE Noise XX handshake intermittently fails (3/5 attempts).
Logs show:
  - Phase 0: CONNECTION_READY ✅
  - Phase 1: IDENTITY_EXCHANGE ✅
  - Phase 1.5: NoiseException('Invalid nonce') ❌

Context:
  - Nonce is stored in CipherState._n (should be u64, strictly increasing)
  - Session created fresh per connection (no reuse)
  - Same two devices, random failure pattern
  - No clock skew visible in logs

What causes intermittent nonce errors in Noise XX handshake?
Options to investigate:
  A) Nonce not incrementing (threading issue)?
  B) AEAD authentication failure (key derivation)?
  C) State machine race condition (Phase 1 not complete before Phase 1.5)?
  D) Device role confusion (central vs peripheral)?

Which is most likely and how do I verify?"
```

**Codex Response** (hypothetical):
```
"Most likely: Option C - race condition in state machine.

Why:
  1. Intermittent = timing-dependent
  2. Nonce error during Phase 1.5 = state not ready
  3. Same devices = rule out key derivation
  4. Random 3/5 = connection timing variance

Verification:
  1. Add mutex lock to Phase 1→1.5 transition
  2. Log state transitions with timestamps
  3. Check for concurrent noiseSessionManager.getSession() calls
  4. Verify Phase 1 callback fires before Phase 1.5 starts

Secondary check:
  - Ensure ephemeralId rotation doesn't race with nonce initialization
  - Verify MTU negotiation completes before Phase 1 message"
```

**Then Claude Asks You**:
1. "Can you share logs from 3 failed handshake attempts?"
2. "Are multiple threads calling getSession() simultaneously?"
3. "Does adding a 100ms delay between Phase 1→1.5 help?"

## Testing & Verification (Real Results)

**Tests Performed**:

| Test | Command | Result | Notes |
|------|---------|--------|-------|
| Basic prompt | `mcp__codex__codex` with `prompt` field | ✅ PASS | Codex responded with detailed analysis |
| Response format | Checked response structure | ✅ Plain text (not JSON) | Returns unstructured text directly |
| Vague prompts | `"Why is my BLE code failing?"` | ✅ PASS | Works fine, gives broad context analysis |
| Specific prompts | `"Review identity resolution for race conditions"` | ✅ PASS | More detailed, includes file:line references |
| UUID conversationId | Tested `conversationId: "test-123"` | ❌ FAIL | Error: "invalid character, expected UUID format" |
| Model parameter | Added `model: "sonnet"` | ✅ Accepted | No errors, unsure if it changed behavior |
| Sandbox parameter | Added `sandbox: "read-only"` | ✅ Accepted | No errors, may not affect Codex |
| Codebase context | Asked about PakConnect specifics | ✅ Yes | Codex knows file structure, gives exact line numbers |

**Key Findings**:
1. **Codex has full codebase access** - Knows PakConnect architecture deeply
2. **Plain text responses** - No JSON parsing needed, responses are immediately usable
3. **Works with vague prompts** - But specific prompts get better file/line references
4. **conversationId is strict** - Must be UUID format for follow-up conversations
5. **Reasoning is implicit** - Don't worry about specifying "high/medium/low" effort

## Troubleshooting Codex Integration

**If Codex doesn't respond**:
1. Check MCP server status: Is Codex running?
2. Check prompt: Did Claude include "prompt" field?
3. Check token budget: Is Codex request too long?
4. Check conversationId: For replies, must be valid UUID format (not arbitrary string)

**If Codex gives wrong answer**:
1. Ask Claude to call Codex again with more context
2. Provide specific details (file paths, error messages, expected behavior)
3. Request analysis of specific area (security, performance, architecture, etc.)

**If Claude isn't calling Codex when you expect it**:
1. Explicitly request: "Have Codex review this"
2. This overrides Claude's confidence threshold
3. Codex will respond even if Claude thinks it has high confidence
