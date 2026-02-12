---
name: stride-development-guidelines
description: Use when writing ANY code in the Stride project (this Phoenix/Elixir kanban application). Invoke BEFORE implementing features, fixing bugs, or making UI changes. Enforces module design, UI/UX, dark mode, quality, and security standards.
---

## What is the Stride Project?

**Stride is THIS codebase** - the Phoenix/Elixir kanban task management application you are currently working in. This skill applies to ALL code changes made within this project.

**Git repository:** `cheezy/kanban` (GitHub)

To verify you're in the Stride project, check if the git remote matches:
```bash
git remote -v | grep -q "cheezy/kanban"
```

## The Iron Law

ALL CODE CHANGES IN THE STRIDE PROJECT MUST PASS: Module design review, UI/UX consistency check, dark mode verification, quality checks (tests + coverage + credo), and security audits.

## When to Use This Skill

**INVOKE THIS SKILL when you are about to write code in the Stride project:**

- Before implementing any new feature in this codebase
- Before fixing any bug in this codebase
- After making any UI changes in this codebase
- Before marking any Stride development task as complete
- Before creating a PR for this repository

**This skill is NOT for:**
- Tasks claimed from the Stride API (those use stride-claiming-tasks, stride-completing-tasks, etc.)
- Working on OTHER codebases

**This skill IS for:**
- Writing Elixir code in `lib/`
- Writing tests in `test/`
- Modifying templates in `lib/kanban_web/`
- Changing CSS in `assets/`
- Any code changes to this Phoenix application

---

## Module Design and Complexity

**IMPORTANT**: When working with modules that are becoming too large or complex:

### Module Size Thresholds

| Threshold | Action Required |
|-----------|-----------------|
| ~500-600 lines | Consider refactoring |
| Cyclomatic complexity > 9 | Extract helper functions |
| Deeply nested logic | Break out logical concerns |

### Refactoring Patterns

**Break out logical concerns** - Extract related functionality into separate, focused modules:

```
Tasks (main module)
├── Tasks.Positioning     # Position/ordering logic
├── Tasks.Dependencies    # Dependency management
├── Tasks.Validation      # Validation logic
└── Tasks.Queries         # Query builders
```

**Extract helper functions** - When a function becomes complex:
- Cyclomatic complexity > 9 = MUST extract
- Extract complex conditional logic into smaller, well-named helper functions
- Each helper should have a single, clear purpose

**Maintain clear module boundaries**:
- Each module should have a clear, single purpose
- Define a well-defined public API
- Document module organization when splitting

### Benefits Checklist

When refactoring, verify these improve:
- [ ] Code maintainability and readability
- [ ] Test isolation and coverage
- [ ] Collaboration between developers
- [ ] Ability to reason about individual components
- [ ] Credo compliance and code quality metrics

---

## UI/UX Guidelines

### The Rules

1. **Always follow existing application styles and patterns** when adding new UI elements
2. Check `core_components.ex` FIRST for existing components (`<.input>`, `<.button>`, `<.form>`, etc.)
3. Use standard component structure with `fieldset`, `label`, and `span.label` classes
4. New buttons MUST use `<.button>` component without custom classes unless specifically requested
5. Maintain consistency with existing color schemes, spacing, and typography

### Before Adding UI Elements

```
CHECKLIST:
├── 1. Check core_components.ex for existing component ✓
├── 2. Review similar UI in the app for patterns ✓
├── 3. Use standard form structure (fieldset, label, span.label) ✓
├── 4. Verify consistency with existing styles ✓
└── 5. Test in BOTH light and dark modes ✓
```

---

## Dark Mode Verification Guidelines

**CRITICAL**: Always verify UI changes work in BOTH light and dark modes before considering a task complete.

### When to Verify Dark Mode

- After adding or modifying any UI component
- After changing CSS styles or Tailwind classes
- After updating modal, form, or layout components
- When users report visibility issues
- **Before marking any UI-related task as complete**

### Common Dark Mode Issues and Fixes

#### 1. Hardcoded Colors

| Issue | Fix |
|-------|-----|
| `text-gray-900` | `text-base-content` |
| `text-gray-600` | `text-base-content opacity-70` |
| `text-gray-500` | `text-base-content opacity-60` |
| `bg-white` | `bg-base-100` |
| `bg-gray-50` | `bg-base-200` |
| `border-gray-200` | `border-base-300` |

#### 2. Form Elements

- **Issue**: Labels and inputs invisible in dark mode
- **Fix**: Labels use `text-base-content` with full opacity
- **Fix**: Inputs have `bg-base-100` background and `text-base-content` text
- Add visible borders with `border-base-300`

#### 3. Buttons and Links

- **Issue**: Low contrast buttons/links in dark mode
- **Fix**: Use `btn-primary` classes or override with `var(--color-primary)` background
- **Fix**: Button text uses `var(--color-primary-content)`
- **Fix**: Links use `var(--color-primary)` for visibility

#### 4. Modal Backgrounds

- **Issue**: White modal backgrounds in dark mode
- **Fix**: Use `bg-base-100` instead of `bg-white`
- **Fix**: Modal backdrop uses `bg-base-200/90` for proper overlay

### Dark Mode Verification Process

**Step 1: Use browser_eval to test both modes**

