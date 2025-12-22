defmodule KanbanWeb.TaskLive.ViewComponent do
  use KanbanWeb, :live_component

  alias Kanban.Tasks

  @impl true
  def update(%{task_id: task_id} = assigns, socket) do
    task = Tasks.get_task_for_view!(task_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:task, task)
     |> assign(:board_id, Map.get(assigns, :board_id))
     |> assign(:can_modify, Map.get(assigns, :can_modify, false))
     |> assign(:field_visibility, Map.get(assigns, :field_visibility, %{}))}
  end

  defp field_visible?(field_visibility, field_name) do
    Map.get(field_visibility, field_name, false)
  end

  defp status_badge_class(:open), do: "bg-gray-100 text-gray-800"
  defp status_badge_class(:in_progress), do: "bg-blue-100 text-blue-800"
  defp status_badge_class(:completed), do: "bg-green-100 text-green-800"
  defp status_badge_class(:blocked), do: "bg-red-100 text-red-800"
  defp status_badge_class(_), do: "bg-gray-100 text-gray-800"

  defp status_label(:open), do: gettext("Open")
  defp status_label(:in_progress), do: gettext("In Progress")
  defp status_label(:completed), do: gettext("Completed")
  defp status_label(:blocked), do: gettext("Blocked")
  defp status_label(_), do: gettext("Unknown")

  defp review_status_badge_class(:pending),
    do: "px-2 py-1 text-xs rounded bg-yellow-100 text-yellow-800"

  defp review_status_badge_class(:approved),
    do: "px-2 py-1 text-xs rounded bg-green-100 text-green-800"

  defp review_status_badge_class(:changes_requested),
    do: "px-2 py-1 text-xs rounded bg-orange-100 text-orange-800"

  defp review_status_badge_class(:rejected),
    do: "px-2 py-1 text-xs rounded bg-red-100 text-red-800"

  defp review_status_badge_class(_), do: "px-2 py-1 text-xs rounded bg-gray-100 text-gray-800"

  defp review_status_label(:pending), do: gettext("Pending")
  defp review_status_label(:approved), do: gettext("Approved")
  defp review_status_label(:changes_requested), do: gettext("Changes Requested")
  defp review_status_label(:rejected), do: gettext("Rejected")
  defp review_status_label(_), do: gettext("Unknown")

  defp review_section_class(:pending), do: "bg-yellow-50 border border-yellow-200 rounded-lg p-4"
  defp review_section_class(:approved), do: "bg-green-50 border border-green-200 rounded-lg p-4"

  defp review_section_class(:changes_requested),
    do: "bg-orange-50 border border-orange-200 rounded-lg p-4"

  defp review_section_class(:rejected), do: "bg-red-50 border border-red-200 rounded-lg p-4"
  defp review_section_class(_), do: "bg-gray-50 border border-gray-200 rounded-lg p-4"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="border-b border-base-300 pb-4">
        <div class="flex items-start justify-between mb-2">
          <div class="flex items-center gap-3 flex-wrap">
            <h2 class="text-2xl font-bold text-base-content">{@task.identifier}</h2>
            <span class={[
              "px-3 py-1 text-xs font-semibold rounded-full",
              case @task.type do
                :work -> "bg-blue-100 text-blue-800"
                :defect -> "bg-red-100 text-red-800"
              end
            ]}>
              {case @task.type do
                :work -> gettext("Work")
                :defect -> gettext("Defect")
              end}
            </span>
            <%= if @task.complexity && field_visible?(@field_visibility, "complexity") do %>
              <span class={[
                "px-3 py-1 text-xs font-semibold rounded-full",
                case @task.complexity do
                  :small -> "bg-green-100 text-green-800"
                  :medium -> "bg-yellow-100 text-yellow-800"
                  :large -> "bg-red-100 text-red-800"
                end
              ]}>
                {case @task.complexity do
                  :small -> gettext("Small")
                  :medium -> gettext("Medium")
                  :large -> gettext("Large")
                end}
              </span>
            <% end %>
            <%= if @task.status do %>
              <span class={[
                "px-3 py-1 text-xs font-semibold rounded-full",
                status_badge_class(@task.status)
              ]}>
                {status_label(@task.status)}
              </span>
            <% end %>
          </div>
          <%= if @can_modify && @board_id do %>
            <.link
              patch={~p"/boards/#{@board_id}/tasks/#{@task}/edit"}
              class="text-blue-600 hover:text-blue-800 flex items-center gap-1"
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
              <span class="text-sm font-medium">{gettext("Edit")}</span>
            </.link>
          <% end %>
        </div>
        <h3 class="text-xl text-base-content">{@task.title}</h3>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div>
          <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">{gettext("Column")}</h4>
          <p class="text-base-content">{@task.column.name}</p>
        </div>

        <div>
          <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">
            {gettext("Priority")}
          </h4>
          <p class={[
            "font-semibold",
            case @task.priority do
              :low -> "text-blue-600"
              :medium -> "text-yellow-600"
              :high -> "text-orange-600"
              :critical -> "text-red-600"
            end
          ]}>
            {case @task.priority do
              :low -> gettext("Low")
              :medium -> gettext("Medium")
              :high -> gettext("High")
              :critical -> gettext("Critical")
            end}
          </p>
        </div>

        <div>
          <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">
            {gettext("Assigned To")}
          </h4>
          <p class="text-base-content">
            <%= if @task.assigned_to do %>
              {@task.assigned_to.name || @task.assigned_to.email}
            <% else %>
              {gettext("Unassigned")}
            <% end %>
          </p>
        </div>

        <div>
          <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">
            {gettext("Needs Review")}
          </h4>
          <p class="text-base-content">
            <%= if @task.needs_review do %>
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
        <div>
          <h4 class="text-sm font-semibold text-base-content opacity-80 mb-1">
            {gettext("Acceptance Criteria")}
          </h4>
          <p class="text-base-content whitespace-pre-wrap">{@task.acceptance_criteria}</p>
        </div>
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
        <div>
          <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
            {gettext("Dependencies")}
          </h4>
          <p class="text-base-content">
            {gettext("Depends on tasks")}: {Enum.join(@task.dependencies, ", ")}
          </p>
        </div>
      <% end %>

      <%= if @task.pitfalls && !Enum.empty?(@task.pitfalls) && field_visible?(@field_visibility, "pitfalls") do %>
        <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
          <h4 class="text-sm font-semibold text-yellow-900 mb-2">{gettext("Pitfalls to Avoid")}</h4>
          <ul class="list-disc list-inside space-y-1">
            <%= for pitfall <- @task.pitfalls do %>
              <li class="text-yellow-900">{pitfall}</li>
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

      <%= if @task.status == :completed && (@task.actual_complexity || @task.actual_files_changed || @task.time_spent_minutes) do %>
        <div class="bg-blue-50 border border-blue-200 rounded-lg p-4">
          <h4 class="text-sm font-semibold text-blue-900 mb-2">{gettext("Actual vs Estimated")}</h4>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <%= if @task.actual_complexity do %>
              <div>
                <p class="text-xs font-semibold text-blue-900 opacity-70">
                  {gettext("Actual Complexity")}
                </p>
                <p class="text-blue-900">
                  {case @task.actual_complexity do
                    :small -> gettext("Small")
                    :medium -> gettext("Medium")
                    :large -> gettext("Large")
                  end}
                  <%= if @task.complexity do %>
                    <span class="text-xs opacity-60">
                      ({gettext("Est")}: {case @task.complexity do
                        :small -> gettext("Small")
                        :medium -> gettext("Medium")
                        :large -> gettext("Large")
                      end})
                    </span>
                  <% end %>
                </p>
              </div>
            <% end %>
            <%= if @task.actual_files_changed do %>
              <div>
                <p class="text-xs font-semibold text-blue-900 opacity-70">
                  {gettext("Actual Files Changed")}
                </p>
                <p class="text-blue-900">
                  {@task.actual_files_changed}
                  <%= if @task.estimated_files do %>
                    <span class="text-xs opacity-60">
                      ({gettext("Est")}: {@task.estimated_files})
                    </span>
                  <% end %>
                </p>
              </div>
            <% end %>
            <%= if @task.time_spent_minutes do %>
              <div>
                <p class="text-xs font-semibold text-blue-900 opacity-70">{gettext("Time Spent")}</p>
                <p class="text-blue-900">{@task.time_spent_minutes} {gettext("minutes")}</p>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @task.needs_review && @task.review_status do %>
        <div class={review_section_class(@task.review_status)}>
          <h4 class="text-sm font-semibold mb-2">{gettext("Review Status")}</h4>
          <div class="space-y-2">
            <p>
              <span class="font-semibold">{gettext("Status")}:</span>
              <span class={review_status_badge_class(@task.review_status)}>
                {review_status_label(@task.review_status)}
              </span>
            </p>
            <%= if @task.reviewed_by do %>
              <p>
                <span class="font-semibold">{gettext("Reviewed by")}:</span>
                {@task.reviewed_by.name || @task.reviewed_by.email}
              </p>
            <% end %>
            <%= if @task.reviewed_at do %>
              <p>
                <span class="font-semibold">{gettext("Reviewed at")}:</span>
                {Calendar.strftime(@task.reviewed_at, "%B %d, %Y at %I:%M %p")}
              </p>
            <% end %>
            <%= if @task.review_notes do %>
              <div>
                <p class="font-semibold mb-1">{gettext("Review Notes")}:</p>
                <p class="whitespace-pre-wrap">{@task.review_notes}</p>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @task.status == :completed && (@task.completed_at || @task.completed_by || @task.completed_by_agent || @task.completion_summary) do %>
        <div class="bg-green-50 border border-green-200 rounded-lg p-4">
          <h4 class="text-sm font-semibold text-green-900 mb-2">{gettext("Completion")}</h4>
          <div class="space-y-2">
            <%= if @task.completed_at do %>
              <p class="text-green-900">
                <span class="font-semibold">{gettext("Completed at")}:</span>
                {Calendar.strftime(@task.completed_at, "%B %d, %Y at %I:%M %p")}
              </p>
            <% end %>
            <%= if @task.completed_by do %>
              <p class="text-green-900">
                <span class="font-semibold">{gettext("Completed by")}:</span>
                {@task.completed_by.name || @task.completed_by.email}
              </p>
            <% end %>
            <%= if @task.completed_by_agent do %>
              <p class="text-green-900">
                <span class="font-semibold">{gettext("Agent")}:</span>
                {@task.completed_by_agent}
              </p>
            <% end %>
            <%= if @task.completion_summary do %>
              <div>
                <p class="font-semibold text-green-900 mb-1">{gettext("Summary")}:</p>
                <p class="text-green-900 whitespace-pre-wrap">{@task.completion_summary}</p>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <div>
        <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">{gettext("History")}</h4>
        <%= if Enum.empty?(@task.task_histories) do %>
          <p class="text-base-content opacity-60 text-sm">{gettext("No history available")}</p>
        <% else %>
          <div class="space-y-3 max-h-48 overflow-y-auto">
            <%= for history <- @task.task_histories do %>
              <div class="flex items-start gap-2 text-sm">
                <div class="mt-0.5">
                  <%= case history.type do %>
                    <% :creation -> %>
                      <.icon name="hero-plus-circle" class="w-4 h-4 text-green-600" />
                    <% :move -> %>
                      <.icon name="hero-arrow-right-circle" class="w-4 h-4 text-blue-600" />
                    <% :priority_change -> %>
                      <.icon name="hero-exclamation-circle" class="w-4 h-4 text-orange-600" />
                    <% :assignment -> %>
                      <.icon name="hero-user-circle" class="w-4 h-4 text-purple-600" />
                  <% end %>
                </div>
                <div class="flex-1">
                  <p class="text-base-content">
                    <%= case history.type do %>
                      <% :creation -> %>
                        <span class="font-semibold">{gettext("Created")}</span>
                      <% :move -> %>
                        <span class="font-semibold">{gettext("Moved")}</span>
                        {gettext("from")}
                        <span class="font-semibold">{history.from_column}</span> {gettext("to")}
                        <span class="font-semibold">{history.to_column}</span>
                      <% :priority_change -> %>
                        <span class="font-semibold">{gettext("Priority changed")}</span>
                        {gettext("from")}
                        <span class="font-semibold">{history.from_priority}</span> {gettext("to")}
                        <span class="font-semibold">{history.to_priority}</span>
                      <% :assignment -> %>
                        <%= cond do %>
                          <% history.from_user_id == nil && history.to_user_id != nil -> %>
                            <span class="font-semibold">{gettext("Assigned to")}</span>
                            <span class="font-semibold text-purple-600">{history.to_user.name}</span>
                          <% history.from_user_id != nil && history.to_user_id == nil -> %>
                            <span class="font-semibold">{gettext("Unassigned from")}</span>
                            <span class="font-semibold text-purple-600">
                              {history.from_user.name}
                            </span>
                          <% true -> %>
                            <span class="font-semibold">{gettext("Reassigned")}</span>
                            {gettext("from")}
                            <span class="font-semibold text-purple-600">
                              {history.from_user.name}
                            </span>
                            {gettext("to")}
                            <span class="font-semibold text-purple-600">{history.to_user.name}</span>
                        <% end %>
                    <% end %>
                  </p>
                  <p class="text-xs text-base-content opacity-60">
                    {Calendar.strftime(history.inserted_at, "%B %d, %Y at %I:%M %p")}
                  </p>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div>
        <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">{gettext("Comments")}</h4>
        <%= if Enum.empty?(@task.comments) do %>
          <p class="text-base-content opacity-60 text-sm">{gettext("No comments yet")}</p>
        <% else %>
          <div class="space-y-3 max-h-48 overflow-y-auto">
            <%= for comment <- @task.comments do %>
              <div class="flex items-start gap-2 text-sm">
                <div class="mt-0.5">
                  <.icon name="hero-chat-bubble-left" class="w-4 h-4 text-base-content opacity-40" />
                </div>
                <div class="flex-1">
                  <p class="text-base-content whitespace-pre-wrap">{comment.content}</p>
                  <p class="text-xs text-gray-500 mt-1">
                    {Calendar.strftime(comment.inserted_at, "%B %d, %Y at %I:%M %p")}
                  </p>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
