# Changelog

All notable changes to the Kanban Board application will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.21.2] - 2026-02-03

### Added

#### OpenCode & Kimi Code CLI AI Assistant Support

- **Multi-Agent Integration Expansion** - Added comprehensive support for OpenCode and Kimi Code CLI as the sixth supported AI coding assistant format (shared AGENTS.md format):
  - **AGENTS.md Instruction File**: Created Markdown-formatted instruction file (~15KB, ~400 lines) with complete Stride integration guidelines
  - **Append-Mode Installation**: Unique installation strategy that appends Stride instructions to existing AGENTS.md files rather than overwriting, preserving project-specific instructions
  - **Hierarchical File Search**: Supports project-scoped (`./AGENTS.md`) and global (`~/.config/opencode/AGENTS.md`) locations with hierarchical search from current directory upward
  - **Onboarding Endpoint Integration**: Added OpenCode/Kimi format to `/api/agent/onboarding` multi_agent_instructions section with safe installation commands
  - **Format Compatibility**: Both OpenCode and Kimi Code CLI (k2.5) use identical AGENTS.md file format and locations

**Multi-Agent Instructions (Now 6 Formats):**
1. GitHub Copilot (`.github/copilot-instructions.md`)
2. Cursor (`.cursorrules`)
3. Windsurf Cascade (`.windsurfrules`)
4. Continue.dev (`.continue/config.json`)
5. Google Gemini Code Assist (`GEMINI.md` or `AGENT.md`)
6. **OpenCode & Kimi Code CLI** (`AGENTS.md`)

*Note: Claude Code uses contextual Skills rather than always-active instructions.*

## [1.21.1] - 2026-01-26

### Fixed

#### Automatic Task Status Synchronization

- **Task Status Now Syncs Automatically When Moving Between Columns** - Fixed data inconsistency issue where task status could be out of sync with column position:
  - **Ready/Backlog Columns**: Automatically sets `status: :open` and clears `completed_at`
  - **Doing/Review Columns**: Automatically sets `status: :in_progress` and clears `completed_at`
  - **Done Column**: Automatically sets `status: :completed` and sets `completed_at` timestamp
  - **Preserves Timestamps**: When task already has `completed_at` set, preserves the original timestamp
  - **Impact**: Eliminates the inconsistency where agents sometimes failed to update status when completing tasks, ensuring column position and status always match

## [1.21.0] - 2026-01-23

### Added

#### Read-Only Board Sharing

- **Public Board Sharing** - Board owners can now share boards publicly for read-only access:
  - **Read-Only Checkbox** - Added "Make board publicly readable" checkbox to board edit form
  - **Public Access** - Anyone with the direct link can view boards marked as read-only

## [1.20.0] - 2026-01-19

### Added

#### Google Gemini Code Assist Support

- **Multi-Agent Integration Expansion** - Added comprehensive support for Google Gemini Code Assist as the fifth supported AI coding assistant:
  - **GEMINI.md Instruction File**: Created Markdown-formatted instruction file with complete Stride integration guidelines
  - **Hierarchical Context Support**: Supports project-scoped, global (`~/.gemini/GEMINI.md`), and component-level context files
  - **Impact**: Gemini Code Assist users can now leverage Stride's workflow enforcement with agent/chat mode context files

**Supported AI Assistants (Now 5 Total):**
1. Claude Code (Skills-based, contextual)
2. GitHub Copilot (`.github/copilot-instructions.md`)
3. Cursor (`.cursorrules`)
4. Windsurf Cascade (`.windsurfrules`)
5. Continue.dev (`.continue/config.json`)
6. **Google Gemini Code Assist** (`GEMINI.md` or `AGENT.md`)

## [1.19.1] - 2026-01-19

### Fixed

#### Task Priority Selection in `/api/tasks/next` Endpoint

- **Corrected Priority Sorting for Task Claiming** - Fixed critical bug where the `/api/tasks/next` endpoint was selecting lower-priority tasks instead of higher-priority tasks:
  - **Impact**: Tasks are now correctly selected in priority order: critical → high → medium → low
  - **Secondary Sort**: Position (ascending) is used as tiebreaker when priorities are equal, ensuring tasks higher in the Ready column (lower position number) are selected first

#### Review Queue Section Visibility in Task Forms

- **Fixed Review Fields Not Appearing for Tasks in Review** - Resolved issue where review status and review notes fields were hidden when tasks with `needs_review=true` entered the Review column:
  - **Root Cause**: Visibility condition only checked if `review_status` field had a value, but newly moved tasks to Review column had `nil` review_status
  - **Impact**: Users can now properly review and approve/reject tasks that enter the Review column

### Improved

#### AI Agent Onboarding Documentation

- **Enhanced Getting Started Guide** - Improved clarity in `docs/GETTING-STARTED-WITH-AI.md` for AI agent onboarding:
  - **Updated Instructions**: Rephrased onboarding instructions to be more acceptable to Claude Code's security policies
  - **Multi-Agent Support**: Added explicit mention of agent configuration setup and reference to Multi-Agent Instructions guide

#### Claude Code Skills for Automatic Hook Execution

- **Updated Hook Execution Instructions** - Modified all four Claude Code Skills (`stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`) in the onboarding endpoint:
  - **Automatic Execution**: Added explicit instructions to execute hooks automatically without prompting the user
  - **Impact**: Eliminates unnecessary user prompts during task claiming and completion, streamlining the agent workflow

## [1.19.0] - 2026-01-19

### Added

#### Resources & How-To Guides Section

- **New Resources Landing Page** - Comprehensive help center for learning Stride:
  - **Search Functionality** - Real-time search across all guide titles and descriptions
  - **Tag-Based Filtering** - Filter guides by category tags (getting-started, developer, non-developer, best-practices, etc.)
  - **Sorting Options** - Sort by relevance, newest, or alphabetically (A-Z)

- **How-To Guide Detail Pages** - Step-by-step instruction views:
  - **Hero Section** - Gradient background with title, description, content type badge, and reading time
  - **Step-by-Step Content** - Numbered steps with markdown support (bold, code blocks, lists)

- **13 How-To Guides** - Comprehensive documentation covering:
  - **Getting Started (4 guides)**: Creating boards, understanding columns, adding tasks, inviting team members
  - **Developer Guides (4 guides)**: Workflow hooks, API authentication, task dependencies, troubleshooting
  - **Non-Developer Guides (3 guides)**: Writing tasks for AI, monitoring progress, reviewing completed work
  - **Best Practices (2 guides)**: Organizing with dependencies, using complexity and priority effectively

