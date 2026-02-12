---
name: stride-development-guidelines
description: Use when writing ANY code in the Stride project (this Phoenix/Elixir kanban application). Invoke BEFORE implementing features, fixing bugs, or making UI changes. Invoke BEFORE marking any development task as complete.
---

# Stride Development Guidelines

This skill applies to ALL code changes in this codebase. No exceptions.

Standards for quality, security, UI/UX, and dark mode are defined in AGENTS.md.
This skill enforces them. Your job is not to re-read the standards — it is to EXECUTE the checks.

---

## GATE 1: Before Writing Code

STOP. Before you write or edit any file in `lib/`, `test/`, or `assets/`, state out loud which of these apply to your change:

- Modifying UI (`.heex`, `core_components`, CSS) → Dark mode verification REQUIRED
- Adding new functions → Unit tests REQUIRED
- Modifying existing code → Existing tests must pass REQUIRED
- Adding/updating dependencies → Security audit REQUIRED
- Editing a module over 400 lines → Check line count, propose split if over 500

IF none apply, state "No special requirements for this change" and proceed.

You MUST NOT skip this step. Silently proceeding without stating applicability is a violation.

---

## GATE 2: After Writing Code

STOP. Run these commands and show the output. Do NOT claim they pass without running them.

1. `mix test` — all tests must pass
2. `mix credo --strict` — no issues

IF you wrote new functions, you MUST have written tests for them before reaching this gate.

IF you modified UI, you MUST have verified dark mode before reaching this gate (see Trigger Rules below).

---

## GATE 3: Before Marking Complete

STOP. Run `mix precommit` and show the output. This runs all quality and security checks together.

IF anything fails, fix it and re-run. Do NOT mark complete until `mix precommit` passes with output shown.

---

## Trigger Rules

These are IF/THEN rules. When you encounter the trigger condition, you MUST take the specified action.

**IF you are about to write a hardcoded color in a template:**
→ STOP. Use the theme-aware equivalent from the Dark Mode Color Map below. Never use `text-gray-*`, `bg-white`, `bg-gray-*`, or `border-gray-*` in templates.

**IF you are creating a new function:**
→ You MUST write a unit test for it. No exceptions. Run the test and show it passes.

**IF a module you are editing is over 400 lines:**
→ STOP. Count the lines. If over 500, propose a refactoring split before adding more code. Follow the module design patterns in AGENTS.md.

**IF you are adding or modifying any UI element:**
→ Check `core_components.ex` FIRST for existing components (`<.input>`, `<.button>`, `<.form>`).
→ Use existing components. Do NOT create custom alternatives unless specifically requested.
→ Verify the change works in BOTH light and dark modes.

**IF you are modifying a `.heex` file, CSS file, or `core_components.ex`:**
→ You MUST verify dark mode. Test in both light and dark modes before proceeding.
→ Use browser evaluation or visual inspection to confirm contrast in both themes.

**IF you are adding or updating a dependency:**
→ Run `mix deps.audit`, `mix hex.audit`, and `mix hex.outdated`. Show the output.

**IF you are about to say "done", "complete", or "finished":**
→ STOP. Go to GATE 3. Run `mix precommit`. Show the output. Only then say complete.

---

## FORBIDDEN Actions

These are hard failures. If you catch yourself doing any of these, STOP and correct immediately.

- FORBIDDEN: Saying "tests should pass" or "credo should be clean" without running them
- FORBIDDEN: Marking a task complete without showing passing output from `mix precommit`
- FORBIDDEN: Adding UI elements without checking `core_components.ex` first
- FORBIDDEN: Skipping dark mode verification on any UI change
- FORBIDDEN: Writing new functions without unit tests
- FORBIDDEN: Putting Ecto queries directly in LiveViews (use context modules)
- FORBIDDEN: Adding text visible in the UI without providing translations

---

## Red Flags — STOP If You Think Any of These

| Thought | Reality |
|---------|---------|
| "It's just a small change" | Small changes break dark mode constantly. Verify. |
| "Tests probably still pass" | Run them. "Probably" is not evidence. |
| "Credo is just style" | Credo catches real bugs and complexity issues. |
| "Security checks are overkill" | One missed vulnerability = production incident. |
| "I'll check dark mode later" | You won't. Check now. |
| "The module isn't that big" | Count the lines. Over 500 = split it. |
| "I already know this passes" | Show the output. Knowledge without proof is assumption. |

---

## Dark Mode Color Map (Reference)

Use this table when writing or reviewing template colors.

| Never Use          | Always Use Instead              |
| ------------------ | ------------------------------- |
| `text-gray-900`    | `text-base-content`             |
| `text-gray-600`    | `text-base-content opacity-70`  |
| `text-gray-500`    | `text-base-content opacity-60`  |
| `bg-white`         | `bg-base-100`                   |
| `bg-gray-50`       | `bg-base-200`                   |
| `border-gray-200`  | `border-base-300`               |

### Dark Mode Element Fixes

| Element                | Fix                                                                            |
| ---------------------- | ------------------------------------------------------------------------------ |
| Labels invisible       | `text-base-content` with full opacity                                          |
| Inputs invisible       | `bg-base-100` background, `text-base-content` text, `border-base-300` border   |
| Low contrast buttons   | `btn-primary` or `var(--color-primary)` background                             |
| Low contrast links     | `var(--color-primary)` color                                                   |
| White modal background | `bg-base-100` instead of `bg-white`                                            |
| Modal backdrop         | `bg-base-200/90` for proper overlay                                            |

### Dark Mode Contrast Targets

| Mode | Text | Background |
|------|------|------------|
| Light | Dark text (oklch ~0.21) | Light backgrounds (oklch ~0.98) |
| Dark | Light text (oklch ~0.97) | Dark backgrounds (oklch ~0.30) |

---

## Workflow Summary

```text
BEFORE WRITING CODE → GATE 1 (state what applies)
    ↓
WRITE CODE (follow trigger rules as you go)
    ↓
AFTER WRITING CODE → GATE 2 (mix test + mix credo --strict, show output)
    ↓
BEFORE MARKING COMPLETE → GATE 3 (mix precommit, show output)
```

`mix precommit` runs tests, coverage, credo, and sobelow together. Use it at GATE 3.
