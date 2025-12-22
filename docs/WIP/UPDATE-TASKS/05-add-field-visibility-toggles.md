# Add Field Visibility Toggles to Board UI

**Complexity:** Medium | **Est. Files:** 5-6

## Description

**WHY:** Board owners need control over which task fields are visible to avoid information overload and customize the board view for all users based on the team's workflow needs.

**WHAT:** Add checkboxes to board UI that toggle visibility of rich task fields. Store visibility preferences in the boards table. Only board owners can change settings. All users viewing the board see the same field visibility. Show acceptance criteria, why, what, metrics_to_track, error_user_message, error_on_failure, completion_summary, dependencies, status, needs_review, review_status, and review_notes by default, hide all other new fields by default.

**WHERE:** Board LiveView header (owner-only settings panel)

## Acceptance Criteria

- [ ] Migration adds field_visibility JSONB column to boards table
- [ ] Checkboxes added to board UI (visible only to board owners)
- [ ] Acceptance criteria defaults to visible in database
- [ ] All other field checkboxes default to hidden in database
- [ ] Settings stored in boards table, not localStorage
- [ ] Only board owner can toggle field visibility
- [ ] Non-owners see read-only view (no checkboxes)
- [ ] Field visibility changes broadcast via PubSub
- [ ] All connected clients update in real-time
- [ ] Task cards show/hide fields based on board settings
- [ ] Tests cover owner-only access and real-time updates

## Key Files to Read First

- [lib/kanban/boards/board.ex](lib/kanban/boards/board.ex) - Board schema
- [lib/kanban/boards/board_user.ex](lib/kanban/boards/board_user.ex) - Access levels (owner, read_only, modify)
- [lib/kanban_web/live/board_live.ex](lib/kanban_web/live/board_live.ex) - Main board LiveView
- [lib/kanban_web/live/board_live.html.heex](lib/kanban_web/live/board_live.html.heex) - Board template
- [lib/kanban/boards.ex](lib/kanban/boards.ex) - Boards context module

## Technical Notes

**Patterns to Follow:**
- Add JSONB column `field_visibility` to boards table
- Default value: `{"acceptance_criteria": true, "complexity": false, ...}`
- Use LiveView event handlers for checkbox changes
- Broadcast changes via PubSub: `Kanban.PubSub`, topic: `"board:#{board_id}"`
- Check user access level before allowing changes (owner only)
- Use assigns to pass field visibility to task card components
- Follow existing authorization patterns from BoardUser

**Database/Schema:**
- Tables: boards (add field_visibility column)
- Migrations needed: Yes - add JSONB column with default
- Field: `field_visibility` (JSONB, not null, default with all fields)

**Field Categories to Toggle:**
- acceptance_criteria (default: true)
- complexity (default: false)
- context (default: false)
- key_files (default: false)
- verification_steps (default: false)
- technical_notes (default: false)
- observability (default: false)
- error_handling (default: false)
- technology_requirements (default: false)
- pitfalls (default: false)
- out_of_scope (default: false)

**Integration Points:**
- [ ] PubSub broadcasts: Broadcast field visibility changes on `board:#{board_id}` topic
- [ ] Phoenix Channels: None (using LiveView PubSub)
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Create and run migration
mix ecto.gen.migration add_field_visibility_to_boards
mix ecto.migrate

# Test in console
iex -S mix
alias Kanban.{Boards, Repo}

# Get a board
board = Boards.get_board!(1)

# Update field visibility (as owner)
{:ok, updated_board} = Boards.update_field_visibility(board, %{
  "complexity" => true,
  "key_files" => true
})

# Verify stored correctly
IO.inspect(updated_board.field_visibility)

# Run tests
mix test test/kanban/boards_test.exs
mix test test/kanban_web/live/board_live_test.exs

# Run precommit
mix precommit
```

**Manual Testing:**
1. Log in as board owner
2. Open board - verify settings panel visible
3. Verify acceptance criteria checked by default
4. Verify all other fields unchecked by default
5. Check "Key Files" checkbox
6. Verify all task cards immediately show key files
7. Open board in second browser window (as different user)
8. Verify second window shows key files (real-time update)
9. In second window (non-owner), verify checkboxes not editable
10. As owner, uncheck "Key Files"
11. Verify both windows hide key files immediately
12. Reload page as owner
13. Verify settings persist from database
14. Log in as non-owner user
15. Verify settings panel not visible or read-only

**Success Looks Like:**
- Migration adds field_visibility column
- Settings panel shows only for board owners
- Non-owners see task fields but can't change settings
- Changes broadcast to all users in real-time
- Settings persist in database
- All tests pass
- No authorization bypass possible

## Data Examples

**Migration:**
```elixir
defmodule Kanban.Repo.Migrations.AddFieldVisibilityToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :field_visibility, :map, null: false, default: %{
        "acceptance_criteria" => true,
        "complexity" => false,
        "context" => false,
        "key_files" => false,
        "verification_steps" => false,
        "technical_notes" => false,
        "observability" => false,
        "error_handling" => false,
        "technology_requirements" => false,
        "pitfalls" => false,
        "out_of_scope" => false
      }
    end
  end