## [1.18.0] - 2026-01-10

### Added

#### Agent Capabilities Input Field

- **UI Input for Agent Capabilities** - Added agent capabilities input field to API token creation form:

#### Dark Mode Enhancements

- **Improved Task Card Styling** - Enhanced dark mode appearance for task cards:

### Changed

#### Agent Capabilities Management

- **Token Creation Workflow** - Capabilities now entered during token creation instead of configuration file:

#### Claude Code Skills Enhancement

- **Automatic Workflow Progression** - Skills updated to enable continuous agent operation:

## [1.17.1] - 2026-01-09

### Added

#### Multi-Agent Instructions for Non-Claude Code AI Assistants

- **Four AI Assistant Formats** - Always-active code completion guidance distributed as downloadable files:
  - **GitHub Copilot** (`.github/copilot-instructions.md`) - Repository-scoped instructions optimized for 4000 token limit
  - **Cursor** (`.cursorrules`) - Project-scoped rules with expanded examples for 8000 token limit
  - **Windsurf Cascade** (`.windsurfrules`) - Hierarchical rules that cascade from parent directories
  - **Continue.dev** (`.continue/config.json`) - JSON configuration with custom context providers and slash commands

- **Onboarding Endpoint Enhancement** - `GET /api/agent/onboarding` now includes `multi_agent_instructions` section:
  - Download URLs for all four instruction formats
  - Platform-specific installation commands (Unix/Linux/macOS and Windows)
  - Token limit information for each format
  - Usage notes explaining complementary relationship with Claude Code Skills
  - Safe installation guidance (backup, append, manual merge options)

- **Documentation Directory** - All instruction files stored in `docs/multi-agent-instructions/`:
  - `copilot-instructions.md` (9KB) - Markdown format with code examples
  - `cursorrules.txt` (15KB) - Plain text with detailed patterns
  - `windsurfrules.txt` (15KB) - Plain text with cascading rules
  - `continue-config.json` (4KB) - JSON with custom commands and context providers

- **Core Content Coverage** - All formats include essential Stride integration guidance:
  - Hook execution mandate (all four hooks and their requirements)
  - Top 5 critical mistakes agents make
  - Essential task field requirements
  - Code patterns for claiming, completing, and creating tasks
  - Batch creation examples
  - Documentation links

### Changed

#### Onboarding Endpoint Optimization

- **Multi-Agent Instructions Architecture** - Complementary approach to Claude Code Skills:
  - **Claude Code Skills**: Contextual workflow enforcement (1000+ lines per skill, embedded content)
  - **Multi-Agent Instructions**: Always-active code completion (200-400 lines, downloadable files)

## [1.17.0] - 2026-01-08

### Added

#### Claude Code Skills for AI Agent Workflow Enforcement

- **Four Workflow Enforcement Skills** - Complete set of Claude Code skills distributed via the onboarding endpoint to enforce Stride workflow discipline:
  - **stride-claiming-tasks** - Enforces proper task claiming workflow with hook execution before claiming
  - **stride-completing-tasks** - Ensures both after_doing and before_review hooks are executed before marking tasks complete
  - **stride-creating-tasks** - Requires comprehensive task specifications to prevent 3+ hour exploration failures
  - **stride-creating-goals** - Enforces proper goal structure with nested tasks and correct batch format

- **Onboarding Endpoint Distribution** - Skills automatically provided through `GET /api/agent/onboarding`:
  - Complete skill content embedded in JSON response
  - Step-by-step installation instructions with exact commands
  - Usage guidance explaining when to invoke each skill
  - Automatic discovery by Claude Code when installed

## [1.16.0] - 2026-01-08

### Added

#### Task Archive System

- **Archive Functionality** - Tasks can now be archived and later restored or permanently deleted:
  - **Archive Tasks** - Archive button added to task card menus on board view
  - **Archived Tasks Page** - Dedicated page (`/boards/:id/archive`) to view all archived tasks for a board
  - **Unarchive Tasks** - Restore archived tasks back to their original column
  - **Permanent Delete** - Delete archived tasks permanently from the database
  - **Archive Navigation** - "Archived Tasks" link added to board header for easy access
  - **Empty State** - Friendly empty state when no archived tasks exist

## [1.15.0] - 2026-01-07

### Changed

#### ⚠️ BREAKING CHANGE: All Four Hooks Now Blocking with Mandatory API Validation

All hooks (`before_doing`, `after_doing`, `before_review`, `after_review`) are now **blocking** and require **mandatory validation** at the API level. Agents must execute hooks before calling endpoints and include execution results in their requests.

**What Changed:**

- **`before_review` hook**: Changed from non-blocking to **blocking** (60s timeout)
- **`after_review` hook**: Changed from non-blocking to **blocking** (60s timeout)
- **API validation enforced**: All endpoints now reject requests (422 error) if required hook results are missing or hooks failed

**Updated API Endpoints:**

1. **`PATCH /api/tasks/:id/complete`** - Now requires BOTH hook results:
   - **Required parameters**: `after_doing_result` AND `before_review_result`
   - **Execution order**: Execute `after_doing` hook FIRST, then `before_review` hook SECOND, then call endpoint
   - **Validation**: Both hooks must succeed (exit_code 0) or request is rejected
   - **Error response**: 422 if either hook result is missing or hook failed

2. **`PATCH /api/tasks/:id/mark_reviewed`** - Now requires hook result:
   - **Required parameter**: `after_review_result`
   - **Execution order**: Execute `after_review` hook FIRST, then call endpoint
   - **Validation**: Hook must succeed (exit_code 0) or request is rejected
   - **Error response**: 422 if hook result is missing or hook failed

**New Workflow (All Hooks Blocking):**

```
1. Execute before_doing hook (blocking, 60s) → Capture result
2. POST /api/tasks/claim WITH before_doing_result
3. [Do work]
4. Execute after_doing hook (blocking, 120s) → Capture result
5. Execute before_review hook (blocking, 60s) → Capture result
6. PATCH /api/tasks/:id/complete WITH after_doing_result AND before_review_result
7. IF needs_review=true: Wait for human approval
8. Execute after_review hook (blocking, 60s) → Capture result
9. PATCH /api/tasks/:id/mark_reviewed WITH after_review_result
```

**Migration Guide for Agents:**

**Before (v1.14.x):**
```bash
# Old: Execute after_doing only before /complete
mix test
curl -X PATCH .../complete -d '{"after_doing_result": {...}}'
# Execute before_review AFTER /complete (non-blocking)
gh pr create ...
```

