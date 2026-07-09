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

## Trigger Rules

These are IF/THEN rules. When you encounter the trigger condition, you MUST take the specified action.

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

---

## FORBIDDEN Actions

These are hard failures. If you catch yourself doing any of these, STOP and correct immediately.

- FORBIDDEN: Saying "tests should pass" or "credo should be clean" without running them
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

## Workflow Summary

```text
BEFORE WRITING CODE → GATE 1 (state what applies)
    ↓
WRITE CODE (follow trigger rules as you go)
```
