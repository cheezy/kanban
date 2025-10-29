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

```
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

- [ ] **Generate Column schema and migration**
  - [ ] Create migration: `mix ecto.gen.migration create_columns`
  - [ ] Define `columns` table with fields: name (string), position (integer), wip_limit (integer, default: 0, not null), board_id (references :boards)
  - [ ] Add foreign key constraint with `on_delete: :delete_all`
  - [ ] Add index on board_id
  - [ ] Add unique constraint on (board_id, position)
  - [ ] Add check constraint to ensure wip_limit >= 0 (no negative values)
  - [ ] Run migration: `mix ecto.migrate`
- [ ] **Create Column schema**
  - [ ] Create `lib/kanban/columns/column.ex` with Ecto schema
  - [ ] Define fields: `:name`, `:position`, `:wip_limit`
  - [ ] Add `belongs_to :board, Kanban.Boards.Board`
  - [ ] Create changeset function with validations:
    - [ ] Validate wip_limit is >= 0 (no negative values)
    - [ ] Validate wip_limit is an integer
- [ ] **Update Board schema**
  - [ ] Add `has_many :columns, Kanban.Columns.Column` to Board schema
- [ ] **Create Columns context**
  - [ ] Create `lib/kanban/columns.ex` context with:
    - [ ] `list_columns(board)` - list columns for a board
    - [ ] `get_column!(id)` - get column by id
    - [ ] `create_column(board, attrs)` - create column with auto position
    - [ ] `update_column(column, attrs)` - update column
    - [ ] `delete_column(column)` - delete column and reorder remaining
    - [ ] `reorder_columns(board, column_ids)` - reorder columns
- [ ] **Write Column context tests**
  - [ ] Create `test/kanban/columns_test.exs`:
    - [ ] Test all CRUD operations
    - [ ] Test automatic position assignment
    - [ ] Test position reordering
    - [ ] Test WIP limit validation (must be >= 0)
    - [ ] Test WIP limit default value (0 = no limit)
- [ ] **Update board show LiveView for columns**
  - [ ] Update `lib/kanban_web/live/board_live/show.ex`
  - [ ] Load board with preloaded columns
  - [ ] Display columns in order by position
  - [ ] Show column name and task count placeholder
  - [ ] Display WIP limit indicator (e.g., "3/5" when limit is 5 and 3 tasks exist, or "3" when no limit)
  - [ ] Add visual warning when column is at or over WIP limit
  - [ ] Add "New Column" button
- [ ] **Create column form component**
  - [ ] Create `lib/kanban_web/live/column_live/form_component.ex`
  - [ ] Build form for creating/editing columns
  - [ ] Add WIP limit input field with validation (must be >= 0)
  - [ ] Add helpful text explaining WIP limit (0 = no limit)
  - [ ] Handle form submission
- [ ] **Add column actions**
  - [ ] Add edit column name inline or via modal
  - [ ] Add delete column with confirmation
- [ ] **Write Column LiveView tests**
  - [ ] Test column creation with WIP limit
  - [ ] Test column editing (including WIP limit changes)
  - [ ] Test column deletion
  - [ ] Test column ordering
  - [ ] Test WIP limit display and warnings
  - [ ] Test that negative WIP limits are rejected
- [ ] **Quality Checks (Phase 4)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues
  - [ ] Run `mix sobelow --config` and fix any security issues

#### Phase 5: Task Management (Schema, Context & UI)

- [ ] **Generate Task schema and migration**
  - [ ] Create migration: `mix ecto.gen.migration create_tasks`
  - [ ] Define `tasks` table with fields: title (string), description (text), position (integer), column_id (references :columns)
  - [ ] Add foreign key constraint with `on_delete: :delete_all`
  - [ ] Add index on column_id
  - [ ] Add unique constraint on (column_id, position)
  - [ ] Run migration: `mix ecto.migrate`
- [ ] **Create Task schema**
  - [ ] Create `lib/kanban/tasks/task.ex` with Ecto schema
  - [ ] Define fields: `:title`, `:description`, `:position`
  - [ ] Add `belongs_to :column, Kanban.Columns.Column`
  - [ ] Create changeset function with validations
- [ ] **Update Column schema**
  - [ ] Add `has_many :tasks, Kanban.Tasks.Task` to Column schema
- [ ] **Create Tasks context**
  - [ ] Create `lib/kanban/tasks.ex` context with:
    - [ ] `list_tasks(column)` - list tasks for a column
    - [ ] `get_task!(id)` - get task by id
    - [ ] `create_task(column, attrs)` - create task with auto position (check WIP limit)
    - [ ] `update_task(task, attrs)` - update task
    - [ ] `delete_task(task)` - delete task and reorder remaining
    - [ ] `move_task(task, new_column, new_position)` - move task to different column (check target column WIP limit)
    - [ ] `reorder_tasks(column, task_ids)` - reorder tasks within column
    - [ ] `can_add_task?(column)` - helper to check if column has room (respects WIP limit)
- [ ] **Write Task context tests**
  - [ ] Create `test/kanban/tasks_test.exs`:
    - [ ] Test all CRUD operations
    - [ ] Test automatic position assignment
    - [ ] Test moving tasks between columns
    - [ ] Test position reordering within column
    - [ ] Test position updates when task deleted
    - [ ] Test WIP limit enforcement when creating tasks
    - [ ] Test WIP limit enforcement when moving tasks to a column
    - [ ] Test that WIP limit of 0 allows unlimited tasks
    - [ ] Test error handling when WIP limit is reached
- [ ] **Update board show LiveView for tasks**
  - [ ] Update `lib/kanban_web/live/board_live/show.ex`
  - [ ] Load board with preloaded columns and tasks
  - [ ] Use streams to display tasks within each column
  - [ ] Show task title and description
  - [ ] Display in order by position
- [ ] **Create task form component**
  - [ ] Create `lib/kanban_web/live/task_live/form_component.ex`
  - [ ] Build form for creating/editing tasks
  - [ ] Handle form submission
- [ ] **Add task actions**
  - [ ] Add "New Task" button in each column (disable when WIP limit reached)
  - [ ] Show informative message when WIP limit prevents task creation
  - [ ] Add edit task button
  - [ ] Add delete task with confirmation
- [ ] **Write Task LiveView tests**
  - [ ] Test task creation
  - [ ] Test task creation blocked when WIP limit reached
  - [ ] Test task editing
  - [ ] Test task deletion
  - [ ] Test task display in correct column
  - [ ] Test "New Task" button disabled state when at WIP limit
- [ ] **Quality Checks (Phase 5)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues
  - [ ] Run `mix sobelow --config` and fix any security issues

#### Phase 6: Drag & Drop Functionality

- [ ] **Install drag-and-drop library**
  - [ ] Add Sortable.js or use native HTML5 drag-and-drop
  - [ ] Configure in `assets/js/app.js`
- [ ] **Create LiveView hooks for drag-and-drop**
  - [ ] Create hook in `assets/js/hooks.js`
  - [ ] Handle drag start, drag over, and drop events
  - [ ] Send events to LiveView
- [ ] **Implement server-side move handlers**
  - [ ] Add `handle_event("move_task", ...)` to board show LiveView
  - [ ] Call `Tasks.move_task/3` context function (respects WIP limit)
  - [ ] Handle WIP limit errors and display appropriate message to user
  - [ ] Update UI with new task positions
- [ ] **Add visual feedback**
  - [ ] Add drag handle to tasks
  - [ ] Show placeholder when dragging
  - [ ] Highlight drop zones
  - [ ] Visually indicate when a column cannot accept more tasks due to WIP limit
  - [ ] Show warning indicator when attempting to drag to a full column
- [ ] **Write LiveView tests**
  - [ ] Test moving task within same column
  - [ ] Test moving task to different column
  - [ ] Test position updates after move
  - [ ] Test that drag-and-drop respects WIP limits
  - [ ] Test error handling when attempting to move task to full column
- [ ] **Quality Checks (Phase 6)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues

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