**After (v1.15.0):**
```bash
# New: Execute BOTH hooks BEFORE /complete
START_1=$(date +%s%3N)
OUTPUT_1=$(timeout 120 bash -c 'mix test' 2>&1)
EXIT_1=$?
DURATION_1=$(($(date +%s%3N) - START_1))

START_2=$(date +%s%3N)
OUTPUT_2=$(timeout 60 bash -c 'gh pr create ...' 2>&1)
EXIT_2=$?
DURATION_2=$(($(date +%s%3N) - START_2))

# Only call /complete if BOTH hooks succeeded
if [ $EXIT_1 -eq 0 ] && [ $EXIT_2 -eq 0 ]; then
  curl -X PATCH .../complete \
    -d "{
      \"after_doing_result\": {\"exit_code\": $EXIT_1, \"output\": \"$OUTPUT_1\", \"duration_ms\": $DURATION_1},
      \"before_review_result\": {\"exit_code\": $EXIT_2, \"output\": \"$OUTPUT_2\", \"duration_ms\": $DURATION_2}
    }"
fi
```

**Why This Change:**

- **Quality Enforcement**: Prevents tasks from entering review with failing PR creation or missing documentation
- **Consistency**: All four hooks now have identical blocking behavior - simpler mental model
- **Early Validation**: Catches issues (failing tests, PR creation failures, deployment failures) before state transitions
- **Audit Trail**: Complete record of all hook execution results in the database

**Updated Documentation:**

- `docs/AI-WORKFLOW.md` - Updated workflow steps and hook execution order
- `docs/api/README.md` - Updated endpoint requirements and examples
- `docs/api/patch_tasks_id_complete.md` - Added `before_review_result` requirement
- `docs/api/patch_tasks_id_mark_reviewed.md` - Added `after_review_result` requirement
- `docs/REVIEW-WORKFLOW.md` - Updated review workflow with new hook execution order
- `docs/GETTING-STARTED-WITH-AI.md` - Updated hook descriptions and examples
- `docs/AGENT-HOOK-EXECUTION-GUIDE.md` - Updated execution patterns
- `docs/STRIDE-SKILLS-PLAN.md` - Updated completion process
- `lib/kanban_web/controllers/api/agent_json.ex` - Updated onboarding endpoint

## [1.14.1] - 2026-01-06

### Fixed

#### WIP Limit Calculation - Goals Exclusion

- **Goals No Longer Count Toward WIP Limits** - Work In Progress (WIP) limits now correctly exclude goal tasks and only count work and defect tasks:

#### Goal Positioning During Drag Operations

- **Fixed Goal Display Order in LiveView** - Goals now consistently appear above their child tasks during live drag-and-drop operations:

#### Dependency Blocking Status in Bulk Upload

- **Dependencies Now Properly Block Tasks in Bulk Upload** - Tasks with dependencies are now correctly marked as blocked when created via bulk upload API endpoint (POST /api/tasks/batch):

## [1.14.0] - 2026-01-05

### Added

#### API Enhancements - Agent Onboarding Endpoint

- **Comprehensive Agent Memory System** - The `/api/agent/onboarding` endpoint has been significantly enhanced to help AI agents remember how to work with Stride across sessions and platforms:

  - **`memory_strategy` section** - Platform-agnostic and platform-specific instructions for maintaining context across sessions:
  - **`session_initialization` section** - Step-by-step checklist for starting new sessions:
  - **`first_session_vs_returning` section** - Different workflows for experience levels:
  - **`common_mistakes_agents_make` section** - Learning from collective experience:
  - **`quick_reference_card` section** - Ultra-condensed essentials for experienced agents:
  - **`quick_reference_card` section** - Ultra-condensed

- **Enhanced Documentation**:
  - `docs/AGENT-MEMORY-SOLUTION.md` - Detailed explanation of the multi-layered memory strategy

#### Why This Matters

This release solves the "agent memory problem" - where AI agents would forget how to work with Stride between sessions. The enhanced onboarding endpoint provides a universal, platform-agnostic solution that works for any AI coding agent (Claude Code, Cursor, Windsurf, Aider, Cline, etc.) in any project using Stride.

### Changed

#### Goal Movement Behavior Enhancement

- **Improved Goal Auto-Positioning** - When a task triggers its parent goal to move to a new column, the goal now positions itself **directly above the task that caused the movement** (instead of above the earliest child in the target column):


## [1.13.2] - 2026-01-05

### Changed

#### UI Improvements - Conditional Field Visibility

- **Conditional Visibility for Status & Agent Tracking Section** - The "Status & Agent Tracking" section in task forms now intelligently shows/hides based on agent interaction:
  - **Fields in Status & Agent Tracking Section**:
    - **Status** - Task status (Open, In Progress, Completed, Blocked)
    - **Created By Agent** - Name of AI agent that created the task
    - **Completed By Agent** - Name of AI agent that completed the task
    - **Completion Summary** - Summary provided by agent upon completion

- **Conditional Visibility for Review Queue Section** - The "Review Queue" section in task forms now only appears when a task has a review status:
  - **Fields in Review Queue Section**:
    - **Review Status** - Pending, Approved, Changes Requested, or Rejected
    - **Review Notes** - Notes from the reviewer about the task

- **Conditional Visibility for Actual Metrics Section** - The "Actual Metrics" section in task forms now only appears when actual metrics data exists:
  - **Fields in Actual Metrics Section**:
    - **Actual Complexity** - Actual complexity level (Small, Medium, Large)
    - **Actual Files Changed** - Number of files actually modified
    - **Time Spent (minutes)** - Actual time spent on the task

### Added

#### Documentation

- **TASK-FORM-FIELD-VISIBILITY.md** - New comprehensive guide explaining task form field visibility:
  - Board-level field visibility settings and configurable fields
  - Always-visible fields vs. conditionally visible fields
  - Detailed explanation of conditional visibility for Status & Agent Tracking, Review Queue, and Actual Metrics
  - API behavior vs. UI form behavior
  - Best practices for board owners, AI agents, and human users
  - Examples and scenarios demonstrating visibility logic

## [1.13.1] - 2026-01-04

### Fixed

#### Drag and Drop Improvements

- **Smoother Animation** - Enhanced drag and drop feel with improved visual feedback:
- **More Precise Positioning** - Improved accuracy when dropping tasks:
- **Better Scroll Behavior** - Enhanced dragging near column edges:
- **Prevented Premature DOM Updates** - Fixed jarring updates during drag operations:
- **Enhanced Touch Support** - Better mobile drag experience:
- **Position Index Bug Fix** - Resolved issue where tasks would return to wrong position:

