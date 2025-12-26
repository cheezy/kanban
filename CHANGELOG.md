# Changelog

All notable changes to the Kanban Board application will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
