# Changelog

All notable changes to the Kanban Board application will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