## [1.13.0] - 2026-01-01

### Added

#### Enhanced New User Experience

- **Automatic Login After Registration** - New users are now automatically logged in after creating their account:
  - Eliminates the redundant step of requiring users to log in immediately after registration
  - Improved onboarding flow reduces friction for new users

- **AI Optimized Board Quick Start** - Added prominent call-to-action for new users without boards:
  - Displays helpful message: "You don't have any boards yet. Create your first board to get started!"
  - Large, centered "Create AI Optimized Board" button with orange gradient styling

### Changed

#### UI/UX Improvements

- **Enhanced Task Review Checkbox Visibility** - Made the "Needs Review" checkbox more obvious in task forms:
  - Changed from subtle gray label to prominent blue gradient styling
  - Added blue checkmark icon when enabled for better visual feedback
  - Increased text size and weight for better readability
  - Improved accessibility with clearer visual distinction

## [1.12.0] - 2025-12-29

### Added

#### Agent Onboarding Endpoint

- **GET /api/agent/onboarding** - Comprehensive onboarding endpoint for AI agents starting work with Stride:
  - **Critical first steps** - Immediate guidance on creating `.stride_auth.md` and `.stride.md` configuration files
  - **File templates** - Complete templates for both configuration files included in response
  - **Workflow overview** - Clear explanation of the Ready → Doing → Review → Done workflow
  - **Hook execution guide** - Complete documentation of all four hook points with environment variables
  - **API reference** - Full endpoint listing with categorization (discovery, management, creation)
  - **Documentation links** - Direct URLs to all agent-facing documentation guides
  - **Quick start guide** - Step-by-step instructions for getting started immediately
  - Returns all information needed for an agent to begin working without external documentation lookup

- **Comprehensive Agent Documentation** - Created complete documentation set for AI agents:
  - `AUTHENTICATION.md` - Bearer token authentication with `.stride_auth.md` format
  - `AGENT-CAPABILITIES.md` - Capability matching system with 12 standard capabilities
  - `AGENT-HOOK-EXECUTION-GUIDE.md` - Client-side hook execution with complete examples
  - `TASK-WRITING-GUIDE.md` - Task creation guide with structured JSON format rationale
  - `REVIEW-WORKFLOW.md` - Review workflow patterns and continuous work loop
  - `ESTIMATION-FEEDBACK.md` - Providing estimation feedback on task completion
  - `UNCLAIM-TASKS.md` - When and how to release tasks agents can't complete
  - `AI-WORKFLOW.md` - Complete agent workflow from authentication to task completion

### Changed

#### Homepage Redesign

- **Human-AI Collaboration Focus** - Completely redesigned the homepage to showcase Stride as a Human-AI collaboration platform:
  - **Hero section** - Updated badge to "Human-AI Collaboration Platform" and headline to emphasize AI agents working alongside humans
  - **Value proposition** - Rewritten to highlight workflow hooks, task delegation to AI, and human review control
  - **Feature cards** - Replaced generic kanban features with collaboration-focused features:
    - **AI Agent Integration** - REST API with capability matching and workflow hooks
    - **Automated Task Claiming** - Atomic claiming with optimistic locking and dependency handling
    - **Human Review Workflow** - Optional human review and approval process
    - **Client-Side Workflow Hooks** - Custom code execution at four key workflow moments

#### About Page Enhancement

- **Human-AI Collaboration Platform Section** - Added new section explaining Stride's collaborative features:
  - **Overview** - Describes how AI agents and humans work together through REST API and review workflows
  - **Five key features** - Capability matching, atomic task claiming, client-side hooks, human review, and API documentation
  - **Use case description** - Explains how teams delegate repetitive tasks to AI while humans focus on architecture and review

## [1.11.0] - 2025-12-28

### Added

#### Workflow Hooks System for AI Agent Integration

- **Client-Side Hook Execution Architecture** - Introduced a flexible hook system that enables AI agents to execute custom workflows at key points in the task lifecycle:
  - **Server provides hook metadata** - Server does NOT execute hooks; instead returns hook metadata (name, environment variables, timeout, blocking status) to the agent
  - **Agent executes locally** - Agents read `.stride.md` configuration file from their project root and execute hook commands on their local machine
  - **Language-agnostic** - Works with any programming language or environment (Elixir, Java, Python, etc.) since hooks run on agent's machine
  - **Four fixed hook points**:
    - `before_doing` - Executes before task is moved to Doing (blocking, 60s timeout)
    - `after_doing` - Executes after task completes to Review (blocking, 120s timeout)
    - `before_review` - Executes when task enters Review column (non-blocking, 60s timeout)
    - `after_review` - Executes after review approval/rejection (non-blocking, 60s timeout)

- **Hook Metadata System** - New `Kanban.Hooks` context provides hook information to agents:
  - **`get_hook_info/4`** - Returns hook metadata for a specific task and hook point
  - **`list_hooks/0`** - Returns all available hook configurations
  - **Environment variables** - Rich environment context provided for each hook:
    - Task metadata: `TASK_ID`, `TASK_IDENTIFIER`, `TASK_TITLE`, `TASK_DESCRIPTION`, `TASK_COMPLEXITY`, `TASK_PRIORITY`, `TASK_STATUS`, `TASK_NEEDS_REVIEW`
    - Board context: `BOARD_ID`, `BOARD_NAME`, `COLUMN_ID`, `COLUMN_NAME`
    - Agent context: `AGENT_NAME`, `HOOK_NAME`
  - **Timeout configuration** - Each hook has a configured timeout for safe execution
  - **Blocking behavior** - Hooks can be blocking (prevent action on failure) or non-blocking (log errors but continue)

- **API Integration** - Hook metadata returned in API responses:
  - **POST /api/tasks/claim** - Returns `before_doing` hook metadata along with claimed task
  - **PATCH /api/tasks/:id/complete** - Returns array of hook metadata: `[after_doing, before_review, after_review?]`
  - **PATCH /api/tasks/:id/mark_reviewed** - Returns `after_review` hook metadata
  - **Hook execution sequence** - Agents receive hooks in correct execution order for their workflow
  - **Conditional hook inclusion** - `after_review` hook included in complete response only when `needs_review=false`

- **Automatic Task Completion for No-Review Tasks** - Enhanced `complete_task/4` to handle tasks that don't require review:
  - When `needs_review=false`, task automatically moves from Review to Done after hook execution
  - Sets `status` to `:completed` and `completed_at` timestamp
  - Moves parent goal to Done column as well
  - Unblocks dependent tasks
  - Returns all three hooks (`after_doing`, `before_review`, `after_review`) for agent execution
  - Ensures proper workflow even when human review is skipped

