# Setting Up OpenAI MCP Server for Claude Code Collaboration

## What This Enables

I (Claude Code) can delegate specific tasks to ChatGPT-5 via MCP, allowing:
- **Unbiased code review**: ChatGPT reviews code I wrote without my inherent biases
- **Second opinions**: Architecture decisions, security analysis, algorithmic approaches
- **Parallel work**: I handle implementation, ChatGPT does research/documentation simultaneously

## Installation Steps

### 1. Install the MCP Server

```bash
npm install -g openai-mcp-server
```

### 2. Set Your OpenAI API Key

**Get API key**: https://platform.openai.com/api-keys (requires ChatGPT Pro subscription)

**Windows**:
```bash
setx OPENAI_API_KEY "sk-proj-YOUR_KEY_HERE"
```

**Linux/Mac**:
```bash
export OPENAI_API_KEY="sk-proj-YOUR_KEY_HERE"
# Add to ~/.bashrc or ~/.zshrc to persist
```

### 3. Configure Claude Code to Use It

Edit `.claude/settings.local.json`:

```json
{
  "mcp": {
    "openai": {
      "command": "npx",
      "args": ["-y", "openai-mcp-server"],
      "env": {
        "OPENAI_API_KEY": "${env:OPENAI_API_KEY}"
      }
    }
  },
  "permissions": {
    "allow": [
      // ... existing permissions ...
    ]
  }
}
```

### 4. Restart Claude Code

```bash
# In your terminal where claude code is running:
# Press Ctrl+C, then:
claude code
```

## Usage Examples

### Example 1: Unbiased Code Review

**You**: "Claude, have ChatGPT review the Noise Protocol handshake implementation for timing vulnerabilities"

**What happens**:
1. I send `lib/core/security/noise/noise_session.dart` to ChatGPT via MCP
2. ChatGPT analyzes it fresh (no bias from writing it)
3. Returns findings to me
4. I synthesize findings and propose fixes to you

### Example 2: Architectural Debate

**You**: "Claude and ChatGPT: Should we use bloom filters or LRU cache for SeenMessageStore?"

**What happens**:
1. I present my analysis (bloom filters for memory efficiency)
2. I query ChatGPT for alternative perspective
3. ChatGPT might counter (LRU for bounded memory + item eviction)
4. I present both views with trade-offs to you

### Example 3: Parallel Work

**You**: "Claude: Implement message compression. ChatGPT: Research best compression algorithms for BLE MTU constraints"

**What happens**:
1. I start implementing `MessageCompressor` class
2. Simultaneously, I delegate research to ChatGPT via MCP
3. ChatGPT returns: "LZ4 > zlib for BLE (speed), but zstd best compression ratio"
4. I adjust implementation based on research
5. Present complete solution to you

## Verification

After setup, I'll be able to call:

```typescript
// Behind the scenes via MCP
await openai.chat({
  model: "gpt-4",
  messages: [{
    role: "system",
    content: "You are a security auditor reviewing Dart/Flutter code."
  }, {
    role: "user",
    content: "Review this Noise Protocol implementation for timing attacks..."
  }]
});
```

## Cost Considerations

**OpenAI API pricing** (as of 2025):
- **GPT-4 Turbo**: $0.01/1K input tokens, $0.03/1K output tokens
- **GPT-4o**: $0.005/1K input tokens, $0.015/1K output tokens

**Estimated costs for typical tasks**:
- Code review (5K tokens): ~$0.08-$0.15
- Architecture analysis (10K tokens): ~$0.15-$0.30

Your ChatGPT Pro subscription includes API credits, but verify limits at:
https://platform.openai.com/usage

## Troubleshooting

### "Unauthorized" Error

**Cause**: API key not set or invalid

**Fix**:
```bash
# Verify key is set
cmd /c "echo %OPENAI_API_KEY%"

# Should output: sk-proj-...
# If blank, re-run setx command
```

### "MCP server not found"

**Cause**: `openai-mcp-server` not in PATH

**Fix**:
```bash
# Check installation
npm list -g openai-mcp-server

# If missing:
npm install -g openai-mcp-server
```

### "Model not available"

**Cause**: Using GPT-4 without access

**Fix**: Edit MCP config to use `gpt-3.5-turbo` (always available) or `gpt-4o` if you have access.

## Alternative: @fadeaway-ai/openai-mcp-server

**Features**:
- ✅ o3-deep-research model (requires higher tier access)
- ✅ Web search + code interpreter enabled by default
- ❌ More complex setup

**Install**:
```bash
npm install -g @fadeaway-ai/openai-mcp-server
```

**Config** (use in `.claude/settings.local.json`):
```json
{
  "mcp": {
    "openai": {
      "command": "npx",
      "args": ["-y", "@fadeaway-ai/openai-mcp-server"],
      "env": {
        "OPENAI_API_KEY": "${env:OPENAI_API_KEY}"
      }
    }
  }
}
```

## What "Headless Mode" Means Here

**You won't see ChatGPT's UI**. Instead:
- I call ChatGPT's API programmatically
- You see the synthesized results in my responses
- No need to copy-paste between Claude Code and ChatGPT web UI

**It's like having two developers in your terminal**:
- Me (Claude Code): Main implementer, sees the codebase history
- ChatGPT (via MCP): Fresh eyes, unbiased reviewer

## Next Steps

1. Run the installation commands above
2. Set your OpenAI API key
3. Update `.claude/settings.local.json`
4. Restart Claude Code
5. Ask me to "have ChatGPT review [specific code]" to test