end
```

**Schema Update:**
```elixir
defmodule Kanban.Boards.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    field :description, :string
    field :field_visibility, :map, default: %{
      "acceptance_criteria" => true,
      "complexity" => false,
      "context" => false,
      "key_files" => false,
      "verification_steps" => false,
      "technical_notes" => false,
      "observability" => false,
      "error_handling" => false,
      "technology_requirements" => false,
      "pitfalls" => false,
      "out_of_scope" => false
    }
    field :user_access, Ecto.Enum, values: [:owner, :read_only, :modify], virtual: true

    has_many :board_users, Kanban.Boards.BoardUser
    has_many :columns, Kanban.Columns.Column
    many_to_many :users, Kanban.Accounts.User, join_through: Kanban.Boards.BoardUser

    timestamps()
  end

  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :description, :field_visibility])
    |> validate_required([:name])
    |> validate_length(:name, min: 5, max: 50)
    |> validate_length(:description, max: 255)
    |> validate_field_visibility()
  end

  defp validate_field_visibility(changeset) do
    case get_change(changeset, :field_visibility) do
      nil ->
        changeset

      visibility when is_map(visibility) ->
        # Validate all expected keys are present and boolean
        required_keys = [
          "acceptance_criteria", "complexity", "context", "key_files",
          "verification_steps", "technical_notes", "observability",
          "error_handling", "technology_requirements", "pitfalls", "out_of_scope"
        ]

        if Enum.all?(required_keys, &Map.has_key?(visibility, &1)) do
          changeset
        else
          add_error(changeset, :field_visibility, "missing required field visibility keys")
        end

      _ ->
        add_error(changeset, :field_visibility, "must be a map")
    end
  end
end
```

**Context Function:**
```elixir
defmodule Kanban.Boards do
  # ... existing functions ...

  @doc """
  Updates field visibility settings for a board.
  Only board owners can update field visibility.
  Broadcasts changes to all connected clients.
  """
  def update_field_visibility(%Board{} = board, field_visibility, %User{} = user) do
    # Check if user is owner
    unless is_board_owner?(board, user) do
      {:error, :unauthorized}
    else
      board
      |> Board.changeset(%{field_visibility: field_visibility})
      |> Repo.update()
      |> case do
        {:ok, updated_board} ->
          # Broadcast to all clients viewing this board
          Phoenix.PubSub.broadcast(
            Kanban.PubSub,
            "board:#{board.id}",
            {:field_visibility_updated, updated_board.field_visibility}
          )

          {:ok, updated_board}

        error ->
          error
      end
    end
  end

  defp is_board_owner?(%Board{id: board_id}, %User{id: user_id}) do
    from(bu in BoardUser,
      where: bu.board_id == ^board_id and bu.user_id == ^user_id and bu.access == :owner
    )
    |> Repo.exists?()
  end
end
```

**LiveView Implementation:**
```elixir
defmodule KanbanWeb.BoardLive do
  use KanbanWeb, :live_view

  def mount(%{"id" => board_id}, _session, socket) do
    board = Boards.get_board!(board_id)

    # Subscribe to board updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board_id}")
    end

    {:ok,
     socket
     |> assign(:board, board)
     |> assign(:field_visibility, board.field_visibility)
     |> assign(:is_owner, is_owner?(socket.assigns.current_user, board))}
  end

  def handle_event("toggle_field", %{"field" => field_name}, socket) do
    # Only allow owner to toggle
    if socket.assigns.is_owner do
      board = socket.assigns.board
      current_visibility = socket.assigns.field_visibility
      new_visibility = Map.put(current_visibility, field_name, !current_visibility[field_name])

      case Boards.update_field_visibility(board, new_visibility, socket.assigns.current_user) do
        {:ok, updated_board} ->
          {:noreply, assign(socket, :field_visibility, updated_board.field_visibility)}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "Only board owners can change field visibility")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update field visibility")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only board owners can change field visibility")}
    end
  end

  # Handle PubSub broadcasts from other clients
  def handle_info({:field_visibility_updated, new_visibility}, socket) do
    {:noreply, assign(socket, :field_visibility, new_visibility)}
  end

  defp is_owner?(user, board) do
    Enum.any?(board.board_users, fn bu ->
      bu.user_id == user.id && bu.access == :owner
    end)
  end