## [1.10.1] - 2025-12-28

### Added

#### Bulk Task Creation with Nested Goals

- **POST /api/tasks with nested tasks** - Create a goal with multiple child tasks in a single atomic API call:
  - **Atomic transactions** - Uses `Ecto.Multi` to ensure all-or-nothing semantics (if any task fails, entire operation rolls back)
  - **Automatic parent_id assignment** - Child tasks automatically linked to parent goal
  - **Automatic identifier generation** - Goals get G prefix (G1, G2, etc.), tasks get W/D prefix based on type
  - **Position management** - Goal positioned first, child tasks positioned sequentially after
  - **Task history tracking** - Creation history entries created for goal and all child tasks
  - **PubSub broadcasting** - Real-time updates broadcast for goal and all children
  - **Telemetry events** - `[:kanban, :goal, :created_with_tasks]` event emitted with goal and task counts
  - **WIP limit enforcement** - Respects column WIP limits before creating goal
  - **Full field support** - Preserves all AI-optimized fields (complexity, verification_steps, key_files, etc.)
  - **Response format** - Returns `{goal: ..., child_tasks: [...]}` with complete task data

- **Request Format**:
  ```json
  POST /api/tasks
  {
    "title": "Implement search feature",
    "tasks": [
      {"title": "Add search schema", "type": "work", "complexity": "small"},
      {"title": "Build search UI", "type": "work", "complexity": "medium"},
      {"title": "Fix search bug", "type": "defect", "complexity": "small"}
    ]
  }
  ```

#### Automatic Goal Deletion

- **Smart goal cleanup** - Goals are automatically deleted when all their child tasks are removed:
  - **Cascade deletion** - When the last child task of a goal is deleted, the parent goal is automatically deleted as well
  - **Real-time updates** - Goal deletion broadcasts via PubSub for immediate UI updates
  - **Prevents orphaned goals** - Ensures goals without children don't remain on the board
  - **Proper reordering** - Tasks are reordered after goal deletion to maintain proper positioning

## [1.10.0] - 2025-12-28

### Added

#### Goal → Task Hierarchy System

- **2-Level Task Hierarchy** - Introduced goal-based task organization:
  - **Goals (G prefix)** - Large initiatives (25+ hours) that contain multiple related tasks
  - **Tasks (W/D prefix)** - Individual work items that can belong to a goal via `parent_id` field
  - Standalone tasks (no parent) remain fully supported

- **Goal Card UI** - Compact, visually distinct cards for goals:
  - **Yellow gradient styling** - `from-yellow-50 to-yellow-100` background with `border-yellow-300/60`
  - **Compact dimensions** - `min-h-[45px]` height with `p-1.5` padding (vs `p-3` for regular tasks)
  - **Reduced spacing** - `mt-1` between title and progress bar, `mt-1.5` between progress bar and badges
  - **Three-line layout**:
    - Line 1: Goal title (text-sm, leading-snug)
    - Line 2: Progress bar showing completion (e.g., "6/11")
    - Line 3: Badge row (G badge, priority, identifier)
  - **Non-draggable** - No drag handle displayed (goals move automatically)
  - **Type badge** - Yellow "G" badge with gradient background matching card style

- **Automatic Goal Movement** - Goals reposition based on child task status:
  - **Smart column detection** - When ALL child tasks are in same column, goal moves to that column
  - **Before-child positioning** - Goal positions BEFORE first child in target column
  - **Done column special handling** - Goal positions at END when all children complete
  - **Real-time updates** - Movement triggers immediately when last child task moves
  - **Position shifting** - Other tasks shift to maintain proper ordering

- **Goal Progress Tracking** - Real-time progress calculation and display:
  - **Progress bar** - Green gradient bar (`from-green-500 to-emerald-500`) on yellow background
  - **Completion count** - Shows "completed/total" (e.g., "6/11") next to progress bar
  - **Percentage calculation** - Computed via `calculate_goal_progress/1` helper
  - **PubSub updates** - Progress updates broadcast in real-time as child tasks complete
  - **Status tracking** - Counts completed vs total children for accurate progress

- **Parent Goal Selection** - Tasks can be assigned to goals during creation/edit:
  - **Goal dropdown** - New "Parent Goal" field in task form
  - **Goal options** - Shows all goals in format "G1 - Goal Title"
  - **Filtered by board** - Only shows goals from current board
  - **Self-exclusion** - Goals cannot be their own parent (prevents circular references)
  - **Ordered display** - Goals sorted by identifier (G1, G2, G3, etc.)

#### Hierarchical Task Tree API Endpoint

- **GET /api/tasks/:id/tree** - Returns nested JSON structure showing task hierarchy:
  - **For goals**: Returns goal data + array of child tasks + progress counts
  - **For tasks**: Returns just the task data (no children)
  - **Full field support** - Includes all rich task fields (complexity, dependencies, etc.)
  - **Progress statistics** - Includes total children and completed count for goals
  - **Ordered children** - Child tasks ordered by position ascending
  - **Scope enforcement** - Respects tasks:read scope, returns 401/404 appropriately
  - **Supports identifiers** - Accepts both numeric IDs and identifiers (e.g., "G1", "W14")

## [1.9.0] - 2025-12-27

### Added

#### Intelligent Review Workflow with mark_reviewed Endpoint

- **Smart Review Processing** - New `mark_reviewed` endpoint that intelligently routes tasks based on review status:
  - **PATCH /api/tasks/:id/mark_reviewed** - Process reviewed tasks with automatic routing
  - If `review_status == "approved"`: Moves task from Review to Done column, sets status to `:completed`
  - If `review_status in ["changes_requested", "rejected"]`: Moves task back to Doing column, keeps status as `:in_progress`
  - Returns 422 error if task not in Review column or review_status not set
  - Supports both numeric IDs and human-readable identifiers (e.g., "W14")

- **Enhanced Review Workflow** - Improved human-AI collaboration on task review:
  - Human reviews task in Review column and sets `review_status` field
  - Human adds `review_notes` to guide AI on required changes
  - Human notifies AI that review is complete
  - AI calls `/mark_reviewed` to automatically route task based on review outcome
  - Eliminates need for polling - explicit notification-based workflow
  - Agent can read `review_notes` to understand what needs to be fixed

- **Telemetry and Observability** - Comprehensive tracking of review outcomes:
  - Emits `[:kanban, :task, :completed]` when task approved and moved to Done
  - Emits `[:kanban, :task, :returned_to_doing]` when task needs changes
  - Tracks review status in telemetry metadata
  - Logs reviewer information with `reviewed_by_id` field

