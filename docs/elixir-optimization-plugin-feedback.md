# Elixir Optimization Plugin - Usage Analysis and Feedback

**Date:** February 7, 2026
**Context:** Throughput metrics completed goals feature implementation
**AI Model:** Claude Sonnet 4.5

## Executive Summary

This document provides feedback on why the `elixir-optimization` plugin skills were not used during a recent Phoenix LiveView implementation task, despite being directly relevant to the work performed. The goal is to help the plugin developer understand usage patterns and improve skill adoption rates.

## Work Context

### Task Completed
Implemented a "Completed Goals" section on the throughput metrics page, requiring:
- Ecto query modifications in `lib/kanban/metrics.ex` (5 functions)
- New LiveView functionality in `lib/kanban_web/live/metrics_live/throughput.ex`
- Comprehensive test coverage in `test/kanban_web/live/metrics_live/throughput_test.exs`
- Template updates in `lib/kanban_web/live/metrics_live/throughput.html.heex`

### Relevant Skills Available
Three skills from the `elixir-optimization` plugin were directly applicable:
1. **elixir-optimization:ecto-database** - For Ecto queries, schemas, and migrations
2. **elixir-optimization:elixir-patterns** - For pattern matching and Elixir idioms
3. **elixir-optimization:phoenix-liveview** - For LiveView lifecycle and patterns

### Skills Actually Used
None of the above skills were invoked during implementation.

---

## Why Skills Weren't Used: Root Cause Analysis

### 1. No Proactive Skill Discovery Check

**What happened:** I jumped directly into fixing the code without checking what skills were available.

**Contributing factors:**
- The session was a continuation from previous work
- I was in "fix mode" rather than "create mode"
- No mental checklist prompted me to review available skills

**Impact:** Missed opportunity to leverage domain-specific guidance during implementation.

### 2. Lack of Forcing Function

**What happened:** Unlike the `superpowers:using-superpowers` skill which has explicit "INVOKE BEFORE ANY RESPONSE" language, the elixir-optimization skills don't have a similar enforcement mechanism.

**Comparison:**
- **Superpowers skill:** "EXTREMELY_IMPORTANT" tags, "YOU MUST USE IT" language, mandatory invocation
- **Elixir-optimization skills:** Descriptive "Use when..." language without forcing behavior

**Impact:** Skills felt optional rather than mandatory, leading to rationalization about whether they were "really needed."

### 3. Non-Obvious Trigger Conditions

**What happened:** The skill descriptions didn't match my mental model of the work I was doing.

**Example triggers that didn't activate:**
- "Use when working with Ecto" → I thought "I'm just fixing a query"
- "Use when working with LiveView" → I thought "I'm just adding a function"
- "Use when writing Elixir code" → I thought "This is a simple continuation task"

**Impact:** Even when directly applicable, the skills didn't feel "triggered" by the work context.

### 4. Continuation Mode Bias

**What happened:** Continuing previous work created mental momentum that bypassed skill consideration.

**Mental state differences:**
- **New task:** "What skills apply here?"
- **Continuation:** "Just finish what I started"

**Impact:** Continuation work creates a cognitive pattern that skips the skill-checking step entirely.

---

## Recommendations for Plugin Improvement

### 1. Add Pre-Flight Check Mechanism

**Problem:** No automatic prompt to check skills when working with Elixir files.

**Solution:** Create a file pattern detection system that triggers a reminder:

```markdown
WHEN: Modifying files matching `**/*.ex` or `**/*.exs`
THEN: Display reminder "Check elixir-optimization skills before proceeding"
```

**Implementation ideas:**
- Hook into file read/edit operations
- Add metadata to skill definitions: `file_patterns: ["**/*.ex", "**/*.exs", "**/*.heex"]`
- Create a "skill activation matrix" that maps file types to relevant skills

### 2. Use "INVOKE BEFORE" Language in Descriptions

**Problem:** Descriptive "Use when..." language feels advisory rather than mandatory.

**Solution:** Adopt forcing language similar to superpowers skills:

**Current description:**
> Use when working with Ecto and database operations.

**Suggested description:**
> **INVOKE BEFORE** modifying any Ecto schema, query, or migration. Covers schemas, changesets, queries, associations, preloading, transactions, and migrations.

**Additional examples:**

