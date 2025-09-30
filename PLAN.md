# Kanban Board Application - Development Plan

## Project Overview
Build a full-featured Kanban board application using Phoenix LiveView where authenticated users can create boards, manage columns, and organize tasks.

## Core Features
- User authentication and authorization
- Create and manage multiple Kanban boards
- Add named columns to boards
- Create tasks within columns
- Drag-and-drop tasks between columns
- Responsive, modern UI with smooth interactions

---

## Development Phases

### Phase 1: User Authentication
**Status:** Not Started

#### Tasks
- [ ] Generate authentication system using `mix phx.gen.auth`
- [ ] Run authentication migrations
- [ ] Test user registration flow
- [ ] Test user login/logout flow
- [ ] Update navigation with auth links (sign in, sign up, sign out)
- [ ] Run tests to ensure authentication works
- [ ] Run security audit (`mix sobelow --config`)

**Deliverable:** Functional user authentication system with registration, login, and logout

---

### Phase 2: Database Schema & Contexts
**Status:** Not Started

#### 2.1 Design Database Schema
- [ ] Create `boards` table (user_id, name, description, timestamps)
- [ ] Create `columns` table (board_id, name, position, timestamps)
- [ ] Create `tasks` table (column_id, title, description, position, timestamps)
- [ ] Document relationships (User has_many Boards, Board has_many Columns, Column has_many Tasks)

#### 2.2 Create Ecto Schemas
- [ ] Generate Board schema and migration
- [ ] Generate Column schema and migration
- [ ] Generate Task schema and migration
- [ ] Add associations to schemas (belongs_to, has_many)
- [ ] Run migrations with `mix ecto.migrate`

#### 2.3 Build Context Modules
- [ ] Create `Kanban.Boards` context
  - [ ] `list_boards(user_id)` - List all boards for a user
  - [ ] `get_board!(id, user_id)` - Get a board with authorization
  - [ ] `create_board(user, attrs)` - Create a new board
  - [ ] `update_board(board, attrs)` - Update board details
  - [ ] `delete_board(board)` - Delete a board
  - [ ] **Write unit tests for each function as you implement them**
  - [ ] **Run `mix test` after implementing Boards context**

- [ ] Create `Kanban.Columns` context
  - [ ] `list_columns(board_id)` - List all columns for a board
  - [ ] `create_column(board, attrs)` - Create a column
  - [ ] `update_column(column, attrs)` - Update column name/position
  - [ ] `delete_column(column)` - Delete a column
  - [ ] `reorder_columns(board_id, column_ids)` - Update column positions
  - [ ] **Write unit tests for each function as you implement them**
  - [ ] **Run `mix test` after implementing Columns context**

- [ ] Create `Kanban.Tasks` context
  - [ ] `list_tasks(column_id)` - List all tasks in a column
  - [ ] `create_task(column, attrs)` - Create a task
  - [ ] `update_task(task, attrs)` - Update task details
  - [ ] `delete_task(task)` - Delete a task
  - [ ] `move_task(task, new_column_id, new_position)` - Move task between columns
  - [ ] **Write unit tests for each function as you implement them**
  - [ ] **Run `mix test` after implementing Tasks context**

#### 2.4 Quality Checks
- [ ] Run `mix test --cover` and verify coverage threshold
- [ ] Run `mix credo --strict` and fix any issues
- [ ] Run `mix sobelow --config` and address security concerns

**Deliverable:** Complete database schema with tested context modules for business logic

---

### Phase 3: Board Management LiveViews
**Status:** Not Started

#### 3.1 Boards Index Page
- [ ] Create `KanbanWeb.BoardLive.Index` LiveView
- [ ] Display list of user's boards in a grid/card layout
- [ ] Add "New Board" button with modal form
- [ ] Implement board creation form with validation
- [ ] Add edit and delete actions for each board
- [ ] Add empty state UI when user has no boards
- [ ] Style with Tailwind CSS for modern appearance
- [ ] Add route `/boards` to router (requires authentication)
- [ ] **Write LiveView tests for index page as you build it**
- [ ] **Run `mix test` to verify tests pass**

#### 3.2 Board Show Page (Main Kanban View)
- [ ] Create `KanbanWeb.BoardLive.Show` LiveView
- [ ] Display board name and description
- [ ] Show all columns horizontally
- [ ] Display tasks within each column
- [ ] Add "New Column" button
- [ ] Add "New Task" button within each column
- [ ] Add route `/boards/:id` to router (requires authentication)
- [ ] Implement authorization check (user can only view own boards)
- [ ] **Write LiveView tests for show page as you build it**
- [ ] **Run `mix test` to verify tests pass**

#### 3.3 Quality Checks
- [ ] Run `mix test --cover` and verify coverage
- [ ] Run `mix credo --strict` and fix any issues
- [ ] Run `mix sobelow --config` and address security concerns