- **Backwards Compatibility** - Preserved existing endpoints:
  - `mark_done` endpoint still available but marked as deprecated
  - Both endpoints coexist for gradual migration
  - New workflow recommended for all new integrations

#### AI Agent Metadata Tracking

- **Agent Tracking on Task Creation** - Tasks created via API now track the AI agent model:
  - Added `created_by_agent` field to store agent information in format `"ai_agent:model_name"`
  - Automatically populated when API token has `agent_model` configured
  - Visible indicator (purple CPU chip icon) on task cards for AI-created tasks
  - Helps track which tasks were created by AI agents vs. human users

- **Agent Tracking on Task Completion** - Tasks completed via API now track the AI agent model:
  - Added `completed_by_agent` field to store agent information in format `"ai_agent:model_name"`
  - Automatically populated when API token has `agent_model` configured during task completion
  - Provides audit trail of which AI agent completed specific tasks

- **UI Enhancements** - Visual indicators for AI-created tasks:
  - Purple gradient CPU chip icon displayed on task cards
  - Hover tooltip shows full agent identifier

- **API Token Schema Updates** - Enhanced API token model to support agent metadata:
  - `agent_model` field stores the model identifier (e.g., "claude-sonnet-4")
  - Used by `maybe_add_created_by_agent/2` and `maybe_add_completed_by_agent/2` helpers
  - Only adds metadata when `agent_model` is present on the token

## [1.8.0] - 2025-12-26

### Added

#### Task Dependencies and Blocking Logic

- **Dependency Graph System** - Tasks can now have dependencies on other tasks with full validation:
  - Tasks can specify dependencies using task identifiers (e.g., "W14", "W15")
  - Circular dependency detection prevents invalid dependency relationships
  - Automatic task status management based on dependency completion
  - Visual blocked indicator on task cards when dependencies are incomplete

- **Automatic Blocking/Unblocking** - Task status automatically updates based on dependencies:
  - When a task has incomplete dependencies, status changes to `:blocked`
  - When all dependencies are completed, task automatically unblocks
  - Blocking status checked on task creation, update, and dependency completion
  - Dependent tasks automatically unblocked when a task is marked done

- **Dependency API Endpoints** - New endpoints for querying task relationships:
  - **GET /api/tasks/:id/dependencies** - Returns full dependency tree for a task
  - **GET /api/tasks/:id/dependents** - Returns all tasks that depend on this task
  - Supports both numeric IDs and human-readable identifiers
  - Recursive dependency tree structure with nested dependencies

- **Validation and Safety** - Comprehensive validation to ensure data integrity:
  - Circular dependency detection using depth-first search with visited tracking
  - Prevention of task deletion when other tasks depend on it
  - Prevention of self-dependencies
  - PostgreSQL array operations for efficient dependency queries

- **UI Enhancements** - Visual indicators for blocked tasks:
  - Blocked icon displayed in upper right of task cards
  - Clear visual distinction for tasks that cannot be started
  - Real-time updates when blocking status changes

### Fixed

- **Review Status Update** - Fixed issue preventing review status updates on tasks:
  - Added automatic population of `reviewed_at` and `reviewed_by_id` when review status changes
  - Added missing `handle_info` handler for `:task_reviewed` PubSub events
  - Form component now properly receives user context for review metadata

## [1.7.0] - 2025-12-26

### Added

#### Task Completion API Endpoint

- **Task Completion Workflow** - AI agents can now complete tasks and move them to Review column:
  - **PATCH /api/tasks/:id/complete** - Complete a task by moving it from Doing to Review column with completion summary
  - Supports both numeric IDs and human-readable identifiers (e.g., "W16") for task completion
  - Status remains "in_progress" (final completion to Done column handled by separate endpoint)
  - Stores detailed completion metadata including:
    - `completion_summary` - JSON string with comprehensive completion details (files changed, verification results, implementation notes)
    - `actual_complexity` - Actual complexity experienced (small, medium, large)
    - `actual_files_changed` - String count of files modified during implementation
    - `time_spent_minutes` - Integer minutes spent on the task
    - `completed_by_id` - User ID of the completer

- **Completion Summary Structure** - Supports rich completion data in JSON format:
  - `files_changed` - Array of file paths and what changed in each
  - `tests_added` - Array of test files created
  - `verification_results` - Commands run, status (passed/failed), and output
  - `implementation_notes` - Deviations, discoveries, and edge cases encountered
  - `estimation_feedback` - Comparison of estimated vs actual complexity, files, and time
  - `telemetry_added` - Array of telemetry events added
  - `follow_up_tasks` - Array of follow-up work identified
  - `known_limitations` - Array of limitations or constraints

#### Task Mark Done API Endpoint

- **Final Task Completion** - AI agents can now mark reviewed tasks as done and move them to Done column:
  - **PATCH /api/tasks/:id/mark_done** - Mark a task as done by moving it from Review to Done column
  - Supports both numeric IDs and human-readable identifiers (e.g., "W24") for marking done
  - Sets `status` to `:completed` and `completed_at` timestamp automatically
  - Only tasks in Review column can be marked as done (validation enforced)
  - Final step in the task workflow after review is complete
  - Broadcasts `{:task_completed, task}` PubSub event for real-time UI updates
  - Emits telemetry events: `[:kanban, :task, :completed]` and `[:kanban, :api, :task_marked_done]`
  - Returns 422 error if task is not in Review column
  - Returns 403 error if task belongs to different board

## [1.6.0] - 2025-12-25

### Added

#### Task Claiming API Endpoints

- **Intelligent Task Discovery & Claiming** - AI agents can now discover and claim tasks with advanced filtering:
  - **GET /api/tasks/next** - Retrieve the next available task from the Ready column matching agent capabilities
  - **POST /api/tasks/claim** - Atomically claim the next available task and move it to Doing column
  - **POST /api/tasks/:id/unclaim** - Release a claimed task back to Ready column with optional reason
  - Supports both numeric IDs and human-readable identifiers (e.g., "W14") for task unclaiming
  - Race condition prevention through atomic PostgreSQL operations ensuring tasks are never double-claimed

- **Capability-Based Task Filtering**:
  - Agents only see tasks matching their declared capabilities via `agent_capabilities` array on API tokens
  - Tasks can specify `required_capabilities` to restrict which agents can work on them
  - PostgreSQL array containment operations ensure efficient capability matching
  - Agents without specific capabilities see all tasks without requirements

