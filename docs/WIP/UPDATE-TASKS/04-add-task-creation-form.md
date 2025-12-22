# Add Task Creation/Edit Form with Rich Fields

**Complexity:** Large | **Est. Files:** 5-7

## Description

**WHY:** Users need a UI to create and edit tasks with all the rich fields. Currently can only set title and description. Form needs to support nested associations (key files, verification steps, pitfalls, out of scope).

**WHAT:** Create comprehensive task form with all 18 TASKS.md categories, dynamic nested forms for collections, validation feedback, and smart defaults. Support both creation and editing modes.

**WHERE:** New LiveView form component, form templates

## Acceptance Criteria

- [ ] Form displays all task fields organized in sections
- [ ] Basic fields: title, description, acceptance_criteria, type (work/defect), priority
- [ ] Complexity dropdown (small, medium, large)
- [ ] Estimated files input (text field)
- [ ] Text inputs for why/what/where_context
- [ ] Dynamic embedded forms for key_files (add/remove file_path, note)
- [ ] Dynamic embedded forms for verification_steps (add/remove step_type, step_text, expected_result)
- [ ] Simple array inputs for technology_requirements (add/remove strings)
- [ ] Simple array inputs for pitfalls (add/remove strings)
- [ ] Simple array inputs for out_of_scope (add/remove strings)
- [ ] Dependencies as string array (task identifiers)
- [ ] Status dropdown (open, in_progress, completed, blocked)
- [ ] Agent tracking fields: created_by_agent, completed_by_agent, completion_summary
- [ ] Claim tracking: claimed_at, claim_expires_at, required_capabilities
- [ ] Actual metrics: actual_complexity, actual_files_changed, time_spent_minutes
- [ ] Review fields: needs_review checkbox, review_status, review_notes
- [ ] Form validates all required fields (title, position, type, priority, status)
- [ ] Form handles create and edit modes
- [ ] Real-time validation feedback

## Key Files to Read First

- [lib/kanban_web/live/board_live.ex](lib/kanban_web/live/board_live.ex) - Main LiveView
- [lib/kanban_web/live/board_live.html.heex](lib/kanban_web/live/board_live.html.heex) - Board template
- [lib/kanban_web/components/core_components.ex](lib/kanban_web/components/core_components.ex) - Form components
- [lib/kanban/schemas/task.ex](lib/kanban/schemas/task.ex) - Schema with changeset
- [docs/WIP/TASKS.md](docs/WIP/TASKS.md) - All fields to include

## Technical Notes

**Patterns to Follow:**
- Use LiveView for dynamic form behavior
- Use Phoenix.Component for reusable form sections
- Follow existing form patterns from the app
- Use Tailwind CSS for styling
- Leverage core_components input helpers
- Use inputs_for for nested associations

**Database/Schema:**
- Tables: tasks (only, all nested data stored as JSONB)
- Embedded schemas: key_files, verification_steps (use cast_embed)
- String arrays: technology_requirements, pitfalls, out_of_scope (simple arrays)
- Migrations needed: No
- Changeset: Use cast_embed for key_files and verification_steps

**Form Sections:**
1. **Basic Info**: Title, description, acceptance_criteria, type (work/defect), priority
2. **Complexity**: Dropdown, estimated files
3. **Context**: Why, what, where (textareas)
4. **Key Files**: Embedded form (file_path, note, position)
5. **Verification**: Embedded form (step_type, step_text, expected_result)
6. **Technical**: Patterns, database changes, technology_requirements (textareas)
7. **Observability**: Telemetry event, metrics, logging
8. **Error Handling**: User message, on failure, validation rules
9. **Dependencies**: String array of task identifiers
10. **Pitfalls**: Simple string array (add/remove text items)
11. **Out of Scope**: Simple string array (add/remove text items)
12. **Status & Agent Tracking**: status, created_by_agent, completed_by_agent, completion_summary
13. **Claim Tracking**: claimed_at, claim_expires_at, required_capabilities
14. **Actual Metrics**: actual_complexity, actual_files_changed, time_spent_minutes
15. **Review Queue**: needs_review, review_status, review_notes

