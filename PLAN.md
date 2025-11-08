# Kanban Board Application - Implementation Plan

## Project Overview

A web-based Kanban board application built with Phoenix/Elixir that allows users to create boards, manage columns, and organize tasks with authentication.

## Core Features

### 1. User Authentication

- [ ] User registration
- [ ] User login/logout
- [ ] Password hashing and security
- [ ] Session management
- [ ] Protected routes

### 2. Board Management

- [ ] Create new boards
- [ ] View list of user's boards
- [ ] View individual board
- [ ] Update board details (name, description)
- [ ] Delete boards

### 3. Column Management

- [ ] Add columns to a board
- [ ] Name/rename columns
- [ ] Reorder columns
- [ ] Delete columns

### 4. Task Management

- [ ] Create tasks within columns
- [ ] Edit task details (title, description)
- [ ] Delete tasks
- [ ] Move tasks between columns
- [ ] Reorder tasks within a column

## Technical Architecture

### Database Schema

```text
users
  - id
  - email
  - hashed_password
  - inserted_at
  - updated_at

boards
  - id
  - user_id (foreign key)
  - name
  - description
  - inserted_at
  - updated_at

columns
  - id
  - board_id (foreign key)
  - name
  - position (order)
  - wip_limit (integer, default: 0, not null)
  - inserted_at
  - updated_at

  Note: wip_limit of 0 means no limit, values > 0 enforce max tasks in column

tasks
  - id
  - column_id (foreign key)
  - title
  - description
  - position (order)
  - inserted_at
  - updated_at
```

### Implementation Phases

#### Phase 1: Project Setup & Authentication

- [X] Set up Phoenix project structure
- [X] Configure database
- [X] Implement user authentication
  - [X] Generate authentication scaffold with `mix phx.gen.auth Accounts User users`
  - [X] Run migrations with `mix ecto.migrate`
  - [X] Test user registration flow manually
  - [X] Test user login/logout flow manually
  - [X] Verify protected routes work correctly
- [X] **Quality Checks (Phase 1)**:
  - [X] Run `mix test` and ensure all tests pass
  - [X] Run `mix credo --strict` and fix any issues
  - [X] Run `mix sobelow --config` and fix any security issues

#### Phase 2: UI Polish & Internationalization

- [X] **Clean up default Phoenix UI**
  - [X] Remove Phoenix framework links from layout
  - [X] Customize header/navigation
  - [X] Apply consistent styling with TailwindCSS
  - [X] Create a custom home page design
- [X] **Add internationalization (i18n) support**
  - [X] Install and configure Gettext for multi-language support
  - [X] Extract all user-facing strings to translation files
  - [X] Add English translations (default)
  - [X] Add French translations
  - [X] Add language switcher component
  - [X] Test language switching functionality
- [X] **Quality Checks (Phase 2 - UI Polish)**:
  - [X] Run `mix test` and ensure all tests pass
  - [X] Run `mix credo --strict` and fix any issues
  - [X] Run `mix sobelow --config` and fix any security issues

#### Phase 3: Board Management (Schema, Context & UI)

- [X] **Generate Board schema and migration**
  - [X] Create migration: `mix ecto.gen.migration create_boards`
  - [X] Define `boards` table with fields: name (string), description (text), user_id (references :users)
  - [X] Add foreign key constraint with `on_delete: :delete_all`
  - [X] Add index on user_id
  - [X] Run migration: `mix ecto.migrate`
- [X] **Create Board schema**
  - [X] Create `lib/kanban/boards/board.ex` with Ecto schema
  - [X] Define fields: `:name`, `:description`
  - [X] Add `belongs_to :user, Kanban.Accounts.User`
  - [X] Create changeset function with validations
- [X] **Create Boards context**
  - [X] Create `lib/kanban/boards.ex` context with:
    - [X] `list_boards(user)` - list all boards for a user
    - [X] `get_board!(id, user)` - get board with authorization check
    - [X] `create_board(user, attrs)` - create board for user
    - [X] `update_board(board, attrs)` - update board
    - [X] `delete_board(board)` - delete board
