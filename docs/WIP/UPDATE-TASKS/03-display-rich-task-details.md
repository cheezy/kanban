# Display Rich Task Details in UI

**Complexity:** Medium | **Est. Files:** 4-5

## Description

**WHY:** Users need to see all the rich task information (complexity, key files, verification steps, dependencies, etc.) that AI agents and users are creating. Current UI only shows title and description.

**WHAT:** Update task detail modal/page to display all 18 TASKS.md categories in an organized, readable format. Show key files as links, verification steps as checklists, dependencies as task links, and observability requirements clearly.

**WHERE:** LiveView task detail component, HEEx templates

## Acceptance Criteria

- [ ] Task detail view shows all rich fields
- [ ] Key files displayed as clickable file paths
- [ ] Verification steps shown as checklist
- [ ] Dependencies shown as links to other tasks
- [ ] Pitfalls and out-of-scope items clearly marked
- [ ] Complexity and estimated files prominently displayed
- [ ] Observability section shows telemetry/metrics/logging
- [ ] Completion summary displayed for completed tasks
- [ ] All fields handle nil/empty values gracefully
- [ ] UI is responsive and well-organized

## Key Files to Read First

- [lib/kanban_web/live/board_live.ex](lib/kanban_web/live/board_live.ex) - Main board LiveView
- [lib/kanban_web/live/board_live.html.heex](lib/kanban_web/live/board_live.html.heex) - Board template
- [lib/kanban_web/components/core_components.ex](lib/kanban_web/components/core_components.ex) - Existing component patterns
- [assets/css/app.css](assets/css/app.css) - Styling patterns
- [docs/WIP/TASKS.md](docs/WIP/TASKS.md) - Reference for all fields to display

## Technical Notes

**Patterns to Follow:**
- Use Phoenix LiveView for real-time updates
- Create reusable components for sections
- Follow existing Tailwind CSS patterns in the app
- Use core_components for consistent UI elements
- Handle nil values with safe navigation

**Database/Schema:**
- Tables: tasks (read all rich fields)
- Migrations needed: No
- Preload: [:key_files, :verification_steps, :pitfalls, :out_of_scope]

**UI Sections to Display:**
1. **Header**: Title, complexity badge, estimated files
2. **Context**: Why, What, Where
3. **Key Files**: File paths with notes
4. **Verification**: Commands and manual steps
5. **Technical Notes**: Patterns, database changes
6. **Observability**: Telemetry, metrics, logging
7. **Error Handling**: User messages, failure behavior
8. **Dependencies**: Links to blocking/blocked tasks
9. **Pitfalls**: Common mistakes to avoid
10. **Out of Scope**: What not to do
11. **Completion**: Summary if task completed

**Integration Points:**
- [ ] PubSub broadcasts: Subscribe to task updates
- [ ] Phoenix Channels: Real-time updates when task changes
- [ ] External APIs: None

## Verification

**Commands to Run:**
```bash
# Run tests
mix test test/kanban_web/live/board_live_test.exs

# Start server and test manually
mix phx.server
# Navigate to http://localhost:4000
# Click on a task to view details

# Create rich task in console for testing
iex -S mix
alias Kanban.{Repo, Tasks}

{:ok, task} = Tasks.create_task(%{
  title: "Add user authentication",
  complexity: "large",
  estimated_files: "5+",
  why: "Users need to securely access their boards",
  what: "Implement email/password authentication with sessions",
  where_context: "Login page and user menu",
  patterns_to_follow: "Use Phoenix.Token for session management",
  database_changes: "Add users table with email, hashed_password",
  pubsub_required: true,
  channels_required: false,
  telemetry_event: "[:kanban, :auth, :login]",
  metrics_to_track: "Count of login attempts, success rate",
  logging_requirements: "Log login attempts with IP",
  error_user_message: "Invalid email or password",
  error_on_failure: "Show error message, clear password field",
  validation_rules: "Email format, password min 8 chars",
  migration_needed: true,
  breaking_change: false,
  key_files: [
    %{file_path: "lib/kanban_web/controllers/session_controller.ex", note: "Handle login/logout", position: 1},
    %{file_path: "lib/kanban/accounts.ex", note: "User authentication context", position: 2}
  ],
  verification_steps: [
    %{step_type: "command", step_text: "mix test test/kanban/accounts_test.exs", position: 1},
    %{step_type: "manual", step_text: "Try logging in with valid credentials", expected_result: "Redirected to dashboard", position: 2}
  ],
  pitfalls: [
    %{pitfall_text: "Don't store passwords in plain text", position: 1},
    %{pitfall_text: "Remember to handle session timeout", position: 2}
  ],
  out_of_scope: [
    %{item_text: "OAuth/social login", position: 1},
    %{item_text: "Multi-factor authentication", position: 2}
  ],
  status: "open"
})

# Run precommit
mix precommit
```

