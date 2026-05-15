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
  alias KanbanWeb.SectionCard
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

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  defp mini(assigns) do
    assigns =
      assign(assigns, :font, if(assigns.mono, do: "var(--font-mono)", else: "var(--font-sans)"))

    ~H"""
    <div>
      <div class="ucase" style="font-size: 9.5px; margin-bottom: 4px; color: var(--ink-3);">
        {@label}
      </div>
      <div style={[
        "font-size: 11.5px; color: var(--ink); line-height: 1.5;",
        "font-family: #{@font};",
        "white-space: pre-wrap;"
      ]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-task-detail
      class="stride-screen"
      style="display: flex; flex-direction: column; gap: 14px;"
    >
      <%= if @task == nil do %>
        <div style={[
          "padding: 24px; text-align: center;",
          "background: var(--st-blocked-soft); color: var(--st-blocked);",
          "border: 1px solid var(--st-blocked);",
          "border-radius: 8px;"
        ]}>
          <.icon name="hero-exclamation-triangle" class="w-10 h-10 mx-auto mb-4" />
          <h3 style="font-size: 16px; font-weight: 600; margin: 0 0 6px;">
            {gettext("Task Not Found")}
          </h3>
          <p style="margin: 0; font-size: 13px;">
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

        <div
          :if={@task.human_task || @task.estimated_files}
          style="display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px;"
        >
          <SectionCard.section_card :if={@task.human_task} title={gettext("Human Task")}>
            {gettext("Yes — humans only; agents will not claim")}
          </SectionCard.section_card>

          <SectionCard.section_card :if={@task.estimated_files} title={gettext("Estimated Files")}>
            {@task.estimated_files}
          </SectionCard.section_card>
        </div>

        <SectionCard.section_card
          :if={@task.created_by || @task.created_by_agent}
          title={gettext("Creator")}
        >
          <div style="display: flex; flex-direction: column; gap: 6px;">
            <div :if={@task.created_by}>
              <span style="color: var(--ink-3);">{gettext("Created by")}:</span>
              <span style="font-weight: 500;">
                {@task.created_by.name || @task.created_by.email}
              </span>
            </div>
            <div :if={@task.created_by_agent}>
              <span style="color: var(--ink-3);">{gettext("Agent")}:</span>
              <span style="font-weight: 500; font-family: var(--font-mono);">
                {@task.created_by_agent}
              </span>
            </div>
            <div :if={@task.claimed_at}>
              <span style="color: var(--ink-3);">{gettext("Claimed at")}:</span>
              <span style="font-variant-numeric: tabular-nums;">
                {Calendar.strftime(@task.claimed_at, "%B %d, %Y at %I:%M %p")}
              </span>
            </div>
            <div :if={@task.claim_expires_at}>
              <span style="color: var(--ink-3);">{gettext("Claim expires")}:</span>
              <span style="font-variant-numeric: tabular-nums;">
                {Calendar.strftime(@task.claim_expires_at, "%B %d, %Y at %I:%M %p")}
              </span>
            </div>
          </div>
        </SectionCard.section_card>

        <div
          :if={
            (@task.why || @task.what || @task.where_context) &&
              field_visible?(@field_visibility, "context")
          }
          style="display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px;"
        >
          <SectionCard.section_card :if={@task.why} title={gettext("Why")}>
            <div style="white-space: pre-wrap;">{@task.why}</div>
          </SectionCard.section_card>
          <SectionCard.section_card :if={@task.what} title={gettext("What")}>
            <div style="white-space: pre-wrap;">{@task.what}</div>
          </SectionCard.section_card>
          <SectionCard.section_card
            :if={@task.where_context}
            title={gettext("Where in the codebase")}
            mono
          >
            <div style="white-space: pre-wrap;">{@task.where_context}</div>
          </SectionCard.section_card>
        </div>

        <SectionCard.section_card :if={@task.description} title={gettext("Description")}>
          <div style="white-space: pre-wrap;">{@task.description}</div>
        </SectionCard.section_card>

        <%= if @task.acceptance_criteria && field_visible?(@field_visibility, "acceptance_criteria") do %>
          <AcceptanceChecklist.acceptance_checklist acceptance_criteria={@task.acceptance_criteria} />
        <% end %>

        <SectionCard.section_card
          :if={
            @task.key_files && !Enum.empty?(@task.key_files) &&
              field_visible?(@field_visibility, "key_files")
          }
          title={gettext("Key files")}
          count_label={Integer.to_string(length(@task.key_files || []))}
        >
          <ul style="display: flex; flex-direction: column; gap: 4px; margin: 0; padding: 0; list-style: none;">
            <li
              :for={kf <- @task.key_files}
              style="display: flex; flex-direction: column; gap: 2px; padding: 3px 0;"
            >
              <span style="display: inline-flex; align-items: center; gap: 6px; color: var(--ink-2); font-family: var(--font-mono); font-size: 11.5px;">
                <.icon name="hero-document-text" class="w-3 h-3" />
                <span>{kf.file_path}</span>
              </span>
              <span :if={kf.note} style="font-size: 11px; color: var(--ink-3); padding-left: 18px;">
                {kf.note}
              </span>
            </li>
          </ul>
        </SectionCard.section_card>

        <SectionCard.section_card
          :if={
            @task.verification_steps && !Enum.empty?(@task.verification_steps) &&
              field_visible?(@field_visibility, "verification_steps")
          }
          title={gettext("Verification steps")}
          mono
        >
          <ol style="display: flex; flex-direction: column; gap: 6px; margin: 0; padding: 0; list-style: none;">
            <li
              :for={{step, idx} <- Enum.with_index(@task.verification_steps, 1)}
              style="display: grid; grid-template-columns: 24px 1fr; gap: 8px;"
            >
              <span style="color: var(--ink-4); font-size: 11.5px;">{idx}.</span>
              <div style="display: flex; flex-direction: column; gap: 3px;">
                <span style="font-size: 11.5px; color: var(--ink);">{step.step_text}</span>
                <span
                  :if={step.expected_result}
                  style="font-size: 11px; color: var(--ink-3); font-family: var(--font-sans);"
                >
                  → {step.expected_result}
                </span>
              </div>
            </li>
          </ol>
        </SectionCard.section_card>

        <div
          :if={
            (@task.patterns_to_follow || @task.database_changes || @task.validation_rules) &&
              field_visible?(@field_visibility, "technical_notes")
          }
          style="display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px;"
        >
          <SectionCard.section_card
            :if={@task.patterns_to_follow}
            title={gettext("Patterns to follow")}
          >
            <div style="white-space: pre-wrap;">{@task.patterns_to_follow}</div>
          </SectionCard.section_card>
          <SectionCard.section_card
            :if={@task.database_changes}
            title={gettext("Database changes")}
            mono
          >
            <div style="white-space: pre-wrap;">{@task.database_changes}</div>
          </SectionCard.section_card>
          <SectionCard.section_card
            :if={@task.validation_rules}
            title={gettext("Validation rules")}
          >
            <div style="white-space: pre-wrap;">{@task.validation_rules}</div>
          </SectionCard.section_card>
        </div>

        <SectionCard.section_card
          :if={
            (@task.telemetry_event || @task.metrics_to_track || @task.logging_requirements) &&
              field_visible?(@field_visibility, "observability")
          }
          title={gettext("Observability")}
        >
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px;">
            <.mini :if={@task.telemetry_event} label={gettext("Telemetry")} mono>
              {@task.telemetry_event}
            </.mini>
            <.mini :if={@task.metrics_to_track} label={gettext("Metrics")} mono>
              {@task.metrics_to_track}
            </.mini>
            <.mini :if={@task.logging_requirements} label={gettext("Logging")} mono>
              {@task.logging_requirements}
            </.mini>
          </div>
        </SectionCard.section_card>

        <SectionCard.section_card
          :if={
            (@task.error_user_message || @task.error_on_failure) &&
              field_visible?(@field_visibility, "error_handling")
          }
          title={gettext("Error handling")}
        >
          <div style="display: flex; flex-direction: column; gap: 6px;">
            <div :if={@task.error_user_message} style="white-space: pre-wrap;">
              {@task.error_user_message}
            </div>
            <div :if={@task.error_on_failure} style="font-size: 11.5px; color: var(--ink-3);">
              {gettext("On failure")}: {@task.error_on_failure}
            </div>
          </div>
        </SectionCard.section_card>

        <SectionCard.section_card
          :if={
            @task.technology_requirements && !Enum.empty?(@task.technology_requirements) &&
              field_visible?(@field_visibility, "technology_requirements")
          }
          title={gettext("Technology requirements")}
        >
          <ul style="display: flex; flex-wrap: wrap; gap: 6px; margin: 0; padding: 0; list-style: none;">
            <li
              :for={tech <- @task.technology_requirements}
              style={[
                "display: inline-flex; align-items: center;",
                "padding: 2px 8px; border-radius: 999px;",
                "background: var(--surface-sunken); color: var(--ink-2);",
                "font-size: 11.5px; font-family: var(--font-mono);",
                "border: 1px solid var(--line);"
              ]}
            >
              {tech}
            </li>
          </ul>
        </SectionCard.section_card>

        <SectionCard.section_card
          :if={
            @task.required_capabilities && !Enum.empty?(@task.required_capabilities) &&
              field_visible?(@field_visibility, "required_capabilities")
          }
          title={gettext("Required capabilities")}
        >
          <ul style="display: flex; flex-wrap: wrap; gap: 6px; margin: 0; padding: 0; list-style: none;">
            <li
              :for={capability <- @task.required_capabilities}
              style={[
                "display: inline-flex; align-items: center;",
                "padding: 2px 8px; border-radius: 999px;",
                "background: var(--stride-violet-soft); color: var(--stride-violet-ink);",
                "font-size: 11.5px; font-weight: 500;"
              ]}
            >
              {capability}
            </li>
          </ul>
        </SectionCard.section_card>

        <%= if @task.dependencies && !Enum.empty?(@task.dependencies) do %>
          <.dependencies_section dependencies={@task.dependencies} />
        <% end %>

        <SectionCard.section_card
          :if={
            @task.pitfalls && !Enum.empty?(@task.pitfalls) &&
              field_visible?(@field_visibility, "pitfalls")
          }
          title={gettext("Pitfalls")}
          tone={:warn}
        >
          <ul style="display: flex; flex-direction: column; gap: 4px; margin: 0; padding-left: 18px;">
            <li :for={pitfall <- @task.pitfalls}>{pitfall}</li>
          </ul>
        </SectionCard.section_card>

        <SectionCard.section_card
          :if={
            @task.out_of_scope && !Enum.empty?(@task.out_of_scope) &&
              field_visible?(@field_visibility, "out_of_scope")
          }
          title={gettext("Out of scope")}
          tone={:muted}
        >
          <ul style="display: flex; flex-direction: column; gap: 4px; margin: 0; padding-left: 18px;">
            <li :for={item <- @task.out_of_scope}>{item}</li>
          </ul>
        </SectionCard.section_card>

        <SectionCard.section_card
          :if={
            @task.security_considerations && !Enum.empty?(@task.security_considerations) &&
              field_visible?(@field_visibility, "security_considerations")
          }
          title={gettext("Security considerations")}
        >
          <ul style="display: flex; flex-direction: column; gap: 4px; margin: 0; padding-left: 18px;">
            <li :for={item <- @task.security_considerations}>{item}</li>
          </ul>
        </SectionCard.section_card>

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

        <SectionCard.section_card
          :if={@task.review_report && @task.review_report != ""}
          title={gettext("Review report")}
          mono
        >
          <div style="white-space: pre-wrap; max-height: 384px; overflow-y: auto;">
            {@task.review_report}
          </div>
        </SectionCard.section_card>

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