- [X] **Write Board context tests**
  - [X] Create `test/kanban/boards_test.exs`:
    - [X] Test all CRUD operations
    - [X] Test user scoping (users can't access other users' boards)
    - [X] Test validations
- [X] **Create board list LiveView**
  - [X] Create `lib/kanban_web/live/board_live/index.ex`
  - [X] Implement `mount/3` to load user's boards
  - [X] Use streams for board collection
  - [X] Create template with board cards
  - [X] Add "New Board" button
  - [X] Add edit/delete actions for each board
- [X] **Create board show LiveView**
  - [X] Create `lib/kanban_web/live/board_live/show.ex`
  - [X] Load board with authorization check
  - [X] Display board name and description
  - [X] Prepare structure for columns (empty state for now)
- [X] **Create board form LiveView**
  - [X] Create `lib/kanban_web/live/board_live/form.ex`
  - [X] Build form for creating/editing boards
  - [X] Add validation and error display
  - [X] Handle form submission
- [X] **Add routes**
  - [X] Add routes in `lib/kanban_web/router.ex` under authenticated scope
  - [X] `live "/boards", BoardLive.Index, :index`
  - [X] `live "/boards/new", BoardLive.Form, :new`
  - [X] `live "/boards/:id/edit", BoardLive.Form, :edit`
  - [X] `live "/boards/:id", BoardLive.Show, :show`
- [X] **Write Board LiveView tests**
  - [X] Create `test/kanban_web/live/board_live_test.exs`
  - [X] Test board list rendering
  - [X] Test creating new board
  - [X] Test editing board
  - [X] Test deleting board
  - [X] Test authorization (can't access other users' boards)
- [X] **Quality Checks (Phase 3)**:
  - [X] Run `mix test` and ensure all tests pass
  - [X] Run `mix test --cover` and verify coverage meets threshold
  - [X] Run `mix credo --strict` and fix any issues
  - [X] Run `mix sobelow --config` and fix any security issues

#### Phase 4: Column Management (Schema, Context & UI)

- [X] **Generate Column schema and migration**
  - [X] Create migration: `mix ecto.gen.migration create_columns`
  - [X] Define `columns` table with fields: name (string), position (integer), wip_limit (integer, default: 0, not null), board_id (references :boards)
  - [X] Add foreign key constraint with `on_delete: :delete_all`
  - [X] Add index on board_id
  - [X] Add unique constraint on (board_id, position)
  - [X] Add check constraint to ensure wip_limit >= 0 (no negative values)
  - [X] Run migration: `mix ecto.migrate`
- [X] **Create Column schema**
  - [X] Create `lib/kanban/columns/column.ex` with Ecto schema
  - [X] Define fields: `:name`, `:position`, `:wip_limit`
  - [X] Add `belongs_to :board, Kanban.Boards.Board`
  - [X] Create changeset function with validations:
    - [X] Validate wip_limit is >= 0 (no negative values)
    - [X] Validate wip_limit is an integer
- [X] **Update Board schema**
  - [X] Add `has_many :columns, Kanban.Columns.Column` to Board schema
- [X] **Create Columns context**
  - [X] Create `lib/kanban/columns.ex` context with:
    - [X] `list_columns(board)` - list columns for a board
    - [X] `get_column!(id)` - get column by id
    - [X] `create_column(board, attrs)` - create column with auto position
    - [X] `update_column(column, attrs)` - update column
    - [X] `delete_column(column)` - delete column and reorder remaining
    - [X] `reorder_columns(board, column_ids)` - reorder columns
- [X] **Write Column context tests**
  - [X] Create `test/kanban/columns_test.exs`:
    - [X] Test all CRUD operations
    - [X] Test automatic position assignment
    - [X] Test position reordering
    - [X] Test WIP limit validation (must be >= 0)
    - [X] Test WIP limit default value (0 = no limit)
- [X] **Update board show LiveView for columns**
  - [X] Update `lib/kanban_web/live/board_live/show.ex`
  - [X] Load board with preloaded columns
  - [X] Display columns in order by position
  - [X] Show column name and task count placeholder
  - [X] Display WIP limit indicator (e.g., "3/5" when limit is 5 and 3 tasks exist, or "3" when no limit)
  - [X] Add visual warning when column is at or over WIP limit
  - [X] Add "New Column" button
