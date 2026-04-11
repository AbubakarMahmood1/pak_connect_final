# Optional OpenAI API MCP Setup For Claude Code

This file documents an optional path for connecting Claude Code to OpenAI APIs.

It is not required for:
- using native Codex surfaces
- using Codex with a ChatGPT subscription
- following the repo guidance in `AGENTS.md`

## Use This Only If

You specifically want Claude Code to call OpenAI-hosted capabilities through an
API-based MCP bridge.

## Important Distinction

These are separate things:
- ChatGPT subscription access to Codex
- OpenAI API access using an API key
- Claude Code calling OpenAI via an MCP server

Do not treat them as interchangeable.

## Repo-Level Guidance

If your environment uses an OpenAI MCP bridge:
- Keep credentials out of the repo
- Store secrets in user-level environment configuration
- Prefer repo guidance in `AGENTS.md` over package-specific defaults
- Re-verify setup against current official OpenAI docs before changing auth or
  model assumptions

## Practical Recommendation

For PakConnect work:
- Use native Codex surfaces directly when you want Codex
- Use this optional MCP path only if you need Claude Code to delegate to OpenAI
  APIs from inside a Claude session