**Integration Points:**
- [ ] PubSub broadcasts: Broadcast task created/updated
- [ ] Phoenix Channels: Update all clients
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Run tests
mix test test/kanban_web/live/board_live_test.exs
mix test test/kanban_web/live/task_form_component_test.exs

# Start server
mix phx.server

# Test manually at http://localhost:4000
# 1. Click "New Task" button
# 2. Fill out all fields
# 3. Add key files
# 4. Add verification steps
# 5. Submit form
# 6. Verify task created with all data

# Run precommit
mix precommit
```

**Manual Testing:**
1. Click "New Task" in board UI
2. Fill out basic info (title, complexity)
3. Add 3 key files with notes
4. Add 2 verification steps (1 command, 1 manual)
5. Add 2 pitfalls
6. Add 1 out of scope item
7. Select dependencies from dropdown
8. Submit form
9. Verify task appears on board
10. Click to view details - verify all data saved
11. Edit the task
12. Remove 1 key file, add 1 new one
13. Update verification step
14. Save changes
15. Verify updates persisted
16. Test validation - submit empty form
17. Verify error messages display

**Success Looks Like:**
- Form accessible and intuitive
- All fields present and labeled
- Nested forms work (add/remove items)
- Dependencies selectable
- Validation works
- Creates tasks with all data
- Edits preserve existing data
- Form responsive on mobile
- PubSub updates work

## Data Examples

**LiveView Form Component:**
```elixir
defmodule KanbanWeb.TaskFormComponent do
  use KanbanWeb, :live_component
  alias Kanban.Tasks
  alias Kanban.Schemas.Task

  @impl true
  def update(%{task: task} = assigns, socket) do
    changeset = Tasks.change_task(task)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)
     |> assign(:available_tasks, list_available_tasks(task))}
  end

  @impl true
  def handle_event("validate", %{"task" => task_params}, socket) do
    changeset =
      socket.assigns.task
      |> Tasks.change_task(task_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("add-key-file", _params, socket) do
    changeset = socket.assigns.changeset
    existing = Ecto.Changeset.get_field(changeset, :key_files) || []
    key_files = existing ++ [%Kanban.Schemas.Task.KeyFile{position: length(existing)}]

    changeset =
      changeset
      |> Ecto.Changeset.put_embed(:key_files, key_files)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("remove-key-file", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)
    changeset = socket.assigns.changeset
    key_files =
      (Ecto.Changeset.get_field(changeset, :key_files) || [])
      |> List.delete_at(index)

    changeset =
      changeset
      |> Ecto.Changeset.put_embed(:key_files, key_files)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("add-verification-step", _params, socket) do
    changeset = socket.assigns.changeset
    existing = Ecto.Changeset.get_field(changeset, :verification_steps) || []
    steps = existing ++ [%Kanban.Schemas.Task.VerificationStep{position: length(existing)}]

    changeset =
      changeset
      |> Ecto.Changeset.put_embed(:verification_steps, steps)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("remove-verification-step", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)
    changeset = socket.assigns.changeset
    steps =
      (Ecto.Changeset.get_field(changeset, :verification_steps) || [])
      |> List.delete_at(index)

    changeset =
      changeset
      |> Ecto.Changeset.put_embed(:verification_steps, steps)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("add-pitfall", _params, socket) do
    changeset = socket.assigns.changeset
    existing = Ecto.Changeset.get_field(changeset, :pitfalls) || []
    pitfalls = existing ++ [""]

    changeset = Ecto.Changeset.put_change(changeset, :pitfalls, pitfalls)
    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("remove-pitfall", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)
    changeset = socket.assigns.changeset
    pitfalls = (Ecto.Changeset.get_field(changeset, :pitfalls) || []) |> List.delete_at(index)

    changeset = Ecto.Changeset.put_change(changeset, :pitfalls, pitfalls)
    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("add-out-of-scope", _params, socket) do
    changeset = socket.assigns.changeset
    existing = Ecto.Changeset.get_field(changeset, :out_of_scope) || []
    out_of_scope = existing ++ [""]

    changeset = Ecto.Changeset.put_change(changeset, :out_of_scope, out_of_scope)
    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("remove-out-of-scope", %{"index" => index}, socket) do
    {index, _} = Integer.parse(index)
    changeset = socket.assigns.changeset
    out_of_scope = (Ecto.Changeset.get_field(changeset, :out_of_scope) || []) |> List.delete_at(index)

    changeset = Ecto.Changeset.put_change(changeset, :out_of_scope, out_of_scope)
    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"task" => task_params}, socket) do
    save_task(socket, socket.assigns.action, task_params)
  end

  defp save_task(socket, :new, task_params) do
    case Tasks.create_task(task_params) do
      {:ok, task} ->
        notify_parent({:saved, task})

        {:noreply,
         socket
         |> put_flash(:info, "Task created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp save_task(socket, :edit, task_params) do
    case Tasks.update_task(socket.assigns.task, task_params) do
      {:ok, task} ->
        notify_parent({:saved, task})

        {:noreply,
         socket
         |> put_flash(:info, "Task updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp list_available_tasks(current_task) do
    Tasks.list_tasks()
    |> Enum.reject(& &1.id == current_task.id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
      </.header>

      <.simple_form
        for={@changeset}
        id="task-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <!-- Basic Info -->
        <.input field={@changeset[:title]} type="text" label="Title" required />
        <.input field={@changeset[:description]} type="textarea" label="Description" />

        <!-- Complexity -->
        <div class="grid grid-cols-2 gap-4">
          <.input
            field={@changeset[:complexity]}
            type="select"
            label="Complexity"
            options={[{"Small", "small"}, {"Medium", "medium"}, {"Large", "large"}]}
            prompt="Select complexity"
          />
          <.input
            field={@changeset[:estimated_files]}
            type="select"
            label="Estimated Files"
            options={[{"1-2", "1-2"}, {"2-3", "2-3"}, {"3-5", "3-5"}, {"5+", "5+"}]}
            prompt="Select file count"
          />
        </div>

        <!-- Context Section -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Context</legend>
          <.input field={@changeset[:why]} type="textarea" label="Why (Problem being solved)" />
          <.input field={@changeset[:what]} type="textarea" label="What (Specific feature/change)" />
          <.input field={@changeset[:where_context]} type="textarea" label="Where (UI location or code area)" />
        </fieldset>

        <!-- Key Files -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Key Files to Read First</legend>
          <.inputs_for :let={kf} field={@changeset[:key_files]}>
            <div class="flex gap-2 mb-2">
              <.input field={kf[:file_path]} type="text" placeholder="lib/kanban/tasks.ex" class="flex-1" />
              <.input field={kf[:note]} type="text" placeholder="Note about this file" class="flex-1" />
              <.input field={kf[:position]} type="hidden" />
              <button
                type="button"
                phx-click="remove-key-file"
                phx-value-index={kf.index}
                phx-target={@myself}
                class="px-3 py-2 bg-red-500 text-white rounded"
              >
                Remove
              </button>
            </div>
          </.inputs_for>
          <button
            type="button"
            phx-click="add-key-file"
            phx-target={@myself}
            class="mt-2 px-4 py-2 bg-blue-500 text-white rounded"
          >
            Add Key File
          </button>
        </fieldset>

        <!-- Verification Steps -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Verification Steps</legend>
          <.inputs_for :let={vs} field={@changeset[:verification_steps]}>
            <div class="flex gap-2 mb-2">
              <.input
                field={vs[:step_type]}
                type="select"
                options={[{"Command", "command"}, {"Manual", "manual"}]}
                class="w-32"
              />
              <.input field={vs[:step_text]} type="text" placeholder="mix test" class="flex-1" />
              <.input field={vs[:expected_result]} type="text" placeholder="Expected result" class="flex-1" />
              <.input field={vs[:position]} type="hidden" />
              <button
                type="button"
                phx-click="remove-verification-step"
                phx-value-index={vs.index}
                phx-target={@myself}
                class="px-3 py-2 bg-red-500 text-white rounded"
              >
                Remove
              </button>
            </div>
          </.inputs_for>
          <button
            type="button"
            phx-click="add-verification-step"
            phx-target={@myself}
            class="mt-2 px-4 py-2 bg-blue-500 text-white rounded"
          >
            Add Verification Step
          </button>
        </fieldset>

        <!-- Technical Notes -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Technical Notes</legend>
          <.input field={@changeset[:patterns_to_follow]} type="textarea" label="Patterns to Follow" />
          <.input field={@changeset[:database_changes]} type="textarea" label="Database/Schema Changes" />
        </fieldset>

        <!-- Observability -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Observability</legend>
          <.input field={@changeset[:telemetry_event]} type="text" label="Telemetry Event" placeholder="[:kanban, :domain, :action]" />
          <.input field={@changeset[:metrics_to_track]} type="textarea" label="Metrics to Track" />
          <.input field={@changeset[:logging_requirements]} type="textarea" label="Logging Requirements" />
        </fieldset>

        <!-- Error Handling -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Error Handling</legend>
          <.input field={@changeset[:error_user_message]} type="text" label="User Sees (Error Message)" />
          <.input field={@changeset[:error_on_failure]} type="textarea" label="On Failure (What Happens)" />
          <.input field={@changeset[:validation_rules]} type="textarea" label="Validation Rules" />
        </fieldset>

        <!-- Integration Flags -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Integration Points</legend>
          <div class="grid grid-cols-2 gap-4">
            <.input field={@changeset[:pubsub_required]} type="checkbox" label="PubSub Broadcasts Required" />
            <.input field={@changeset[:channels_required]} type="checkbox" label="Phoenix Channels Required" />
            <.input field={@changeset[:migration_needed]} type="checkbox" label="Database Migration Needed" />
            <.input field={@changeset[:breaking_change]} type="checkbox" label="Breaking Change" />
          </div>
        </fieldset>

        <!-- Dependencies -->
        <.input
          field={@changeset[:dependencies]}
          type="select"
          label="Dependencies (Tasks that must complete first)"
          options={Enum.map(@available_tasks, &{&1.title, &1.id})}
          multiple
        />

        <!-- Pitfalls (simple string array) -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Common Pitfalls</legend>
          <%= for {pitfall, index} <- Enum.with_index(Ecto.Changeset.get_field(@changeset, :pitfalls) || []) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[pitfalls][]"
                value={pitfall}
                placeholder="Common pitfall to avoid"
                class="flex-1"
              />
              <button
                type="button"
                phx-click="remove-pitfall"
                phx-value-index={index}
                phx-target={@myself}
                class="px-3 py-2 bg-red-500 text-white rounded"
              >
                Remove
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-pitfall"
            phx-target={@myself}
            class="mt-2 px-4 py-2 bg-blue-500 text-white rounded"
          >
            Add Pitfall
          </button>
        </fieldset>

        <!-- Out of Scope (simple string array) -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Out of Scope</legend>
          <%= for {item, index} <- Enum.with_index(Ecto.Changeset.get_field(@changeset, :out_of_scope) || []) do %>
            <div class="flex gap-2 mb-2">
              <input
                type="text"
                name="task[out_of_scope][]"
                value={item}
                placeholder="Out of scope item"
                class="flex-1"
              />
              <button
                type="button"
                phx-click="remove-out-of-scope"
                phx-value-index={index}
                phx-target={@myself}
                class="px-3 py-2 bg-red-500 text-white rounded"
              >
                Remove
              </button>
            </div>
          <% end %>
          <button
            type="button"
            phx-click="add-out-of-scope"
            phx-target={@myself}
            class="mt-2 px-4 py-2 bg-blue-500 text-white rounded"
          >
            Add Out of Scope Item
          </button>
        </fieldset>

        <!-- Status & Agent Tracking -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Status & Agent Tracking</legend>
          <.input
            field={@changeset[:status]}
            type="select"
            label="Status"
            options={[{"Open", "open"}, {"In Progress", "in_progress"}, {"Completed", "completed"}, {"Blocked", "blocked"}]}
          />
          <.input field={@changeset[:created_by_agent]} type="text" label="Created By Agent" />
          <.input field={@changeset[:completed_by_agent]} type="text" label="Completed By Agent" />
          <.input field={@changeset[:completion_summary]} type="textarea" label="Completion Summary" />
        </fieldset>

        <!-- Review Queue -->
        <fieldset class="border border-gray-300 rounded p-4 mt-4">
          <legend class="text-lg font-semibold px-2">Review Queue</legend>
          <.input field={@changeset[:needs_review]} type="checkbox" label="Needs Review" />
          <.input
            field={@changeset[:review_status]}
            type="select"
            label="Review Status"
            options={[{"Pending", "pending"}, {"Approved", "approved"}, {"Changes Requested", "changes_requested"}, {"Rejected", "rejected"}]}
            prompt="Select status"
          />
          <.input field={@changeset[:review_notes]} type="textarea" label="Review Notes" />
        </fieldset>

        <:actions>
          <.button phx-disable-with="Saving...">Save Task</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
```

**Tasks Context Helper:**
```elixir
defmodule Kanban.Tasks do
  # ... existing functions ...

  def change_task(%Task{} = task, attrs \\ %{}) do
    Task.changeset(task, attrs)
  end
end
```

**Schema Changeset (Update):**
```elixir
defmodule Kanban.Schemas.Task do
  # ... existing schema ...

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title, :description, :acceptance_criteria, :position, :type, :priority,
      :complexity, :estimated_files, :why, :what, :where_context,
      :patterns_to_follow, :database_changes, :validation_rules,
      :telemetry_event, :metrics_to_track, :logging_requirements,
      :error_user_message, :error_on_failure,
      :technology_requirements, :pitfalls, :out_of_scope,
      :created_by_agent, :completed_at, :completed_by_agent, :completion_summary,
      :dependencies, :status, :claimed_at, :claim_expires_at,
      :required_capabilities, :actual_complexity, :actual_files_changed,
      :time_spent_minutes, :needs_review, :review_status, :review_notes
    ])
    |> validate_required([:title, :position, :type, :priority, :status])
    |> validate_inclusion(:type, [:work, :defect])
    |> validate_inclusion(:priority, [:low, :medium, :high, :critical])
    |> validate_inclusion(:complexity, [:small, :medium, :large])
    |> validate_inclusion(:status, [:open, :in_progress, :completed, :blocked])
    |> validate_inclusion(:actual_complexity, [:small, :medium, :large])
    |> validate_inclusion(:review_status, [:pending, :approved, :changes_requested, :rejected])
    |> cast_embed(:key_files)
    |> cast_embed(:verification_steps)
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :ui, :task_form_submitted]`
- [ ] Telemetry event: `[:kanban, :ui, :task_form_validation_failed]`
- [ ] Metrics: Counter of task creations via UI
- [ ] Logging: None (UI interaction)

## Error Handling

- User sees: Real-time validation errors below fields
- User sees: Summary of errors at top of form
- On failure: Form remains open with error state
- Validation: All validations from Task.changeset/2

## Common Pitfalls

- [ ] Don't forget to handle nested association deletion (mark for deletion)
- [ ] Remember to set position field when adding items
- [ ] Avoid losing form state on validation errors
- [ ] Don't forget to preload associations when editing
- [ ] Remember to handle empty arrays vs nil for associations
- [ ] Avoid N+1 queries when loading available tasks for dependencies
- [ ] Don't forget to broadcast PubSub event after create/update
- [ ] Remember responsive design - long forms need good mobile UX

## Dependencies

**Requires:** 08-display-rich-task-details.md
**Blocks:** 11-add-field-visibility-toggles.md

## Out of Scope

- Don't implement task templates
- Don't add AI-assisted field suggestions
- Don't implement collaborative editing (multiple users)
- Don't add rich text editor for description
- Future enhancement: Add task templates (e.g., "Bug Fix", "Feature", "Refactor")
- Future enhancement: Add AI autofill for common patterns
