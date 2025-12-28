# Fixed Workflow Hooks for Doing and Review Columns

**Complexity:** Small | **Est. Files:** 1-2

## Description

**WHY:** Agents need to execute commands at specific workflow transition points: before starting work (Doing), after completing work (Doing), before review (Review), and after successful review (Review).

**WHAT:** Document the fixed hook execution points tied to the Doing and Review columns. Hooks are NOT configurable - they are hardcoded to execute at specific workflow transitions.

**WHERE:** `.stride.md` file in project root (version-controlled agent configuration)

## Acceptance Criteria

- [ ] Documentation for fixed hook execution points
- [ ] `.stride.md` file format documented
- [ ] Hook execution workflow clearly defined
- [ ] Example `.stride.md` provided

## Hook Execution Points

Hooks are **fixed** to these specific workflow transitions:

### 1. before_doing
- **When**: After claiming a task, before entering Doing column
- **Purpose**: Setup work environment, create branch, run pre-work checks
- **Blocking**: Yes - failure prevents task from being claimed

### 2. after_doing
- **When**: After work is done, before moving to Review column
- **Purpose**: Run tests, format code, commit changes
- **Blocking**: Yes - failure prevents task from being marked complete

### 3. before_review
- **When**: When task enters Review column
- **Purpose**: Push changes, create PR, notify reviewers
- **Blocking**: No - failure is logged but doesn't prevent review

### 4. after_review
- **When**: After successful review, before moving to Done column
- **Purpose**: Merge PR, deploy, cleanup
- **Blocking**: No - failure is logged but doesn't prevent completion

## Agent Workflow

The agent follows this workflow:

```
1. Claim task → Execute before_doing hook
2. Move to Doing column
3. Perform work
4. Call complete endpoint → Execute after_doing hook
5. Move to Review column → Execute before_review hook
6. If needs_review=false:
   - Immediately execute after_review hook
   - Move to Done column
7. If needs_review=true:
   - Wait for human review
   - After successful review → Execute after_review hook
   - Move to Done column
```

## .stride.md File Format

Create `.stride.md` in project root (version-controlled):

```markdown
# Stride Agent Configuration

## Agent: Claude Sonnet 4.5

### Capabilities
- code_generation
- testing
- elixir
- phoenix

### Hook Implementations

#### before_doing
```bash
echo "Starting work on task $TASK_ID: $TASK_TITLE"
git checkout -b "task/$TASK_IDENTIFIER"
```

#### after_doing
```bash
echo "Completed work on task $TASK_ID"
# Run your project's test suite (customize for your tech stack)
# Examples for different technologies:
#   npm test                    # JavaScript/Node.js
#   pytest                      # Python
#   mvn test                    # Java/Maven
#   cargo test                  # Rust
#   go test ./...               # Go
#   dotnet test                 # .NET
#   mix test                    # Elixir
# Add your test command here, for example:
# npm test
git add .
git commit -m "Complete task $TASK_IDENTIFIER: $TASK_TITLE"
```

#### before_review
```bash
echo "Submitting task $TASK_ID for review"
git push origin HEAD
# Optional: Create pull request using GitHub CLI
# gh pr create --title "$TASK_TITLE" --body "Closes #$TASK_ID"
```

#### after_review
```bash
echo "Task $TASK_ID approved, merging"
# Optional: Auto-merge PR using GitHub CLI
# gh pr merge --squash --auto
git checkout main
git pull origin main
git branch -D "task/$TASK_IDENTIFIER"
```
```

## Technical Notes

**Key Design Decisions:**
- **No database fields needed** - Hooks are hardcoded to column transitions
- **No configuration UI** - `.stride.md` is edited directly by developers
- **Fixed execution points** - Cannot be moved or disabled per-column
- **Simple workflow** - Four hooks total, tied to two columns (Doing, Review)

**Hook Properties:**
- `before_doing` - Blocking, timeout: 60s
- `after_doing` - Blocking, timeout: 120s (for tests)
- `before_review` - Non-blocking, timeout: 60s
- `after_review` - Non-blocking, timeout: 60s

**Environment Variables Available:**
- `TASK_ID` - Numeric task ID
- `TASK_IDENTIFIER` - Task identifier (W27, D3, G1, etc.)
- `TASK_TITLE` - Task title
- `TASK_DESCRIPTION` - Task description
- `TASK_COMPLEXITY` - small/medium/large
- `TASK_PRIORITY` - Priority level
- `BOARD_ID` - Board ID
- `BOARD_NAME` - Board name
- `COLUMN_ID` - Current column ID
- `COLUMN_NAME` - Current column name
- `AGENT_NAME` - Name of agent from .stride.md

## Verification

**Manual Testing:**
1. Create `.stride.md` in project root with sample hooks
2. Claim a task as an agent
3. Verify `before_doing` hook executes
4. Complete work and call complete endpoint
5. Verify `after_doing` hook executes
6. Task moves to Review column
7. Verify `before_review` hook executes
8. If task doesn't need review:
   - Verify `after_review` hook executes immediately
   - Task moves to Done
9. If task needs review:
   - Wait for human review
   - Mark reviewed
   - Verify `after_review` hook executes
   - Task moves to Done

**Success Looks Like:**
- Hooks execute at correct workflow points
- Environment variables populated correctly
- Blocking hooks prevent action on failure
- Non-blocking hooks log errors but don't block
- Continuous workflow: agent claims → work → complete → review in one flow

## Observability

- [ ] Telemetry event: `[:kanban, :hook, :executed]` with hook name and status
- [ ] Logging: Info level for successful hooks, warn for failures

## Dependencies

**Requires:** None (just documentation)
**Blocks:** Task 14 (Hook Execution Engine implementation)

## Out of Scope

- Don't add database fields for hook configuration
- Don't implement UI for editing hooks
- Don't allow per-column hook customization
- Don't add conditional hook execution
- Hooks are NOT configurable - they are fixed to Doing and Review columns
