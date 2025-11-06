# Serena Usage Guide - Simplified

## ✅ Your Setup is Already Correct!

Both your Windows and WSL configs have Serena configured **globally** without a hardcoded project path.

## How Serena Works (No Local Server Needed!)

### **Key Concept:**
- Serena runs as an **MCP server** that Claude Code starts automatically
- You **DO NOT** need to run a local server manually
- The `uvx --from git+https://github.com/oraios/serena` command pulls the latest version directly from GitHub
- No local installation required!

## Using Serena

### 1. **Start Claude Code (Windows or WSL)**
```bash
# From anywhere:
cd ~
claude
```

### 2. **Activate Your Project**
Once Claude Code starts, just tell me (Claude):
```
"Activate the project /mnt/c/dev/pak_connect"
```

Or from Windows paths:
```
"Activate the project C:/dev/pak_connect"
```

### 3. **Serena Will Index Your Project** (First Time Only)
The first time you activate a project, Serena will:
- Read your codebase structure
- Create `.serena/` directory in your project
- Generate `project.yml` and memories
- This may take a while for large projects

### 4. **Use Serena's Tools**
After activation, I (Claude) can use Serena's powerful tools:
- 🔍 **Semantic code search** - Find symbols, classes, functions
- ✏️ **Symbolic editing** - Edit code by symbol name (not line numbers!)
- 📊 **Code analysis** - Understand dependencies, references
- 🧪 **Shell execution** - Run tests, builds (if enabled)

## Dashboard (Optional)

Serena automatically opens a dashboard at:
```
http://localhost:24282/dashboard/index.html
```

Use it to:
- View logs of Serena's operations
- Monitor tool usage stats
- Shut down Serena cleanly

You can disable this in `~/.serena/serena_config.yml` if you don't want it.

## Pre-Indexing (Recommended for Large Projects)

To speed up first-time usage, pre-index your project:

**Windows:**
```powershell
cd C:\dev\pak_connect
uvx --from git+https://github.com/oraios/serena serena project index
```

**WSL:**
```bash
cd /mnt/c/dev/pak_connect
uvx --from git+https://github.com/oraios/serena serena project index
```

## Configuration Files

### Global Config (Optional)
`~/.serena/serena_config.yml` - Settings that apply everywhere

Edit with:
```bash
uvx --from git+https://github.com/oraios/serena serena config edit
```

### Project Config (Auto-Generated)
`.serena/project.yml` - Project-specific settings (created on first activation)

### Memories
`.serena/memories/` - Serena's "memory" of your project
- Auto-generated during onboarding
- You can manually edit or add new memories
- Serena reads these to understand your project better

## How Your Current Setup Works

### Windows (`C:\Users\theab\.claude.json`):
```json
"serena": {
  "command": "uvx",
  "args": ["--from", "git+https://github.com/oraios/serena",
           "serena", "start-mcp-server", "--context", "ide-assistant"]
}
```

### WSL (`~/.config/claude/claude_desktop_config.json`):
```json
"serena": {
  "command": "uvx",
  "args": ["--from", "git+https://github.com/oraios/serena",
           "serena", "start-mcp-server", "--context", "ide-assistant"]
}
```

**What `uvx --from git+...` means:**
- `uvx` = Run a Python tool without installing it
- `--from git+...` = Pull latest version from GitHub repo
- No local installation needed
- Always uses latest version

## Common Questions

### Q: Do I need to install Serena locally?
**A:** No! The `uvx --from git+...` command pulls it directly from GitHub.

### Q: Do I need to run a local server?
**A:** No! Claude Code automatically starts Serena as a subprocess when needed.

### Q: What if I get "uvx not found" in WSL?
**A:** Install uv (which includes uvx):
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```
Or use pip:
```bash
pip3 install uv
```

### Q: Can I use Serena with multiple projects?
**A:** Yes! Just activate different projects:
```
"Activate the project ~/my-other-project"
```

### Q: Does this use my API key?
**A:** Yes, when you use Claude Code, all tool calls (including Serena) use your Claude API/subscription.

## Workflow Example

```
1. cd C:\dev\pak_connect
2. claude
3. Tell Claude: "Activate the project C:/dev/pak_connect"
4. Tell Claude: "Read the Serena initial instructions"
5. Tell Claude: "Find all functions that handle BLE connections"
6. Claude uses Serena's semantic search to find them instantly!
```

## Advanced: Git Worktrees

If you use git worktrees (parallel work on branches), you can copy Serena's cache:
```bash
cp -r $ORIG_PROJECT/.serena/cache $GIT_WORKTREE/.serena/cache
```

This avoids re-indexing for each worktree.

---

**Summary:**
- ✅ Your setup is already perfect
- ✅ No local server needed (runs via MCP)
- ✅ No local installation needed (pulls from GitHub)
- ✅ Just activate projects when you need them
- ✅ Works globally in Windows and WSL

**Next Steps:**
1. Test in Windows: `cd C:\Users\theab\Desktop && claude` → `/mcp`
2. Test in WSL: `cd ~ && claude` → `/mcp`
3. Activate pak_connect project when ready
