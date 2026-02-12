# Claude Code Setup for Kanban Phoenix App

This directory contains the Claude Code configuration for your Phoenix/Elixir Kanban application.

## What's Been Configured

### 1. Project Context (`.claudeproject`)
Defines the project structure and tells Claude Code to always reference `AGENTS.md` for guidelines.

### 2. Context Optimization (`.claudeignore`)
Excludes build artifacts, dependencies, and temporary files to keep Claude Code's context clean and performant.

### 3. Permissions (`settings.local.json`)
Pre-approved permissions for common Phoenix/Elixir tasks:
- **Mix tasks**: test, compile, format, credo, sobelow, deps, ecto, phx.gen, etc.
- **MCP servers**: TideWave (project context), HexDocs (documentation)
- **Development tools**: npm, curl, lsof, etc.

### 4. Custom Slash Commands (`commands/`)
Quick access to common workflows:

- `/precommit` - Run full precommit checklist (tests, credo, sobelow, coverage)
- `/docs` - Search Hex documentation for dependencies
- `/db` - Database operations (migrations, queries, schemas)

## Using MCP Servers

### TideWave (Elixir Project Context)
Ask Claude to:
- Evaluate Elixir code: "Run this code in the project context"
- Query database: "Show me all users in the database"
- View schemas: "What Ecto schemas exist?"
- Get documentation: "Show docs for MyApp.Accounts"

### HexDocs (Package Documentation)
Ask Claude to:
- Search docs: "Search for Phoenix LiveView streams documentation"
- Fetch package: "Get the Ecto documentation"

## Quick Start

1. Start a conversation in Claude Code
2. Reference guidelines: Claude will automatically use AGENTS.md
3. Use slash commands: Type `/` to see available commands
4. Let Claude run approved commands without prompts

## Project Guidelines

All project guidelines, best practices, and usage rules are in `AGENTS.md` at the root of the project. Claude Code will automatically reference this file when working on your codebase.

Key guidelines include:
- Phoenix v1.8 patterns (LiveView, components, routing)
- Authentication patterns (phx.gen.auth)
- Ecto best practices
- Testing requirements
- Security checks
- Quality standards (coverage, credo, sobelow)

## Precommit Workflow

Before committing code, run:
```bash
mix precommit
```

This runs:
- Compile with warnings as errors
- Unlock unused dependencies
- Format code
- Run tests

For a full quality check, also run:
```bash
mix test --cover
mix credo --strict
mix sobelow --config
```

## Tips

- Claude Code will always follow AGENTS.md guidelines
- Use the `/precommit` command to run all checks
- Ask Claude to use TideWave to understand your running application
- HexDocs searches work across all your dependencies
- All approved commands run without permission prompts

## Need Help?

- Type `/help` in Claude Code
- Check `AGENTS.md` for project-specific guidelines
- Report issues: https://github.com/anthropics/claude-code/issues