- [X] **Create column form component**
  - [X] Create `lib/kanban_web/live/column_live/form_component.ex`
  - [X] Build form for creating/editing columns
  - [X] Add WIP limit input field with validation (must be >= 0)
  - [X] Add helpful text explaining WIP limit (0 = no limit)
  - [X] Handle form submission
- [X] **Add column actions**
  - [X] Add edit column name inline or via modal
  - [X] Add delete column with confirmation
- [X] **Write Column LiveView tests**
  - [X] Test column creation with WIP limit
  - [X] Test column editing (including WIP limit changes)
  - [X] Test column deletion
  - [X] Test column ordering
  - [X] Test WIP limit display and warnings
  - [X] Test that negative WIP limits are rejected
- [X] **Quality Checks (Phase 4)**:
  - [X] Run `mix test` and ensure all tests pass (172 tests, 0 failures)
  - [X] Run `mix test --cover` and verify coverage meets threshold
  - [X] Run `mix credo --strict` and fix any issues (no issues found)
  - [X] Run `mix sobelow --config` and fix any security issues (no issues found)

#### Phase 5: Task Management (Schema, Context & UI)

- [X] **Generate Task schema and migration**
  - [X] Create migration: `mix ecto.gen.migration create_tasks`
  - [X] Define `tasks` table with fields: title (string), description (text), position (integer), column_id (references :columns)
  - [X] Add foreign key constraint with `on_delete: :delete_all`
  - [X] Add index on column_id
  - [X] Add unique constraint on (column_id, position)
  - [X] Run migration: `mix ecto.migrate`
- [X] **Create Task schema**
  - [X] Create `lib/kanban/tasks/task.ex` with Ecto schema
  - [X] Define fields: `:title`, `:description`, `:position`
  - [X] Add `belongs_to :column, Kanban.Columns.Column`
  - [X] Create changeset function with validations
- [X] **Update Column schema**
  - [X] Add `has_many :tasks, Kanban.Tasks.Task` to Column schema
- [X] **Create Tasks context**
  - [X] Create `lib/kanban/tasks.ex` context with:
    - [X] `list_tasks(column)` - list tasks for a column
    - [X] `get_task!(id)` - get task by id
    - [X] `create_task(column, attrs)` - create task with auto position (check WIP limit)
    - [X] `update_task(task, attrs)` - update task
    - [X] `delete_task(task)` - delete task and reorder remaining
    - [X] `move_task(task, new_column, new_position)` - move task to different column (check target column WIP limit)
    - [X] `reorder_tasks(column, task_ids)` - reorder tasks within column
    - [X] `can_add_task?(column)` - helper to check if column has room (respects WIP limit)
- [X] **Write Task context tests**
  - [X] Create `test/kanban/tasks_test.exs`:
    - [X] Test all CRUD operations
    - [X] Test automatic position assignment
    - [X] Test moving tasks between columns
    - [X] Test position reordering within column
    - [X] Test position updates when task deleted
    - [X] Test WIP limit enforcement when creating tasks
    - [X] Test WIP limit enforcement when moving tasks to a column
    - [X] Test that WIP limit of 0 allows unlimited tasks
    - [X] Test error handling when WIP limit is reached
- [X] **Update board show LiveView for tasks**
  - [X] Update `lib/kanban_web/live/board_live/show.ex`
  - [X] Load board with preloaded columns and tasks
  - [X] Use streams to display tasks within each column
  - [X] Show task title and description
  - [X] Display in order by position
- [X] **Create task form component**
  - [X] Create `lib/kanban_web/live/task_live/form_component.ex`
  - [X] Build form for creating/editing tasks
  - [X] Handle form submission
- [X] **Add task actions**
  - [X] Add "New Task" button in each column (disable when WIP limit reached)
  - [X] Show informative message when WIP limit prevents task creation
  - [X] Add edit task button
  - [X] Add delete task with confirmation
