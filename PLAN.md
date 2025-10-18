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
  - inserted_at
  - updated_at

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

#### Phase 3: Database Schema & Context Setup

- [ ] **Generate Board schema and migration**
  - [ ] Create migration: `mix ecto.gen.migration create_boards`
  - [ ] Define `boards` table with fields: name (string), description (text), user_id (references :users)
  - [ ] Add foreign key constraint with `on_delete: :delete_all`
  - [ ] Add index on user_id
  - [ ] Run migration: `mix ecto.migrate`
- [ ] **Create Board schema**
  - [ ] Create `lib/kanban/boards/board.ex` with Ecto schema
  - [ ] Define fields: `:name`, `:description`
  - [ ] Add `belongs_to :user, Kanban.Accounts.User`
  - [ ] Add `has_many :columns, Kanban.Columns.Column`
  - [ ] Create changeset function with validations
- [ ] **Generate Column schema and migration**
  - [ ] Create migration: `mix ecto.gen.migration create_columns`
  - [ ] Define `columns` table with fields: name (string), position (integer), board_id (references :boards)
  - [ ] Add foreign key constraint with `on_delete: :delete_all`
  - [ ] Add index on board_id
  - [ ] Add unique constraint on (board_id, position)
  - [ ] Run migration: `mix ecto.migrate`
- [ ] **Create Column schema**
  - [ ] Create `lib/kanban/columns/column.ex` with Ecto schema
  - [ ] Define fields: `:name`, `:position`
  - [ ] Add `belongs_to :board, Kanban.Boards.Board`
  - [ ] Add `has_many :tasks, Kanban.Tasks.Task`
  - [ ] Create changeset function with validations
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
- [ ] **Create context modules with functions**
  - [ ] Create `lib/kanban/boards.ex` context with:
    - [ ] `list_boards(user)` - list all boards for a user
    - [ ] `get_board!(id, user)` - get board with authorization check
    - [ ] `create_board(user, attrs)` - create board for user
    - [ ] `update_board(board, attrs)` - update board
    - [ ] `delete_board(board)` - delete board
  - [ ] Create `lib/kanban/columns.ex` context with:
    - [ ] `list_columns(board)` - list columns for a board
    - [ ] `get_column!(id)` - get column by id
    - [ ] `create_column(board, attrs)` - create column with auto position
    - [ ] `update_column(column, attrs)` - update column
    - [ ] `delete_column(column)` - delete column and reorder remaining
    - [ ] `reorder_columns(board, column_ids)` - reorder columns
  - [ ] Create `lib/kanban/tasks.ex` context with:
    - [ ] `list_tasks(column)` - list tasks for a column
    - [ ] `get_task!(id)` - get task by id
    - [ ] `create_task(column, attrs)` - create task with auto position
    - [ ] `update_task(task, attrs)` - update task
    - [ ] `delete_task(task)` - delete task and reorder remaining
    - [ ] `move_task(task, new_column, new_position)` - move task to different column
    - [ ] `reorder_tasks(column, task_ids)` - reorder tasks within column
- [ ] **Write comprehensive unit tests**
  - [ ] Create `test/kanban/boards_test.exs`:
    - [ ] Test all CRUD operations
    - [ ] Test user scoping (users can't access other users' boards)
    - [ ] Test cascade deletion (deleting board deletes columns and tasks)
  - [ ] Create `test/kanban/columns_test.exs`:
    - [ ] Test all CRUD operations
    - [ ] Test automatic position assignment
    - [ ] Test position reordering
    - [ ] Test cascade deletion (deleting column deletes tasks)
  - [ ] Create `test/kanban/tasks_test.exs`:
    - [ ] Test all CRUD operations
    - [ ] Test automatic position assignment
    - [ ] Test moving tasks between columns
    - [ ] Test position reordering within column
    - [ ] Test position updates when task deleted
- [ ] **Quality Checks (Phase 4)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues
  - [ ] Run `mix sobelow --config` and fix any security issues

#### Phase 4: Board Management UI

- [ ] **Create board list LiveView**
  - [ ] Create `lib/kanban_web/live/board_live/index.ex`
  - [ ] Implement `mount/3` to load user's boards
  - [ ] Use streams for board collection
  - [ ] Create template with board cards
  - [ ] Add "New Board" button
  - [ ] Add edit/delete actions for each board