- **Dependency-Aware Task Selection**:
  - Automatically skips tasks with incomplete dependencies
  - Uses PostgreSQL subqueries to verify all dependencies are completed before returning tasks
  - Ensures agents always receive tasks that are truly ready to be worked on
  - Prevents blocked tasks from being claimed

- **Key File Conflict Detection**:
  - Prevents concurrent work on the same files by different agents
  - Tasks with overlapping `key_files` are automatically excluded from next/claim operations
  - JSONB operations efficiently compare file paths across in-progress tasks
  - Reduces merge conflicts and ensures safe parallel work

- **Automatic Task State Management**:
  - Tasks claimed via `/api/tasks/claim` are automatically moved to Doing column
  - Sets `claimed_at`, `claim_expires_at` (24 hours), `assigned_to_id`, and `status` fields
  - Calculates correct position in Doing column to maintain sort order
  - Unclaimed tasks return to Ready column with all claim metadata cleared

- **Enhanced Telemetry**:
  - New telemetry events: `[:kanban, :api, :next_task_fetched]`, `[:kanban, :api, :task_claimed]`, `[:kanban, :api, :task_unclaimed]`
  - Tracks task priority, API token usage, and unclaim reasons
  - Provides insights into agent behavior and task workflow efficiency

## [1.5.0] - 2025-12-24

### Added

#### Task CRU API Endpoints

- **RESTful JSON API for Tasks** - AI agents can now programmatically create, read, and update tasks:
  - **POST /api/tasks** - Create tasks with all fields including nested associations (key_files, verification_steps)
  - **GET /api/tasks** - List all tasks for the authenticated board with optional column filtering
  - **GET /api/tasks/:id** - Retrieve a single task with all associations preloaded (supports both database IDs and human-readable identifiers like "W14")
  - **PATCH /api/tasks/:id** - Update task fields including nested associations (supports both database IDs and identifiers)
  - Board-scoped access control - tokens can only access tasks from their associated board
  - Automatic default column selection (Backlog > Ready > first column) when column_id not specified
  - Full field support for all 60+ task fields including metadata, observability, and AI context fields
  - Proper HTTP status codes (201 for create, 200 for update, 422 for validation errors, 403 for forbidden, 401 for unauthorized)
  - **Flexible Task Identification** - API endpoints accept both numeric database IDs (e.g., "73") and human-readable identifiers (e.g., "W14") for improved developer experience

- **Real-Time Integration**:
  - All API mutations automatically broadcast via Phoenix PubSub
  - LiveView clients receive instant updates when tasks are created or modified via API
  - Seamless integration between UI and API workflows

- **Telemetry & Observability**:
  - Emits telemetry events for all API operations (`[:kanban, :api, :task_created]`, `[:kanban, :api, :task_updated]`, `[:kanban, :api, :task_listed]`)
  - Tracks API usage including board_id, user_id, request path, and HTTP method
  - Provides metrics for monitoring API performance and usage patterns

## [1.4.0] - 2025-12-24

### Added

#### API Token Authentication for AI Agents

- **Bearer Token Authentication** - Enable AI agents and automation tools to interact with your boards programmatically:
  - Generate API tokens for AI Optimized Boards from the board's API Tokens page
  - Simple Bearer token authentication via HTTP headers
  - Each token is scoped to a specific board for security
  - One-time token display after creation with easy copy-to-clipboard functionality
  - Token name and optional metadata tracking (AI model, version, purpose)

- **Secure Token Management**:
  - Tokens are cryptographically hashed (SHA-256) before storage
  - Never stored in plaintext - shown only once at creation
  - Easy token revocation without affecting your login session
  - Usage tracking shows when each token was last used
  - Create multiple tokens for different AI agents or purposes

- **AI Optimized Board Integration**:
  - API Tokens feature available exclusively for AI Optimized Boards
  - Provides AI agents with programmatic access to the standardized 5-column workflow
  - Perfect for Claude Code, MCP servers, and other automation tools
  - Works with any HTTP client or programming language

### Changed

- API Tokens button now only appears on AI Optimized Boards

## [1.3.0] - 2025-12-23

### Added

#### AI Context Fields for Enhanced Task Intelligence

- **Three New Task Fields** - Added specialized fields to capture AI-relevant context for task execution:

  - **Security Considerations** (`security_considerations`):
    - Array field for documenting security-related requirements and notes
    - Examples: token hashing requirements, validation rules, security headers
    - Purple background color in UI for high visibility
    - Dynamic add/remove interface in task forms
    - Defaults to empty array when not provided

  - **Testing Strategy** (`testing_strategy`):
    - Map field with three standardized categories: `unit_tests`, `integration_tests`, `manual_tests`
    - Each category contains an array of test descriptions
    - Cyan background color in UI to distinguish from security considerations
    - Dynamic add/remove interface with category-specific sections
    - Defaults to empty map when not provided

  - **Integration Points** (`integration_points`):
    - Map field with four standardized categories:
      - `telemetry_events`: Phoenix telemetry events to emit
      - `pubsub_broadcasts`: PubSub topics to broadcast to
      - `phoenix_channels`: Phoenix channels to update
      - `external_apis`: External API integrations
    - Each category contains an array of integration descriptions
    - Indigo background color in UI to distinguish from other AI fields
    - Dynamic add/remove interface with category-specific sections
    - Defaults to empty map when not provided

## [1.2.0] - 2025-12-22

### Added

#### AI Optimized Boards

- **New Board Type** - Introduced AI Optimized Boards with predefined, immutable structure:
  - Automatically creates 5 standard columns: Backlog, Ready, Doing, Review, Done
  - Columns are locked and cannot be added, edited, deleted, or reordered
  - Designed for AI-driven workflows with consistent, predictable structure
  - Board owners retain full control over tasks, but column structure is fixed
  - Clear visual distinction from regular boards throughout the interface

## [1.1.0] - 2025-12-22

### Added

#### Rich Task Metadata System

- **Extended Task Schema** - Added 18+ new fields to support AI-optimized task management:
  - **Planning & Context**: complexity (small/medium/large), estimated_files, why, what, where_context
  - **Implementation Guidance**: patterns_to_follow, database_changes, validation_rules, required_capabilities
  - **Observability**: telemetry_event, metrics_to_track, logging_requirements
  - **Error Handling**: error_user_message, error_on_failure
  - **Collections**: key_files (JSONB), verification_steps (JSONB), technology_requirements (JSONB), pitfalls (JSONB), out_of_scope (JSONB)
  - **Metadata Tracking**: created_by, creator_name, completed_at, completed_by, completer_name, completion_summary
  - **Assignment Tracking**: claimed_at, claimed_by, claimer_name
  - **Review System**: needs_review (boolean), review_status (pending/approved/changes_requested), review_notes
  - **Dependencies**: dependencies (JSONB array) to track task relationships

