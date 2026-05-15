defmodule KanbanWeb.TaskLive.ViewComponent do
  use KanbanWeb, :live_component

  import KanbanWeb.TaskLive.Components.ActualVsEstimatedSection
  import KanbanWeb.TaskLive.Components.ChecklistSection
  import KanbanWeb.TaskLive.Components.ChildTasksSection
  import KanbanWeb.TaskLive.Components.CommentsSection
  import KanbanWeb.TaskLive.Components.CompletionSection
  import KanbanWeb.TaskLive.Components.DependenciesSection
  import KanbanWeb.TaskLive.Components.IntegrationPointsSection
  import KanbanWeb.TaskLive.Components.ReviewStatusSection
  import KanbanWeb.TaskLive.Components.WorkflowStepsSection

  alias Kanban.Tasks
  alias KanbanWeb.AcceptanceChecklist
  alias KanbanWeb.TaskActivityLog
  alias KanbanWeb.TaskDetailHeader
  alias KanbanWeb.TaskMetadataGrid

  @impl true
  def update(%{task_id: task_id} = assigns, socket) do
    expected_board_id = Map.get(assigns, :board_id)
    task = load_task_for_board(task_id, expected_board_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:task, task)
     |> assign(:board_id, expected_board_id)
     |> assign(:ai_optimized_board, Map.get(assigns, :ai_optimized_board, false))
     |> assign(:can_modify, Map.get(assigns, :can_modify, false))
     |> assign(:field_visibility, Map.get(assigns, :field_visibility, %{}))}
  end

  # Defense-in-depth: even if a caller forgets to scope the task lookup at the
  # parent LiveView, the component must not render a task that doesn't belong
  # to the supplied board_id. When no board_id is given (legacy callers), fall
  # back to the unscoped lookup — but callers SHOULD always pass one.
  defp load_task_for_board(task_id, nil), do: Tasks.get_task_for_view(task_id)

  defp load_task_for_board(task_id, board_id) do
    case Tasks.get_task_for_view(task_id) do
      nil ->
        nil

      %{column: %{board_id: ^board_id}} = task ->
        task

      _other_board ->
        nil
    end
  end

  # Used inside the inline ~H render block; analyzer regex misses predicate `?` callers.
  defp field_visible?(field_visibility, field_name) do
    Map.get(field_visibility, field_name, false)
  end

  defp board_name_for(%{column: %{board: %{name: name}}}) when is_binary(name), do: name
  defp board_name_for(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= if @task == nil do %>
        <div class="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
          <.icon name="hero-exclamation-triangle" class="w-12 h-12 text-red-600 mx-auto mb-4" />
          <h3 class="text-xl font-semibold text-red-900 mb-2">
            {gettext("Task Not Found")}
          </h3>
          <p class="text-red-700">
            {gettext("This task may have been deleted or you may not have permission to view it.")}
          </p>
        </div>
      <% else %>
        <div class="stride-screen">
          <TaskDetailHeader.detail_header task={@task} variant={:pane} />
          <div
            :if={@can_modify && @board_id}
            style="display: flex; justify-content: flex-end; padding: 6px 22px 0;"
          >
            <.link
              patch={~p"/boards/#{@board_id}/tasks/#{@task}/edit"}
              class="text-blue-600 hover:text-blue-800 flex items-center gap-1"
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
              <span class="text-sm font-medium">{gettext("Edit")}</span>
            </.link>
          </div>
        </div>

        <div class="stride-screen">
          <TaskMetadataGrid.metadata_grid
            task={@task}
            parent_goal={Map.get(@task, :parent)}
            board_name={board_name_for(@task)}
          />
        </div>

        <%= if @task.human_task || @task.estimated_files do %>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">
                {gettext("Human Task")}
              </h4>
              <p class="text-base-content">
                <%= if @task.human_task do %>
                  {gettext("Yes")}
                <% else %>
                  {gettext("No")}
                <% end %>
              </p>
            </div>

            <%= if @task.estimated_files do %>
              <div>
                <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">
                  {gettext("Estimated Files")}
                </h4>
                <p class="text-base-content">{@task.estimated_files}</p>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if @task.created_by || @task.created_by_agent do %>
          <div class="bg-base-200 rounded-lg p-4">
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Creator Info")}
            </h4>
            <div class="space-y-2">
              <%= if @task.created_by do %>
                <p class="text-base-content">
                  <span class="font-semibold">{gettext("Created by")}:</span>
                  {@task.created_by.name || @task.created_by.email}
                </p>
              <% end %>
              <%= if @task.created_by_agent do %>
                <p class="text-base-content">
                  <span class="font-semibold">{gettext("Agent")}:</span>
                  {@task.created_by_agent}
                </p>
              <% end %>
              <%= if @task.claimed_at do %>
                <p class="text-base-content">
                  <span class="font-semibold">{gettext("Claimed at")}:</span>
                  {Calendar.strftime(@task.claimed_at, "%B %d, %Y at %I:%M %p")}
                </p>
                <%= if @task.claim_expires_at do %>
                  <p class="text-base-content">
                    <span class="font-semibold">{gettext("Claim expires")}:</span>
                    {Calendar.strftime(@task.claim_expires_at, "%B %d, %Y at %I:%M %p")}
                  </p>
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if (@task.why || @task.what || @task.where_context) && field_visible?(@field_visibility, "context") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Context")}
            </h4>
            <div class="space-y-3">
              <%= if @task.why do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Why")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.why}</p>
                </div>
              <% end %>
              <%= if @task.what do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("What")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.what}</p>
                </div>
              <% end %>
              <%= if @task.where_context do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Where")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.where_context}</p>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @task.description do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">
              {gettext("Description")}
            </h4>
            <p class="text-base-content whitespace-pre-wrap">{@task.description}</p>
          </div>
        <% end %>

        <%= if @task.acceptance_criteria && field_visible?(@field_visibility, "acceptance_criteria") do %>
          <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@task.acceptance_criteria} />
        <% end %>

        <%= if @task.key_files && !Enum.empty?(@task.key_files) && field_visible?(@field_visibility, "key_files") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Key Files")}
            </h4>
            <div class="space-y-2">
              <%= for key_file <- @task.key_files do %>
                <div class="bg-base-200 rounded p-3">
                  <p class="font-mono text-sm text-base-content">{key_file.file_path}</p>
                  <%= if key_file.note do %>
                    <p class="text-sm text-base-content opacity-70 mt-1">{key_file.note}</p>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @task.verification_steps && !Enum.empty?(@task.verification_steps) && field_visible?(@field_visibility, "verification_steps") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Verification Steps")}
            </h4>
            <div class="space-y-2">
              <%= for step <- @task.verification_steps do %>
                <div class="bg-base-200 rounded p-3">
                  <div class="flex items-center gap-2 mb-1">
                    <span class={[
                      "px-2 py-0.5 text-xs font-semibold rounded",
                      if step.step_type == "command" do
                        "bg-blue-100 text-blue-800"
                      else
                        "bg-purple-100 text-purple-800"
                      end
                    ]}>
                      {step.step_type}
                    </span>
                  </div>
                  <p class={[
                    "text-sm text-base-content",
                    if(step.step_type == "command", do: "font-mono bg-base-300 rounded px-2 py-1")
                  ]}>
                    {step.step_text}
                  </p>
                  <%= if step.expected_result do %>
                    <p class="text-xs text-base-content opacity-60 mt-2">
                      <span class="font-semibold">{gettext("Expected")}:</span> {step.expected_result}
                    </p>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if (@task.patterns_to_follow || @task.database_changes || @task.validation_rules) && field_visible?(@field_visibility, "technical_notes") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Implementation Guidance")}
            </h4>
            <div class="space-y-3">
              <%= if @task.patterns_to_follow do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Patterns to Follow")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.patterns_to_follow}</p>
                </div>
              <% end %>
              <%= if @task.database_changes do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Database Changes")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.database_changes}</p>
                </div>
              <% end %>
              <%= if @task.validation_rules do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Validation Rules")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.validation_rules}</p>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if (@task.telemetry_event || @task.metrics_to_track || @task.logging_requirements) && field_visible?(@field_visibility, "observability") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Observability")}
            </h4>
            <div class="space-y-3">
              <%= if @task.telemetry_event do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Telemetry Event")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.telemetry_event}</p>
                </div>
              <% end %>
              <%= if @task.metrics_to_track do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Metrics to Track")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.metrics_to_track}</p>
                </div>
              <% end %>
              <%= if @task.logging_requirements do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("Logging Requirements")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.logging_requirements}</p>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if (@task.error_user_message || @task.error_on_failure) && field_visible?(@field_visibility, "error_handling") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Error Handling")}
            </h4>
            <div class="space-y-3">
              <%= if @task.error_user_message do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("User Message")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.error_user_message}</p>
                </div>
              <% end %>
              <%= if @task.error_on_failure do %>
                <div>
                  <p class="text-xs font-semibold text-base-content opacity-60 mb-1">
                    {gettext("On Failure")}
                  </p>
                  <p class="text-base-content whitespace-pre-wrap">{@task.error_on_failure}</p>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @task.technology_requirements && !Enum.empty?(@task.technology_requirements) && field_visible?(@field_visibility, "technology_requirements") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Technology Requirements")}
            </h4>
            <ul class="list-disc list-inside space-y-1">
              <%= for tech <- @task.technology_requirements do %>
                <li class="text-base-content">{tech}</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <%= if @task.required_capabilities && !Enum.empty?(@task.required_capabilities) && field_visible?(@field_visibility, "required_capabilities") do %>
          <div>
            <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
              {gettext("Required Agent Capabilities")}
            </h4>
            <ul class="list-disc list-inside space-y-1">
              <%= for capability <- @task.required_capabilities do %>
                <li class="text-base-content">{capability}</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <%= if @task.dependencies && !Enum.empty?(@task.dependencies) do %>
          <.dependencies_section dependencies={@task.dependencies} />
        <% end %>

        <%= if @task.pitfalls && !Enum.empty?(@task.pitfalls) && field_visible?(@field_visibility, "pitfalls") do %>
          <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 dark:bg-yellow-900/20 dark:border-yellow-700/50">
            <h4 class="text-sm font-semibold text-yellow-900 mb-2 dark:text-yellow-200">
              {gettext("Pitfalls to Avoid")}
            </h4>
            <ul class="list-disc list-inside space-y-1">
              <%= for pitfall <- @task.pitfalls do %>
                <li class="text-yellow-900 dark:text-yellow-200">{pitfall}</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <%= if @task.out_of_scope && !Enum.empty?(@task.out_of_scope) && field_visible?(@field_visibility, "out_of_scope") do %>
          <div class="bg-red-50 border border-red-200 rounded-lg p-4">
            <h4 class="text-sm font-semibold text-red-900 mb-2">{gettext("Out of Scope")}</h4>
            <ul class="list-disc list-inside space-y-1">
              <%= for item <- @task.out_of_scope do %>
                <li class="text-red-900">{item}</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <%= if @task.security_considerations && !Enum.empty?(@task.security_considerations) && field_visible?(@field_visibility, "security_considerations") do %>
          <div class="bg-purple-50 border border-purple-200 rounded-lg p-4">
            <h4 class="text-sm font-semibold text-purple-900 mb-2">
              {gettext("Security Considerations")}
            </h4>
            <ul class="list-disc list-inside space-y-1">
              <%= for item <- @task.security_considerations do %>
                <li class="text-purple-900">{item}</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <%= if @task.testing_strategy && map_size(@task.testing_strategy) > 0 && field_visible?(@field_visibility, "testing_strategy") do %>
          <.checklist_section testing_strategy={@task.testing_strategy} />
        <% end %>

        <%= if @task.integration_points && map_size(@task.integration_points) > 0 && field_visible?(@field_visibility, "integration_points") do %>
          <.integration_points_section integration_points={@task.integration_points} />
        <% end %>

        <%= if @task.status == :completed && (@task.actual_complexity || @task.actual_files_changed || @task.time_spent_minutes) do %>
          <.actual_vs_estimated_section task={@task} />
        <% end %>

        <%= if @task.needs_review && @task.review_status do %>
          <.review_status_section task={@task} />
        <% end %>

        <%= if @task.review_report && @task.review_report != "" do %>
          <div class="bg-blue-50 border border-blue-200 rounded-lg p-4 dark:bg-blue-900/20 dark:border-blue-700/50">
            <h4 class="text-sm font-semibold text-blue-900 dark:text-blue-200 mb-2">
              {gettext("Review Report")}
            </h4>
            <div class="text-blue-900 dark:text-blue-100 whitespace-pre-wrap text-sm max-h-96 overflow-y-auto">
              {@task.review_report}
            </div>
          </div>
        <% end %>

        <%= if @task.workflow_steps && @task.workflow_steps != [] do %>
          <.workflow_steps_section steps={@task.workflow_steps} />
        <% end %>

        <%= if @task.status == :completed && (@task.completed_at || @task.completed_by || @task.completed_by_agent || @task.completion_summary) do %>
          <.completion_section task={@task} />
        <% end %>

        <%= if @task.type == :goal && length(@task.children || []) > 0 do %>
          <.child_tasks_section children={@task.children} />
        <% end %>

        <TaskActivityLog.activity_log histories={@task.task_histories} />

        <.comments_section comments={@task.comments} />
      <% end %>
    </div>
    """
  end
end