**Deliverable:** Functional board listing and viewing with create/edit/delete operations

---

### Phase 4: Column Management
**Status:** Not Started

#### 4.1 Column CRUD Operations
- [ ] Create column creation modal/form component
- [ ] Implement `handle_event` for creating columns
- [ ] **Write tests for column creation**
- [ ] Add inline column name editing
- [ ] **Write tests for column editing**
- [ ] Implement column deletion with confirmation
- [ ] **Write tests for column deletion**
- [ ] Add empty state when board has no columns
- [ ] Update LiveView to use streams for columns
- [ ] **Run `mix test` to verify all column tests pass**

#### 4.2 Column Positioning
- [ ] Add position field to columns
- [ ] Implement column reordering logic in context
- [ ] Add visual indicators for column order
- [ ] **Write tests for column positioning**
- [ ] **Run `mix test` to verify positioning tests pass**

#### 4.3 Column Styling
- [ ] Style columns with cards/containers
- [ ] Add column headers with name and actions
- [ ] Make columns scrollable vertically
- [ ] Ensure responsive layout

#### 4.4 Quality Checks
- [ ] Run `mix test --cover` and verify coverage
- [ ] Run `mix credo --strict` and fix any issues
- [ ] Run `mix sobelow --config` and address security concerns

**Deliverable:** Full column management with create, edit, delete, and positioning

---

### Phase 5: Task Management
**Status:** Not Started

#### 5.1 Task CRUD Operations
- [ ] Create task creation form within columns
- [ ] Implement `handle_event` for creating tasks
- [ ] **Write tests for task creation**
- [ ] Create task edit modal/inline editing
- [ ] **Write tests for task editing**
- [ ] Implement task deletion with confirmation
- [ ] **Write tests for task deletion**
- [ ] Add empty state when column has no tasks
- [ ] Update LiveView to use streams for tasks
- [ ] **Run `mix test` to verify all task tests pass**

#### 5.2 Task Display
- [ ] Design task card component
- [ ] Display task title and description (truncated)
- [ ] Add task actions (edit, delete)
- [ ] Style task cards with Tailwind CSS
- [ ] Add hover effects and micro-interactions

#### 5.3 Quality Checks
- [ ] Run `mix test --cover` and verify coverage
- [ ] Run `mix credo --strict` and fix any issues
- [ ] Run `mix sobelow --config` and address security concerns

**Deliverable:** Complete task CRUD operations with polished UI

---

### Phase 6: Drag-and-Drop Functionality
**Status:** Not Started

#### 6.1 JavaScript Drag-and-Drop Integration
- [ ] Research drag-and-drop libraries (Sortable.js recommended)
- [ ] Install and configure drag-and-drop library in `assets/js/app.js`
- [ ] Create Phoenix Hook for drag-and-drop events
- [ ] Add `phx-hook` and `phx-update="ignore"` to draggable containers

#### 6.2 Server-Side Task Movement
- [ ] Implement `handle_event("move_task", ...)` in LiveView
- [ ] Update task column_id and position in database
- [ ] Broadcast updates to LiveView
- [ ] Handle edge cases (invalid moves, concurrent updates)
- [ ] **Write tests for task movement between columns**
- [ ] **Write tests for position updates**
- [ ] **Write tests for authorization (users can't move other users' tasks)**
- [ ] **Run `mix test` to verify all tests pass**

#### 6.3 Drag-and-Drop UX
- [ ] Add visual feedback during drag (opacity, shadow)
- [ ] Show drop zones
- [ ] Add smooth animations for task movement
- [ ] Ensure mobile-friendly alternative (move buttons)

#### 6.4 Quality Checks
- [ ] Run `mix test --cover` and verify coverage
- [ ] Run `mix credo --strict` and fix any issues
- [ ] Run `mix sobelow --config` and address security concerns

**Deliverable:** Smooth drag-and-drop task movement between columns

---

### Phase 7: Polish & User Experience
**Status:** Not Started

#### 7.1 UI/UX Enhancements
- [ ] Add loading states for async operations
- [ ] Implement flash messages for success/error feedback
- [ ] Add confirmation modals for destructive actions
- [ ] Implement keyboard shortcuts (ESC to close modals, etc.)
- [ ] Add smooth page transitions
- [ ] Ensure consistent spacing and typography

#### 7.2 Responsive Design
- [ ] Test on mobile devices
- [ ] Implement mobile-friendly navigation
- [ ] Make columns stack vertically on small screens
- [ ] Ensure touch-friendly interactions

#### 7.3 Performance Optimization
- [ ] Use LiveView streams for all collections
- [ ] Optimize database queries (preloading, indexes)
- [ ] Add database indexes on foreign keys
- [ ] Test with large datasets (many boards/columns/tasks)

#### 7.4 Accessibility
- [ ] Add proper ARIA labels
- [ ] Ensure keyboard navigation works
- [ ] Test with screen readers
- [ ] Verify color contrast ratios