**Manual Testing:**
1. Create task with all rich fields via iex
2. Open board in browser
3. Click on task to view details
4. Verify all sections display correctly
5. Check nil handling - create task with minimal fields
6. Click on dependency links - verify navigation
7. Test responsive layout on mobile
8. Update task fields - verify real-time update
9. Complete task - verify completion summary shows
10. Check accessibility (screen reader, keyboard nav)

**Success Looks Like:**
- All task fields visible in organized layout
- Sections collapsible or well-spaced
- Dependencies clickable
- Complexity shown with visual badge
- Verification steps formatted as checklist
- Completion summary prominent for done tasks
- No layout breaks with long text
- Real-time updates work
- Accessible and responsive

## Data Examples

**LiveView Component:**
```elixir
defmodule KanbanWeb.TaskDetailComponent do
  use KanbanWeb, :live_component
  alias Kanban.Tasks

  @impl true
  def update(%{id: task_id}, socket) do
    task = Tasks.get_task!(task_id)

    {:ok,
     socket
     |> assign(:task, task)
     |> assign(:show_completion, not is_nil(task.completed_at))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="task-detail-modal">
      <.modal id="task-detail-modal" show={true}>
        <!-- Header -->
        <div class="mb-4">
          <div class="flex items-center justify-between">
            <h2 class="text-2xl font-bold"><%= @task.title %></h2>
            <div class="flex gap-2">
              <.badge :if={@task.complexity} color={complexity_color(@task.complexity)}>
                <%= @task.complexity %>
              </.badge>
              <.badge :if={@task.estimated_files} color="gray">
                <%= @task.estimated_files %> files
              </.badge>
            </div>
          </div>
        </div>

        <!-- Context Section -->
        <.section :if={@task.why || @task.what || @task.where_context} title="Context">
          <.field :if={@task.why} label="Why" value={@task.why} />
          <.field :if={@task.what} label="What" value={@task.what} />
          <.field :if={@task.where_context} label="Where" value={@task.where_context} />
        </.section>

        <!-- Key Files -->
        <.section :if={length(@task.key_files) > 0} title="Key Files">
          <ul class="space-y-2">
            <%= for file <- Enum.sort_by(@task.key_files, & &1.position) do %>
              <li class="flex items-start">
                <code class="text-sm bg-gray-100 px-2 py-1 rounded">
                  <%= file.file_path %>
                </code>
                <span :if={file.note} class="ml-2 text-sm text-gray-600">
                  - <%= file.note %>
                </span>
              </li>
            <% end %>
          </ul>
        </.section>

        <!-- Verification Steps -->
        <.section :if={length(@task.verification_steps) > 0} title="Verification">
          <ul class="space-y-2">
            <%= for step <- Enum.sort_by(@task.verification_steps, & &1.position) do %>
              <li class="flex items-start">
                <.icon name={step_icon(step.step_type)} class="w-5 h-5 mr-2" />
                <div class="flex-1">
                  <div class="font-mono text-sm"><%= step.step_text %></div>
                  <div :if={step.expected_result} class="text-sm text-gray-600 mt-1">
                    Expected: <%= step.expected_result %>
                  </div>
                </div>
              </li>
            <% end %>
          </ul>
        </.section>

        <!-- Technical Notes -->
        <.section :if={@task.patterns_to_follow || @task.database_changes} title="Technical Notes">
          <.field :if={@task.patterns_to_follow} label="Patterns to Follow" value={@task.patterns_to_follow} />
          <.field :if={@task.database_changes} label="Database Changes" value={@task.database_changes} />
        </.section>

        <!-- Observability -->
        <.section :if={@task.telemetry_event || @task.metrics_to_track || @task.logging_requirements}
                  title="Observability">
          <.field :if={@task.telemetry_event} label="Telemetry Event">
            <code class="text-sm"><%= @task.telemetry_event %></code>
          </.field>
          <.field :if={@task.metrics_to_track} label="Metrics" value={@task.metrics_to_track} />
          <.field :if={@task.logging_requirements} label="Logging" value={@task.logging_requirements} />
        </.section>

        <!-- Error Handling -->
        <.section :if={@task.error_user_message || @task.error_on_failure} title="Error Handling">
          <.field :if={@task.error_user_message} label="User Message" value={@task.error_user_message} />
          <.field :if={@task.error_on_failure} label="On Failure" value={@task.error_on_failure} />
        </.section>

        <!-- Dependencies -->
        <.section :if={@task.dependencies && length(@task.dependencies) > 0} title="Dependencies">
          <p class="text-sm text-gray-600 mb-2">This task depends on:</p>
          <.dependency_list task_ids={@task.dependencies} />
        </.section>

        <!-- Pitfalls -->
        <.section :if={length(@task.pitfalls) > 0} title="Common Pitfalls">
          <ul class="space-y-1">
            <%= for pitfall <- Enum.sort_by(@task.pitfalls, & &1.position) do %>
              <li class="flex items-start">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5 mr-2 text-yellow-500" />
                <span class="text-sm"><%= pitfall.pitfall_text %></span>
              </li>
            <% end %>
          </ul>
        </.section>

        <!-- Out of Scope -->
        <.section :if={length(@task.out_of_scope) > 0} title="Out of Scope">
          <ul class="space-y-1">
            <%= for item <- Enum.sort_by(@task.out_of_scope, & &1.position) do %>
              <li class="flex items-start">
                <.icon name="hero-x-circle" class="w-5 h-5 mr-2 text-red-500" />
                <span class="text-sm"><%= item.item_text %></span>
              </li>
            <% end %>
          </ul>
        </.section>

        <!-- Completion Summary -->
        <.section :if={@show_completion} title="Completion Summary" class="bg-green-50 p-4 rounded">
          <.field label="Completed By" value={@task.completed_by} />
          <.field label="Completed At" value={format_datetime(@task.completed_at)} />

          <div :if={@task.completion_summary} class="mt-4">
            <h4 class="font-semibold mb-2">Files Changed</h4>
            <ul class="space-y-1">
              <%= for file <- @task.completion_summary["files_changed"] || [] do %>
                <li class="text-sm">
                  <code><%= file["path"] %></code> - <%= file["changes"] %>
                </li>
              <% end %>
            </ul>

            <h4 class="font-semibold mt-4 mb-2">Verification Results</h4>
            <div class="text-sm">
              <.badge color={result_color(@task.completion_summary["verification_results"]["status"])}>
                <%= @task.completion_summary["verification_results"]["status"] %>
              </.badge>
            </div>
          </div>
        </.section>
      </.modal>
    </div>
    """
  end

  defp section(assigns) do
    ~H"""
    <div class={["mb-6", @class]}>
      <h3 class="text-lg font-semibold mb-3"><%= @title %></h3>
      <div class="pl-2">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  defp field(assigns) do
    ~H"""
    <div class="mb-2">
      <dt class="text-sm font-medium text-gray-600"><%= @label %></dt>
      <dd class="text-sm mt-1">
        <%= if assigns[:value] do %>
          <%= @value %>
        <% else %>
          <%= render_slot(@inner_block) %>
        <% end %>
      </dd>
    </div>
    """
  end

  defp badge(assigns) do
    assigns = assign_new(assigns, :color, fn -> "blue" end)

    ~H"""
    <span class={["inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                   badge_color_class(@color)]}>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  defp complexity_color("small"), do: "green"
  defp complexity_color("medium"), do: "yellow"
  defp complexity_color("large"), do: "red"
  defp complexity_color(_), do: "gray"

  defp step_icon("command"), do: "hero-command-line"
  defp step_icon("manual"), do: "hero-hand-raised"
  defp step_icon(_), do: "hero-check-circle"

  defp result_color("passed"), do: "green"
  defp result_color("failed"), do: "red"
  defp result_color(_), do: "gray"

  defp badge_color_class("green"), do: "bg-green-100 text-green-800"
  defp badge_color_class("yellow"), do: "bg-yellow-100 text-yellow-800"
  defp badge_color_class("red"), do: "bg-red-100 text-red-800"
  defp badge_color_class("blue"), do: "bg-blue-100 text-blue-800"
  defp badge_color_class(_), do: "bg-gray-100 text-gray-800"

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end
end
```