- [ ] **Create board show LiveView**
  - [ ] Create `lib/kanban_web/live/board_live/show.ex`
  - [ ] Load board with preloaded columns and tasks
  - [ ] Display board name and description
  - [ ] Show all columns with their tasks
  - [ ] Add "New Column" button
- [ ] **Create board form component**
  - [ ] Create `lib/kanban_web/live/board_live/form_component.ex`
  - [ ] Build form for creating/editing boards
  - [ ] Add validation and error display
  - [ ] Handle form submission
- [ ] **Add routes**
  - [ ] Add routes in `lib/kanban_web/router.ex` under authenticated scope
  - [ ] `live "/boards", BoardLive.Index, :index`
  - [ ] `live "/boards/new", BoardLive.Index, :new`
  - [ ] `live "/boards/:id/edit", BoardLive.Index, :edit`
  - [ ] `live "/boards/:id", BoardLive.Show, :show`
- [ ] **Write LiveView tests**
  - [ ] Create `test/kanban_web/live/board_live_test.exs`
  - [ ] Test board list rendering
  - [ ] Test creating new board
  - [ ] Test editing board
  - [ ] Test deleting board
  - [ ] Test authorization (can't access other users' boards)
- [ ] **Quality Checks (Phase 5)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues
  - [ ] Run `mix sobelow --config` and fix any security issues

#### Phase 5: Column Management UI

- [ ] **Add column creation to board show view**
  - [ ] Add inline form or modal for new columns
  - [ ] Display columns in order by position
  - [ ] Show column name and task count
- [ ] **Create column form component**
  - [ ] Create `lib/kanban_web/live/column_live/form_component.ex`
  - [ ] Build form for creating/editing columns
  - [ ] Handle form submission
- [ ] **Add column actions**
  - [ ] Add edit column name inline or via modal
  - [ ] Add delete column with confirmation
  - [ ] Ensure tasks are deleted when column deleted
- [ ] **Write LiveView tests**
  - [ ] Test column creation
  - [ ] Test column editing
  - [ ] Test column deletion
  - [ ] Test column ordering
- [ ] **Quality Checks (Phase 6)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues

#### Phase 6: Task Management UI

- [ ] **Add task display to columns**
  - [ ] Use streams to display tasks within each column
  - [ ] Show task title and description
  - [ ] Display in order by position
- [ ] **Create task form component**
  - [ ] Create `lib/kanban_web/live/task_live/form_component.ex`
  - [ ] Build form for creating/editing tasks
  - [ ] Handle form submission
- [ ] **Add task actions**
  - [ ] Add "New Task" button in each column
  - [ ] Add edit task button
  - [ ] Add delete task with confirmation
- [ ] **Write LiveView tests**
  - [ ] Test task creation
  - [ ] Test task editing
  - [ ] Test task deletion
  - [ ] Test task display in correct column
- [ ] **Quality Checks (Phase 7)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues

#### Phase 7: Drag & Drop Functionality

- [ ] **Install drag-and-drop library**
  - [ ] Add Sortable.js or use native HTML5 drag-and-drop
  - [ ] Configure in `assets/js/app.js`
- [ ] **Create LiveView hooks for drag-and-drop**
  - [ ] Create hook in `assets/js/hooks.js`
  - [ ] Handle drag start, drag over, and drop events
  - [ ] Send events to LiveView
- [ ] **Implement server-side move handlers**
  - [ ] Add `handle_event("move_task", ...)` to board show LiveView
  - [ ] Call `Tasks.move_task/3` context function
  - [ ] Update UI with new task positions
- [ ] **Add visual feedback**
  - [ ] Add drag handle to tasks
  - [ ] Show placeholder when dragging
  - [ ] Highlight drop zones
- [ ] **Write LiveView tests**
  - [ ] Test moving task within same column
  - [ ] Test moving task to different column
  - [ ] Test position updates after move
- [ ] **Quality Checks (Phase 8)**:
  - [ ] Run `mix test` and ensure all tests pass
  - [ ] Run `mix test --cover` and verify coverage meets threshold
  - [ ] Run `mix credo --strict` and fix any issues

#### Phase 8: Polish & Enhancement

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