#### Board-Level Field Visibility System

- **Field Visibility Toggles** - Board owners can control which task fields are visible to all users:
  - 12 toggleable fields: acceptance_criteria, complexity, context, key_files, verification_steps, technical_notes, observability, error_handling, technology_requirements, pitfalls, out_of_scope, required_capabilities
  - Stored in boards table as JSONB (field_visibility column)
  - Real-time PubSub broadcasts synchronize visibility changes across all connected clients
  - Owner-only access control - only board owners can modify field visibility settings
  - Default visibility: acceptance_criteria shown, all others hidden
  - Settings persist in database and apply to all users viewing the board

#### Enhanced Task Forms

- **Comprehensive Task Creation/Edit Form** - Support for all rich task fields with dynamic sections:
  - Dynamic key files editor with add/remove functionality
  - Dynamic verification steps editor with add/remove functionality
  - Embedded schema support for structured JSONB data
  - Validation for all new fields with proper error handling
  - Field visibility awareness - form fields show/hide based on board settings
  - Reduced code complexity (Credo compliant) through helper function extraction

#### Task Detail View Enhancements

- **Rich Task Display** - All 18 TASK.md categories displayed in organized, scannable format:
  - Planning context (Why/What/Where)
  - Implementation guidance section
  - Key files to read (with file paths and descriptions)
  - Verification steps checklist
  - Observability requirements
  - Error handling guidelines
  - Technology requirements
  - Known pitfalls
  - Out of scope clarifications
  - Dependencies visualization
  - Review status indicators
  - Assignment and completion tracking

### Technical Improvements

- **Real-Time Collaboration**:
  - PubSub broadcasts for field visibility changes
  - Instant synchronization of board settings across all connected clients

### Developer Experience

- **AI-Optimized Task Structure** - Tasks now contain comprehensive information for AI agents to:
  - Understand context and rationale (why/what/where)
  - Follow project patterns and conventions
  - Locate relevant code files
  - Verify implementation success
  - Handle errors appropriately
  - Track dependencies and review status

- **Flexible Board Configuration** - Teams can customize their workflow by:
  - Showing only relevant fields for their process
  - Reducing information overload on task cards
  - Maintaining consistent views across all team members
  - Adjusting visibility as workflow needs evolve

## [1.0.1] - 2025-12-21

### Fixed

- Updated all UI components to use theme-aware daisyUI color tokens for proper dark mode support
- Replaced hardcoded Tailwind gray colors with daisyUI semantic colors (base-100, base-200, base-300, base-content)
- Fixed text visibility issues in dark mode across all pages including:
  - Board list, show, and form views
  - Task view and form components
  - Column form component
  - Home, About, Changelog, and Tango pages
  - Authentication pages
  - Error pages (404, 500)
- Updated test expectations to match new dark mode compatible CSS classes
- All components now properly adapt to both light and dark themes using OKLCH color space

## [1.0.0] - 2025-12-15

### Core Features

#### User Authentication & Management

- User registration with email and password
- Secure user login and logout with session management
- Password hashing and security using bcrypt
- Protected routes requiring authentication
- User profiles with customizable display names
- Multi-language support with language switcher (English and French)

#### Board Management

- Create, view, edit, and delete kanban boards
- Each board has a name and description
- Board-level access control with three permission levels:
  - **Owner**: Full control over board, columns, and tasks
  - **Modify**: Can edit and move tasks, but cannot modify board structure
  - **Read-only**: Can only view the board
- Share boards with other users with granular permissions
- Beautiful board cards with responsive design
- Board listing with quick access to all user boards

#### Column Management

- Create, edit, and delete columns within boards
- Drag-and-drop column reordering
- Configurable Work-In-Progress (WIP) limits per column:
  - Set to 0 for unlimited tasks
  - Set to positive integer to enforce maximum tasks
  - Visual indicators when approaching or exceeding WIP limits
  - Prevents task creation/movement when limit is reached
- Visual task count display (e.g., "3/5" when limit is 5)
- Column deletion with cascade (removes all tasks in column)

#### Task Management

- Create, edit, and delete tasks within columns
- Rich task properties:
  - **Title**: Required task name
  - **Description**: Optional detailed description
  - **Acceptance Criteria**: Optional criteria for task completion
  - **Type**: Work or Defect
  - **Priority**: Low, Medium, High, or Critical
  - **Assigned To**: Assign tasks to specific users
  - **Identifier**: Auto-generated unique identifier (e.g., W1, W2, D1)
- Drag-and-drop task movement:
  - Move tasks within the same column (reorder)
  - Move tasks between columns
  - Respects WIP limits when moving
  - Visual feedback during drag operations
- Task comments:
  - Add comments to tasks for collaboration
  - Timestamp and display for all comments
  - View comment history
- Task history tracking:
  - Automatic tracking of task lifecycle events
  - Track creation, moves between columns, priority changes, and assignments
  - Display full history with timestamps
  - Visual icons for different event types

#### Real-Time Collaboration

- Phoenix PubSub integration for real-time updates
- Live synchronization across all connected browsers:
  - Task creation, updates, and deletion
  - Task movement between columns
  - Automatic board refresh when changes occur
- Multiple users can view and interact with the same board simultaneously

#### User Experience

- Modern, responsive design using TailwindCSS
- Smooth animations and transitions
- Drag-and-drop interfaces for intuitive task management
- Loading states for asynchronous operations
- Flash messages for user feedback
- Confirmation dialogs for destructive actions
- Empty states with helpful guidance
- Accessibility improvements throughout the application
- Mobile-responsive layout

#### Error Tracking & Monitoring

- Built-in error tracking with ErrorTracker
- Error dashboard for administrators
- Automatic error capture and reporting
- Stack trace and context information for debugging

#### Internationalization

- Full Gettext integration
- English translations (default)
- French translations
- Spanish translations
- German translations
- Portugese translations
- Japanese translations
- Mandarin Chinese translations
- Easy addition of new languages
- Context-aware translations

### Release Notes

This is the initial stable release of the Kanban Board application. All core features have been implemented, tested, and documented. The application is production-ready with comprehensive test coverage, security measures, and a polished user interface.

### Known Limitations

None identified. Please report any issues via the project's issue tracker. A form is available on the About page for easy submission.

### Credits

This application was completely Vibecoded by Jeff "Cheezy" Morgan with the help of Claude Code and TideWave.