**Deliverable:** Polished, responsive, and accessible user interface

---

### Phase 8: Final Integration & Quality Assurance
**Status:** Not Started

> **Note:** Most testing, code quality checks, and security audits should already be complete from previous phases. This phase focuses on integration testing and final verification.

#### 8.1 Integration Testing
- [ ] Write end-to-end integration tests for complete user flows
  - [ ] User registration → create board → add columns → add tasks → move tasks
  - [ ] Multiple users with isolated data
  - [ ] Error handling and edge cases
- [ ] Run full test suite with `mix test`
- [ ] Achieve >80% code coverage with `mix test --cover`

#### 8.2 Final Code Quality Review
- [ ] Run `mix credo --strict` and ensure no issues remain
- [ ] Run `mix format --check-formatted` to verify formatting
- [ ] Review code for Elixir/Phoenix best practices per AGENTS.md
- [ ] Refactor any complex functions or duplicated code

#### 8.3 Final Security Audit
- [ ] Run `mix sobelow --config` and ensure no issues remain
- [ ] Run `mix deps.audit` and `mix hex.audit`
- [ ] Verify all routes require authentication
- [ ] Verify CSRF protection on all forms
- [ ] Manual test: Attempt to access another user's boards/data
- [ ] Review for any hardcoded secrets or sensitive data

#### 8.4 Final Quality Check
- [ ] Run `mix precommit` and ensure it passes cleanly
- [ ] Review AGENTS.md guidelines compliance checklist
- [ ] Test in multiple browsers (Chrome, Firefox, Safari)
- [ ] Perform manual testing of all features
- [ ] Test with large datasets (many boards/columns/tasks)

**Deliverable:** Production-ready application with comprehensive test coverage and verified quality

---

### Phase 9: Documentation & Deployment Prep
**Status:** Not Started

#### 9.1 Documentation
- [ ] Update README.md with project description
- [ ] Document setup instructions
- [ ] Add usage guide with screenshots
- [ ] Document API/context functions
- [ ] Add inline code documentation where needed

#### 9.2 Seed Data
- [ ] Create `priv/repo/seeds.exs` with sample data
- [ ] Add sample users, boards, columns, and tasks
- [ ] Test seed script with `mix run priv/repo/seeds.exs`

#### 9.3 Environment Configuration
- [ ] Review production configuration in `config/runtime.exs`
- [ ] Ensure secrets are properly configured
- [ ] Set up production database configuration
- [ ] Configure email delivery for production (if needed)

**Deliverable:** Complete documentation and deployment-ready configuration

---

## Technical Stack

### Backend
- Phoenix 1.8.1
- Phoenix LiveView 1.1.13
- Ecto 3.13.3
- PostgreSQL

### Frontend
- Tailwind CSS v4
- Hero Icons
- JavaScript (drag-and-drop library)
- Phoenix LiveView JS hooks

### Quality Tools
- ExUnit (testing)
- Credo (code quality)
- Sobelow (security)
- mix_audit (dependency security)

---

## Success Criteria

- ✅ Users can register and authenticate
- ✅ Users can create multiple boards
- ✅ Users can add/edit/delete columns on boards
- ✅ Users can add/edit/delete tasks in columns
- ✅ Users can drag-and-drop tasks between columns
- ✅ Users can only access their own boards
- ✅ Application has >80% test coverage
- ✅ All security audits pass
- ✅ UI is responsive and accessible
- ✅ Code follows Phoenix/Elixir best practices

---

## Development Workflow Guidelines

### Quality-First Development Approach

**Test-Driven Development:**
- Write unit tests **as you implement each function**, not after
- Run `mix test` frequently to catch issues early
- Each context function should have corresponding tests before moving on

**Continuous Quality Checks:**
- Run `mix credo --strict` after completing each major feature
- Fix Credo issues immediately rather than accumulating technical debt
- Run `mix format` regularly to maintain consistent code style

**Security Throughout:**
- Run `mix sobelow --config` after each phase
- Run `mix deps.audit` and `mix hex.audit` when adding dependencies
- Address security issues immediately, never defer them

**Phase Completion Checklist:**
Every phase should end with:
1. ✅ All tests passing (`mix test`)
2. ✅ Coverage meeting threshold (`mix test --cover`)
3. ✅ No Credo issues (`mix credo --strict`)
4. ✅ No security issues (`mix sobelow --config`)
5. ✅ Code formatted (`mix format`)

**Best Practices:**
- Follow guidelines in AGENTS.md throughout development
- Use HexDoc MCP server for documentation lookups
- Use TideWave MCP server for application inspection
- Commit frequently with descriptive messages
- Review and update PLAN.md as you progress

---

**Last Updated:** 2025-09-30
**Status:** Planning Complete - Ready to Begin Phase 1
