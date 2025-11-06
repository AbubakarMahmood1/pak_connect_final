# Codex Integration Summary

## ✅ What We Set Up

### 1. MCP Server Configuration
**Location**: `~/.claude.json` (user-level, applies to all projects)

**Command**:
```bash
codex mcp-server -c model="gpt-5" -c model_reasoning_effort="medium" -c model_reasoning_summary="detailed"
```

**Settings**:
- Model: GPT-5 (most capable)
- Reasoning Effort: **medium** (default, balances quality vs limits)
- Reasoning Summary: detailed (transparency in thought process)
- Authentication: Uses your ChatGPT Pro subscription (no API key needed)

### 2. CLAUDE.md Updates
**Added**: Codex as 6th item in Confidence Protocol checklist (15% weight)

**Automatic Triggers** (Claude will call Codex without asking):
- Confidence score <70%
- Critical areas (BLE handshake, Noise Protocol, mesh routing, security)
- Stuck debugging >2 hours
- Architecture changes

**Reasoning Effort Selection**:
- **High**: Security audits, cryptography, race conditions, critical bugs
- **Medium**: Code reviews, refactoring, architecture (default)
- **Low**: Simple questions, explanations

### 3. AGENTS.md Creation
**Purpose**: Shared context for all AI agents (Claude, Codex, future LLMs)

**Content**:
- Project overview (tech stack, architecture)
- Critical invariants (identity, Noise, mesh, BLE, database)
- Common pitfalls (what NOT to do)
- Collaboration guidelines (Claude implements, Codex reviews)

**Key Section**: "🤝 Collaboration with Other Agents"
- Defines roles: Claude (implementation) vs Codex (critique)
- Establishes workflow: Implement → Review → Validate

---

## 🔄 Workflow Examples

### Example 1: Low Confidence (<70%)

**User**: "Fix Device A connecting to itself"

**Claude's Process**:
1. Run confidence check → Score 30% (< 70%)
2. **Automatically call Codex** (medium reasoning):
   ```
   "BLE dual-role device connecting to itself. Common prevention patterns?"
   ```
3. Receive Codex's suggestions (MAC filtering, device ID in advertising, etc.)
4. Ask user informed questions based on Codex's input
5. Implement solution with both perspectives considered

### Example 2: Critical Area (Security)

**User**: "Review the Noise Protocol handshake for timing vulnerabilities"

**Claude's Process**:
1. Recognize: "Noise Protocol" = Critical Area (security)
2. **Automatically escalate to Codex** (high reasoning):
   ```
   codex exec -c model_reasoning_effort="high" \
   "Audit this Noise Protocol XX handshake for timing attacks..."
   ```
3. Receive detailed security analysis from GPT-5
4. Synthesize findings with own analysis
5. Present comprehensive security review to user

### Example 3: Standard Task (≥90% Confidence)

**User**: "Add a new field to the Chat model"

**Claude's Process**:
1. Run confidence check → Score 95% (≥ 90%)
2. **Skip Codex** (high confidence, not critical area)
3. Implement directly (optional: Codex review after completion)
4. Saves your GPT-5 message limits for critical tasks

---

## 📊 Expected Outcomes

### Benefits
✅ **Unbiased reviews**: Codex hasn't seen the code before (no implementation bias)
✅ **Security focus**: Automatic escalation on critical areas
✅ **Limit management**: Medium reasoning default saves ~2-3x messages
✅ **Systematic validation**: Confidence protocol prevents 7-day rabbit holes

### Cost Management
- **Medium reasoning** (default): ~2,600 tokens per query
- **High reasoning** (critical): ~4,000-6,000 tokens per query
- **Low reasoning** (simple): ~800-1,200 tokens per query
- Automatic triggers only on critical/low-confidence tasks

### Quality Improvements
- Fewer regressions (two perspectives validate approach)
- Faster debugging (fresh eyes spot issues Claude might miss)
- Better architecture (Codex evaluates trade-offs objectively)

---

## 🔧 Configuration Files Reference

### MCP Server Config
**File**: `~/.claude.json`
**Section**: `mcpServers.codex`
**Scope**: User-level (all projects)

### Project Guidelines
**File**: `CLAUDE.md` (Claude Code specific)
**Key Sections**:
- Confidence Protocol (lines 590-700)
- Codex Integration Workflow (lines 645-661)

**File**: `AGENTS.md` (all AI agents)
**Key Sections**:
- Critical Invariants (lines 75-109)
- Collaboration Guidelines (lines 157-168)

---

## 🚀 Next Steps

### To Activate Full Integration
1. **Restart Claude Code**: `Ctrl+C` then `claude code`
   - Loads Codex MCP server for native tool access
   - After restart, Claude will have `mcp__codex__codex` and `mcp__codex__codex-reply` tools

2. **Test Collaboration**:
   ```
   You: "Claude, have Codex review the mesh relay logic"
   Claude: [automatically calls Codex, synthesizes review]
   ```

### Optional: Codex CLI Profile
Create `~/.codex/config.toml` to customize:
```toml
[profiles.pak-review]
model = "gpt-5"
model_reasoning_effort = "medium"
model_reasoning_summary = "detailed"
model_verbosity = "high"
```

Then use: `codex --profile pak-review mcp-server`

---

## 🆘 Troubleshooting

### Codex Not Responding
**Check**: `claude mcp list` shows "✓ Connected"?
**Fix**: Restart Claude Code to load MCP servers

### Hitting GPT-5 Limits Too Fast
**Check**: Are you using `high` reasoning on simple tasks?
**Fix**: Change default to `low` in MCP config:
```bash
claude mcp remove codex
claude mcp add codex -s user -- codex mcp-server -c model="gpt-5" -c model_reasoning_effort="low"
```

### Codex Gives Incorrect Context
**Check**: Is `AGENTS.md` up to date with critical invariants?
**Fix**: Update `AGENTS.md` whenever architecture changes

---

## 📝 Maintenance

**When to update AGENTS.md**:
- New critical invariants discovered
- Architecture patterns change
- Security requirements evolve
- Common pitfalls identified through debugging

**When to update CLAUDE.md**:
- Implementation details change
- New services/components added
- Confidence protocol thresholds adjust
- Codex integration patterns improve

**Keep files in sync**:
- Critical invariants should match between files
- CLAUDE.md = detailed implementation
- AGENTS.md = high-level shared context