- [X] **Write Task LiveView tests**
  - [X] Test task creation
  - [X] Test task creation blocked when WIP limit reached
  - [X] Test task editing
  - [X] Test task deletion
  - [X] Test task display in correct column
  - [X] Test "New Task" button disabled state when at WIP limit
- [X] **Quality Checks (Phase 5)**:
  - [X] Run `mix test` and ensure all tests pass (215 tests, 0 failures)
  - [X] Run `mix test --cover` and verify coverage meets threshold (94.68% coverage)
  - [X] Run `mix credo --strict` and fix any issues (no issues found)
  - [X] Run `mix sobelow --config` and fix any security issues (no issues found)

#### Phase 6: Drag & Drop Functionality

- [X] **Install drag-and-drop library**
  - [X] Add Sortable.js or use native HTML5 drag-and-drop
  - [X] Configure in `assets/js/app.js`
- [X] **Create LiveView hooks for drag-and-drop**
  - [X] Create hook in `assets/js/hooks/sortable.js`
  - [X] Handle drag start, drag over, and drop events
  - [X] Send events to LiveView
- [X] **Implement server-side move handlers**
  - [X] Add `handle_event("move_task", ...)` to board show LiveView
  - [X] Call `Tasks.move_task/3` context function (respects WIP limit)
  - [X] Handle WIP limit errors and display appropriate message to user
  - [X] Update UI with new task positions
- [X] **Add visual feedback**
  - [X] Add drag handle to tasks
  - [X] Show placeholder when dragging
  - [X] Highlight drop zones
  - [X] Visually indicate when a column cannot accept more tasks due to WIP limit
  - [X] Show warning indicator when attempting to drag to a full column
- [X] **Write LiveView tests**
  - [X] Test moving task within same column
  - [X] Test moving task to different column
  - [X] Test position updates after move
  - [X] Test that drag-and-drop respects WIP limits
  - [X] Test error handling when attempting to move task to full column
- [X] **Quality Checks (Phase 6)**:
  - [X] Run `mix test` and ensure all tests pass (223 tests, 0 failures)
  - [X] Run `mix test --cover` and verify coverage meets threshold (94.67% coverage)
  - [X] Run `mix credo --strict` and fix any issues (no issues found)

#### Phase 7: Polish & Enhancement

- [ ] **UI/UX improvements**
  - [ ] Design beautiful board cards with Tailwind CSS
  - [ ] Add hover effects and transitions
  - [ ] Improve spacing and typography
  - [ ] Add loading states for async actions
  - [ ] Add empty states for boards without columns/tasks
- [ ] **Add notifications**
  - [ ] Use Phoenix LiveView flash messages for success/error
  - [ ] Style flash messages with Tailwind CSS
- [ ] **Add confirmation dialogs**
  - [ ] Add confirmation for board deletion
  - [ ] Add confirmation for column deletion (mention tasks will be deleted)
  - [ ] Add confirmation for task deletion
- [ ] **Error handling**
  - [ ] Add proper error messages for validation failures
  - [ ] Handle edge cases (deleting last column, etc.)
  - [ ] Add 404 pages for missing resources
- [ ] **Final Quality Checks**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues
  - [ ] Run `mix sobelow --config` and fix any security issues
  - [ ] Run `mix precommit` to run all checks together

## Technology Stack

- **Backend**: Phoenix Framework (Elixir)
- **Database**: PostgreSQL
- **Frontend**: Phoenix LiveView
- **Authentication**: Phoenix built-in authentication
- **Styling**: TailwindCSS (default with Phoenix)

## Current Status

- [x] Project initialized
- [ ] Ready to begin Phase 1

## Notes

- Focus on core functionality first
- Use LiveView for real-time updates
- Keep UI simple and intuitive
- Ensure proper authorization (users can only access their own boards)
- **WIP Limits**: Columns have a configurable Work In Progress (WIP) limit
  - WIP limit of 0 means unlimited tasks
  - WIP limit > 0 enforces a maximum number of tasks in the column
  - WIP limit must be >= 0 (cannot be negative)
  - UI should clearly indicate when a column is at or over its limit
  - Task creation and movement operations must respect WIP limits