**Dependency List Component:**
```elixir
defmodule KanbanWeb.DependencyListComponent do
  use KanbanWeb, :live_component
  alias Kanban.Tasks

  @impl true
  def update(%{task_ids: task_ids}, socket) do
    tasks = Enum.map(task_ids, &Tasks.get_task!/1)

    {:ok, assign(socket, :tasks, tasks)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ul class="space-y-2">
      <%= for task <- @tasks do %>
        <li>
          <a href="#" phx-click="show-task-detail" phx-value-id={task.id}
             class="text-blue-600 hover:underline flex items-center">
            <.icon name="hero-arrow-right" class="w-4 h-4 mr-1" />
            <%= task.title %>
            <.badge :if={task.status == "completed"} color="green" class="ml-2">
              Done
            </.badge>
            <.badge :if={task.status == "blocked"} color="red" class="ml-2">
              Blocked
            </.badge>
          </a>
        </li>
      <% end %>
    </ul>
    """
  end
end
```

## Observability

- [ ] Telemetry event: `[:kanban, :ui, :task_detail_viewed]`
- [ ] Metrics: Counter of task detail views
- [ ] Logging: None (UI interaction, no logging needed)

## Error Handling

- User sees: Graceful fallback if task data missing
- On failure: Show error message if task not found
- Validation: Handle nil/empty values for all optional fields

## Common Pitfalls

- [ ] Don't forget to preload all associations (key_files, verification_steps, etc.)
- [ ] Remember to handle nil values gracefully (use :if conditions)
- [ ] Avoid rendering empty sections (check length/nil before displaying)
- [ ] Don't forget to sort by position field for ordered lists
- [ ] Remember to make dependency links clickable
- [ ] Avoid layout breaks with long file paths (use text truncation/wrapping)
- [ ] Don't forget responsive design for mobile
- [ ] Remember accessibility (proper headings, labels, ARIA)

## Dependencies

**Requires:** 02-add-task-metadata-fields.md
**Blocks:** 09-add-task-creation-form.md

## Out of Scope

- Don't implement inline editing of task fields (separate feature)
- Don't add task activity history/timeline
- Don't implement task comments/discussions
- Don't add file preview/syntax highlighting
- Future enhancement: Add drag-and-drop to reorder key files/verification steps
- Future enhancement: Add copy-to-clipboard for verification commands