```javascript
// Test in dark mode
await page.eval(() => {
  localStorage.setItem('phx:theme', 'dark');
  document.documentElement.setAttribute('data-theme', 'dark');
});

// Check element visibility
await page.eval(() => {
  const el = document.querySelector('.your-element');
  const style = window.getComputedStyle(el);
  console.log('Color:', style.color);
  console.log('Background:', style.backgroundColor);
});

// Test in light mode
await page.eval(() => {
  localStorage.setItem('phx:theme', 'light');
  document.documentElement.setAttribute('data-theme', 'light');
});
```

**Step 2: Verify contrast**

| Mode | Text | Background |
|------|------|------------|
| Light | Dark text (oklch ~0.21) | Light backgrounds (oklch ~0.98) |
| Dark | Light text (oklch ~0.97) | Dark backgrounds (oklch ~0.30) |
| Buttons | High contrast in both modes using primary colors |

**Step 3: Test all sections**

- [ ] Headers/titles
- [ ] Form labels and inputs
- [ ] Buttons and links
- [ ] Text content
- [ ] Borders and dividers
- [ ] Modal overlays

### CSS Patterns for Dark Mode Support

**In assets/css/app.css:**

```css
@layer components {
  /* Labels with full opacity */
  .label {
    color: var(--color-base-content) !important;
    opacity: 1 !important;
  }

  /* Inputs with theme-aware backgrounds */
  input.input,
  textarea.textarea,
  select.select {
    background-color: var(--color-base-100) !important;
    color: var(--color-base-content) !important;
    border-color: var(--color-base-300) !important;
  }

  /* High contrast buttons */
  .btn-primary {
    background-color: var(--color-primary) !important;
    color: var(--color-primary-content) !important;
  }

  /* Visible links */
  a {
    color: var(--color-primary) !important;
  }
}
```

**In templates:**

```heex
<!-- Use theme-aware classes -->
<h1 class="text-base-content">Title</h1>
<p class="text-base-content opacity-70">Subtitle</p>
<div class="bg-base-100 border-base-300">Content</div>
```

---

## Quality Guidelines

**ALWAYS** follow these quality guidelines:

### Testing Requirements

| When | Action |
|------|--------|
| Complete task with new functions | Write unit tests for new functions |
| Complete task with code updates | Ensure existing tests pass, write new tests if needed |
| Write/update unit tests | Run `mix test` and ensure they pass |
| Complete any task | Run `mix test --cover` and ensure coverage is above threshold |
| Complete any task | Run `mix credo --strict` and fix any issues |

### Quality Checklist

```
BEFORE MARKING COMPLETE:
├── 1. New functions have unit tests ✓
├── 2. All existing tests pass ✓
├── 3. mix test --cover passes threshold ✓
└── 4. mix credo --strict shows no issues ✓
```

### Running Quality Checks

```bash
# Run all tests
mix test

# Run tests with coverage
mix test --cover

# Run credo
mix credo --strict
```

---

## Security Guidelines

**ALWAYS** follow these security guidelines:

### Dependency Security

| When | Action |
|------|--------|
| Add or update a dependency | Run `mix deps.audit` and `mix hex.audit` |
| Add or update a dependency | Run `mix hex.outdated` to check for outdated deps |
| Complete any task | Run `mix sobelow --config` and fix any issues |

### Security Checklist

```
BEFORE MARKING COMPLETE:
├── 1. mix deps.audit passes ✓
├── 2. mix hex.audit passes ✓
├── 3. mix hex.outdated reviewed ✓
└── 4. mix sobelow --config shows no issues ✓
```

### Running Security Checks

```bash
# Check for known vulnerabilities in deps
mix deps.audit

# Check hex packages for security issues
mix hex.audit

# Check for outdated dependencies
mix hex.outdated

# Run static security analysis
mix sobelow --config
```

---

## Pre-Completion Checklist

Before marking ANY task as complete, verify ALL of the following:

### Code Quality

- [ ] Module under 500-600 lines (or properly split)
- [ ] Functions have cyclomatic complexity < 9
- [ ] Clear module boundaries with single purpose

### UI/UX (if applicable)

- [ ] Uses existing components from core_components.ex
- [ ] Follows existing patterns and styles
- [ ] Works in BOTH light and dark modes
- [ ] All text uses theme-aware colors

### Quality Checks

- [ ] `mix test` passes
- [ ] `mix test --cover` above threshold
- [ ] `mix credo --strict` passes

### Security Checks

- [ ] `mix deps.audit` passes
- [ ] `mix hex.audit` passes
- [ ] `mix sobelow --config` passes

---

## Red Flags - STOP

These thoughts mean you're about to skip important checks:

| Thought | Reality |
|---------|---------|
| "It's just a small change" | Small changes break dark mode constantly |
| "Tests probably still pass" | Run them. 40% of "probably" is wrong. |
| "Credo is just style" | Credo catches real bugs and complexity issues |
| "Security checks are overkill" | One missed vuln = production incident |
| "I'll check dark mode later" | You won't. Check now. |
| "The module isn't that big" | Count the lines. 500+ = split it. |

---

## Quick Reference

```
DEVELOPMENT WORKFLOW:
├── 1. Implement feature/fix
├── 2. Check module size/complexity
├── 3. Verify UI uses existing components
├── 4. Test in BOTH light and dark modes
├── 5. Run mix test
├── 6. Run mix test --cover
├── 7. Run mix credo --strict
├── 8. Run mix deps.audit
├── 9. Run mix hex.audit
├── 10. Run mix sobelow --config
└── 11. ALL pass? → Mark complete
```

**Remember:** `mix precommit` runs all quality and security checks together.