end
```

**LiveView Template:**
```heex
<!-- Field Visibility Controls (Owner Only) -->
<div :if={@is_owner} class="mb-4 p-4 bg-gray-50 rounded-lg border border-gray-200">
  <h3 class="text-sm font-semibold mb-2 flex items-center">
    <.icon name="hero-eye" class="w-4 h-4 mr-2" />
    Field Visibility (Owner Settings)
  </h3>
  <div class="grid grid-cols-2 md:grid-cols-3 gap-2">
    <%= for {field_key, field_label} <- field_options() do %>
      <label class="flex items-center text-sm cursor-pointer hover:bg-gray-100 p-1 rounded">
        <input
          type="checkbox"
          phx-click="toggle_field"
          phx-value-field={field_key}
          checked={@field_visibility[field_key]}
          class="mr-2"
        />
        <%= field_label %>
      </label>
    <% end %>
  </div>
</div>

<!-- Read-only indicator for non-owners -->
<div :if={!@is_owner and any_fields_visible?(@field_visibility)} class="mb-4 p-2 bg-blue-50 rounded text-sm text-blue-700">
  <.icon name="hero-information-circle" class="w-4 h-4 inline mr-1" />
  Visible fields configured by board owner
</div>

<!-- Task cards with conditional field rendering -->
<div class="task-card">
  <h3><%= @task.title %></h3>
  <p class="text-sm text-gray-600"><%= @task.description %></p>

  <!-- Acceptance Criteria (visible by default) -->
  <div :if={@field_visibility["acceptance_criteria"]} class="mt-2">
    <h4 class="font-semibold text-sm">Acceptance Criteria</h4>
    <!-- render criteria -->
  </div>

  <!-- Complexity (hidden by default) -->
  <div :if={@field_visibility["complexity"] and @task.complexity} class="mt-2">
    <span class="badge"><%= @task.complexity %></span>
    <span class="text-sm"><%= @task.estimated_files %> files</span>
  </div>

  <!-- Context (hidden by default) -->
  <div :if={@field_visibility["context"]} class="mt-2">
    <div :if={@task.why}><strong>Why:</strong> <%= @task.why %></div>
    <div :if={@task.what}><strong>What:</strong> <%= @task.what %></div>
    <div :if={@task.where_context}><strong>Where:</strong> <%= @task.where_context %></div>
  </div>

  <!-- Key Files (hidden by default) -->
  <div :if={@field_visibility["key_files"] and @task.key_files} class="mt-2">
    <h4 class="font-semibold text-sm">Key Files</h4>
    <ul class="text-sm">
      <%= for file <- parse_key_files(@task.key_files) do %>
        <li><code><%= file.file_path %></code> - <%= file.note %></li>
      <% end %>
    </ul>
  </div>

  <!-- Additional fields similarly... -->
</div>
```

**Helper Functions:**
```elixir
defmodule KanbanWeb.BoardLive do
  # ... existing code ...

  defp field_options do
    [
      {"acceptance_criteria", "Acceptance Criteria"},
      {"complexity", "Complexity & Scope"},
      {"context", "Context (Why/What/Where)"},
      {"key_files", "Key Files"},
      {"verification_steps", "Verification Steps"},
      {"technical_notes", "Technical Notes"},
      {"observability", "Observability"},
      {"error_handling", "Error Handling"},
      {"technology_requirements", "Technology Requirements"},
      {"pitfalls", "Pitfalls"},
      {"out_of_scope", "Out of Scope"}
    ]
  end

  defp any_fields_visible?(field_visibility) do
    Enum.any?(field_visibility, fn {_key, visible} -> visible end)
  end

  defp parse_key_files(nil), do: []
  defp parse_key_files(text) do
    Kanban.Tasks.TextFieldParser.parse_key_files(text)
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :board, :field_visibility_updated]`
- [ ] Metrics: Counter of field visibility changes by board
- [ ] Logging: Log visibility changes at info level with board_id and user_id

## Error Handling

- User sees: "Only board owners can change field visibility" if unauthorized
- On failure: Field visibility remains unchanged, error flash message shown
- Validation: Ensure all expected keys present in field_visibility map

## Common Pitfalls

- [ ] Don't allow non-owners to change field visibility settings
- [ ] Remember to broadcast changes via PubSub to all connected clients
- [ ] Avoid race conditions when multiple owners toggle simultaneously
- [ ] Don't forget to preload board_users association to check ownership
- [ ] Remember to validate field_visibility map has all required keys
- [ ] Avoid breaking existing boards - provide default in migration
- [ ] Don't forget to subscribe to PubSub topic in mount
- [ ] Remember to handle nil values in task fields gracefully
- [ ] Avoid showing empty field sections when field is visible but data is nil

## Dependencies

**Requires:** 09-add-task-creation-form.md
**Blocks:** None (can work in parallel with API tasks 03-07)

## Out of Scope

- Don't implement per-user visibility overrides (board-level only)
- Don't add field ordering/rearranging
- Don't add preset visibility profiles
- Don't implement field visibility history/audit log
- Future enhancement: Allow users to temporarily override board settings
- Future enhancement: Visibility presets (Developer view, Manager view, etc.)
- Future enhancement: Per-column field visibility settings