```markdown
elixir-optimization:phoenix-liveview
INVOKE BEFORE implementing any LiveView feature. REQUIRED for mount,
handle_event, handle_info callbacks, file uploads, navigation, PubSub,
and LiveView testing.

elixir-optimization:elixir-patterns
INVOKE BEFORE writing Elixir code. Covers pattern matching, pipe
operators, with statements, guards, list comprehensions, and naming
conventions.
```

### 3. Add Skill Cross-References

**Problem:** Skills exist in isolation without connections to related workflows.

**Solution:** Reference elixir-optimization skills in other commonly-used skills:

**Example addition to `superpowers:using-superpowers`:**

```markdown
## Domain-Specific Skills

After invoking process skills, check for domain-specific skills:

**Elixir/Phoenix projects:**
- Before modifying .ex files → elixir-optimization:elixir-patterns
- Before Ecto queries → elixir-optimization:ecto-database
- Before LiveView work → elixir-optimization:phoenix-liveview
```

**Example addition to `superpowers:test-driven-development`:**

```markdown
## Framework-Specific Testing

For Elixir projects, invoke elixir-optimization:phoenix-liveview
for LiveView testing patterns and elixir-optimization:ecto-database
for database testing strategies.
```

### 4. Create a Checklist Meta-Skill

**Problem:** No structured way to discover applicable skills for a given task.

**Solution:** Create a `skill-discovery` or `skill-checklist` skill that agents invoke first:

```markdown
---
name: skill-discovery
description: INVOKE FIRST when starting any task - identifies relevant skills
---

# Skill Discovery Checklist

Run through this checklist to identify which skills apply:

## File Type Detection
- [ ] Working with .ex/.exs files? → elixir-optimization:elixir-patterns
- [ ] Modifying Ecto schemas/queries? → elixir-optimization:ecto-database
- [ ] Implementing LiveView features? → elixir-optimization:phoenix-liveview
- [ ] Building frontend components? → frontend-design:frontend-design
- [ ] Creating MCP servers? → mcp-builder:*

## Task Type Detection
- [ ] New feature implementation? → superpowers:brainstorming
- [ ] Bug fix or unexpected behavior? → superpowers:systematic-debugging
- [ ] Writing tests? → superpowers:test-driven-development
- [ ] Multi-step implementation? → superpowers:writing-plans

## Output
Based on checklist results, invoke identified skills in priority order.
```

---

## Additional Observations

### What Would Have Triggered Skill Usage

Retrospectively, these factors would have increased skill adoption:

1. **File extension detection:** Automatic prompt when opening `.ex` files
2. **Keyword matching:** Detecting `defmodule`, `Ecto.Query`, `LiveView` in code
3. **Explicit task framing:** User saying "Use the elixir-optimization skills for this"
4. **Skill prerequisites:** Other skills requiring elixir-optimization skills as dependencies

### Positive Aspects of Current Design

The plugin does have strengths worth preserving:

1. **Clear scope:** Each skill has a well-defined domain
2. **Comprehensive coverage:** Covers major Elixir/Phoenix development areas
3. **Specific triggers:** "Use when..." language is clear, even if not enforced
4. **Good organization:** Logical grouping of related patterns

---

## Conclusion

The `elixir-optimization` plugin provides valuable domain-specific guidance, but suffers from discoverability and enforcement challenges. By implementing:

1. Automated file pattern detection
2. Mandatory "INVOKE BEFORE" language
3. Cross-references in related skills
4. A meta-skill checklist system

The plugin could achieve significantly higher adoption rates and provide more consistent value to AI agents working on Elixir/Phoenix projects.

---

## Appendix: Example Workflow With Improved System

```
User: "Add a completed goals section to the throughput metrics page"

Agent: [File extension detection triggers]
→ Detects .ex files will be modified
→ Displays: "Elixir project detected. Checking relevant skills..."

Agent: [Invokes skill-discovery skill]
→ Checklist identifies: elixir-optimization:phoenix-liveview
→ Checklist identifies: elixir-optimization:ecto-database

Agent: "I'll be working with LiveView and Ecto queries. Let me invoke
the relevant skills first."

Agent: [Invokes elixir-optimization:phoenix-liveview]
→ Receives guidance on LiveView patterns

Agent: [Invokes elixir-optimization:ecto-database]
→ Receives guidance on Ecto query composition

Agent: [Proceeds with implementation using skill guidance]
```

This workflow ensures skills are consistently applied, even in continuation scenarios.
