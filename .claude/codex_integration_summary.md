# Codex Integration Summary

This repo now assumes the following split:

## 1. Repo Guidance

- `AGENTS.md` is the canonical project contract.
- `PLANS.md` is the planning surface for larger or riskier tasks.
- Tool-specific files are thin projections and should not redefine repo rules.

## 2. Preferred Codex Usage

Prefer native Codex surfaces for actual Codex work:
- Codex CLI
- Codex IDE integrations
- Codex app
- Codex web/cloud tasks

Those are separate from any Claude-specific MCP bridge.

## 3. When To Use Codex As A Second Opinion

Use Codex when:
- Confidence is low
- Security is involved
- BLE / Noise / mesh behavior is unclear
- A change is architectural rather than local

## 4. Important Clarification

OpenAI API-based MCP integration for Claude Code is optional and separate from
using Codex with a ChatGPT subscription.

Do not assume:
- that a ChatGPT plan automatically gives an API key
- that an API-key MCP bridge is required for native Codex usage
- that a single hard-coded MCP tool name will exist in every environment

## 5. Repo Rule

If you update Codex-related notes in this repo, keep them aligned with
`AGENTS.md` and avoid writing environment-specific auth claims that go stale
quickly.
