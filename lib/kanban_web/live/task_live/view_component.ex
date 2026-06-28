defmodule KanbanWeb.TaskLive.ViewComponent do
  use KanbanWeb, :live_component

  import KanbanWeb.ReviewReportHelpers, only: [review_panel_visible?: 1]

  import KanbanWeb.TaskLive.Components.ActualVsEstimatedSection
  import KanbanWeb.TaskLive.Components.ChecklistSection
  import KanbanWeb.TaskLive.Components.ChildTasksSection
  import KanbanWeb.TaskLive.Components.CommentsSection
  import KanbanWeb.TaskLive.Components.CompletionSection
  import KanbanWeb.TaskLive.Components.DependenciesSection
  import KanbanWeb.TaskLive.Components.IntegrationPointsSection
  import KanbanWeb.TaskLive.Components.ReviewStatusSection
  import KanbanWeb.TaskLive.Components.TechnicalDetailsSection
  import KanbanWeb.TaskLive.Components.WorkflowStepsSection

  import KanbanWeb.TaskVisuals

  alias Kanban.Tasks
  alias KanbanWeb.AcceptanceChecklist
  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette
  alias KanbanWeb.MetaItem
  alias KanbanWeb.ReviewReportPanel
  alias KanbanWeb.SectionHead
  alias KanbanWeb.TaskActivityLog
  alias KanbanWeb.TaskTokens

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
    <div data-task-detail class="stride-screen" style="display: flex; flex-direction: column;">
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
        <.detail_band task={@task} can_modify={@can_modify} board_id={@board_id} />

        <div class="task-detail-layout" style="display: flex; min-height: 0;">
          <div
            data-task-detail-main
            class="task-detail-main"
            style="flex: 1; min-width: 0; padding: 18px 22px; overflow: hidden;"
          >
            <h2 style="margin: 0; font-size: 19px; font-weight: 600; letter-spacing: -0.02em; line-height: 1.3; color: var(--ink); text-wrap: pretty;">
              {@task.title}
            </h2>

            <p
              :if={@task.description}
              style="margin: 10px 0 0; font-size: 13.5px; line-height: 1.55; color: var(--ink-2); text-wrap: pretty; white-space: pre-wrap;"
            >
              {@task.description}
            </p>

            <div
              :if={
                (@task.why || @task.what || @task.where_context) &&
                  field_visible?(@field_visibility, "context")
              }
              style="display: flex; flex-direction: column; gap: 14px; margin-top: 20px;"
            >
              <.block :if={@task.why} label={gettext("Why")}>{@task.why}</.block>
              <.block :if={@task.what} label={gettext("What")}>{@task.what}</.block>
              <.block :if={@task.where_context} label={gettext("Where")} mono>
                {@task.where_context}
              </.block>
            </div>

            <%= if @task.acceptance_criteria && field_visible?(@field_visibility, "acceptance_criteria") do %>
              <SectionHead.section_head
                title={gettext("Acceptance criteria")}
                count_label={acceptance_count_label(@task.acceptance_criteria)}
              />
              <AcceptanceChecklist.acceptance_checklist acceptance_criteria={
                @task.acceptance_criteria
              } />
            <% end %>

            <%= if @task.key_files && !Enum.empty?(@task.key_files) && field_visible?(@field_visibility, "key_files") do %>
              <SectionHead.section_head
                title={gettext("Key files")}
                count_label={Integer.to_string(length(@task.key_files))}
              />
              <ul style="display: flex; flex-direction: column; gap: 2px; margin: 0; padding: 0; list-style: none;">
                <li
                  :for={kf <- @task.key_files}
                  style="display: flex; flex-direction: column; gap: 1px; padding: 3px 0;"
                >
                  <span style="display: inline-flex; align-items: flex-start; gap: 6px; min-width: 0; color: var(--ink-2); font-family: var(--font-mono); font-size: 11.5px;">
                    <.icon name="hero-document-text" class="w-3 h-3 flex-shrink-0 mt-0.5" />
                    <span style="overflow-wrap: anywhere; min-width: 0;">{kf.file_path}</span>
                  </span>
                  <span
                    :if={kf.note}
                    style="font-size: 11px; color: var(--ink-3); padding-left: 18px;"
                  >
                    {kf.note}
                  </span>
                </li>
              </ul>
            <% end %>

            <%= if @task.patterns_to_follow && field_visible?(@field_visibility, "technical_notes") do %>
              <SectionHead.section_head title={gettext("Patterns to follow")} />
              <p style="margin: 0; font-size: 12.5px; color: var(--ink); white-space: pre-wrap; text-wrap: pretty;">
                {@task.patterns_to_follow}
              </p>
            <% end %>

            <%= if @task.database_changes && field_visible?(@field_visibility, "technical_notes") do %>
              <SectionHead.section_head title={gettext("Database changes")} />
              <p style="margin: 0; font-size: 12.5px; color: var(--ink); font-family: var(--font-mono); white-space: pre-wrap;">
                {@task.database_changes}
              </p>
            <% end %>

            <%= if @task.validation_rules && field_visible?(@field_visibility, "technical_notes") do %>
              <SectionHead.section_head title={gettext("Validation rules")} />
              <p style="margin: 0; font-size: 12.5px; color: var(--ink); white-space: pre-wrap;">
                {@task.validation_rules}
              </p>
            <% end %>

            <%= if @task.verification_steps && !Enum.empty?(@task.verification_steps) && field_visible?(@field_visibility, "verification_steps") do %>
              <SectionHead.section_head title={gettext("Verification steps")} />
              <ol style="display: flex; flex-direction: column; gap: 6px; margin: 0; padding: 0; list-style: none;">
                <li
                  :for={{step, idx} <- Enum.with_index(@task.verification_steps, 1)}
                  style="display: grid; grid-template-columns: 24px 1fr; gap: 8px;"
                >
                  <span style="color: var(--ink-4); font-size: 11.5px; font-family: var(--font-mono);">
                    {idx}.
                  </span>
                  <div style="display: flex; flex-direction: column; gap: 3px; min-width: 0;">
                    <span style="font-size: 12px; color: var(--ink); font-family: var(--font-mono); overflow-wrap: anywhere;">
                      {step.step_text}
                    </span>
                    <span
                      :if={step.expected_result}
                      style="font-size: 11px; color: var(--ink-3); overflow-wrap: anywhere;"
                    >
                      → {step.expected_result}
                    </span>
                  </div>
                </li>
              </ol>
            <% end %>

            <%= if @task.pitfalls && !Enum.empty?(@task.pitfalls) && field_visible?(@field_visibility, "pitfalls") do %>
              <SectionHead.section_head title={gettext("Pitfalls")} />
              <ul style="display: flex; flex-direction: column; gap: 4px; margin: 0; padding-left: 18px; font-size: 12.5px; color: var(--st-blocked);">
                <li :for={pitfall <- @task.pitfalls}>{pitfall}</li>
              </ul>
            <% end %>

            <%= if @task.out_of_scope && !Enum.empty?(@task.out_of_scope) && field_visible?(@field_visibility, "out_of_scope") do %>
              <SectionHead.section_head title={gettext("Out of scope")} />
              <ul style="display: flex; flex-direction: column; gap: 4px; margin: 0; padding-left: 18px; font-size: 12.5px; color: var(--ink-3);">
                <li :for={item <- @task.out_of_scope}>{item}</li>
              </ul>
            <% end %>

            <%= if @task.security_considerations && !Enum.empty?(@task.security_considerations) && field_visible?(@field_visibility, "security_considerations") do %>
              <SectionHead.section_head title={gettext("Security considerations")} />
              <ul style="display: flex; flex-direction: column; gap: 4px; margin: 0; padding-left: 18px; font-size: 12.5px; color: var(--ink);">
                <li :for={item <- @task.security_considerations}>{item}</li>
              </ul>
            <% end %>

            <%= if @task.technology_requirements && !Enum.empty?(@task.technology_requirements) && field_visible?(@field_visibility, "technology_requirements") do %>
              <SectionHead.section_head title={gettext("Technology requirements")} />
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
            <% end %>

            <%= if (@task.telemetry_event || @task.metrics_to_track || @task.logging_requirements) && field_visible?(@field_visibility, "observability") do %>
              <SectionHead.section_head title={gettext("Observability")} />
              <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px;">
                <.block :if={@task.telemetry_event} label={gettext("Telemetry")} mono>
                  {@task.telemetry_event}
                </.block>
                <.block :if={@task.metrics_to_track} label={gettext("Metrics")} mono>
                  {@task.metrics_to_track}
                </.block>
                <.block :if={@task.logging_requirements} label={gettext("Logging")} mono>
                  {@task.logging_requirements}
                </.block>
              </div>
            <% end %>

            <%= if (@task.error_user_message || @task.error_on_failure) && field_visible?(@field_visibility, "error_handling") do %>
              <SectionHead.section_head title={gettext("Error handling")} />
              <div style="display: flex; flex-direction: column; gap: 6px; font-size: 12.5px;">
                <div :if={@task.error_user_message} style="white-space: pre-wrap; color: var(--ink);">
                  {@task.error_user_message}
                </div>
                <div :if={@task.error_on_failure} style="font-size: 11.5px; color: var(--ink-3);">
                  {gettext("On failure")}: {@task.error_on_failure}
                </div>
              </div>
            <% end %>

            <%= if @task.dependencies && !Enum.empty?(@task.dependencies) do %>
              <SectionHead.section_head title={gettext("Dependencies")} />
              <.dependencies_section dependencies={@task.dependencies} />
            <% end %>

            <%= if @task.testing_strategy && map_size(@task.testing_strategy) > 0 && field_visible?(@field_visibility, "testing_strategy") do %>
              <SectionHead.section_head title={gettext("Testing strategy")} />
              <.checklist_section testing_strategy={@task.testing_strategy} />
            <% end %>

            <%= if @task.integration_points && map_size(@task.integration_points) > 0 && field_visible?(@field_visibility, "integration_points") do %>
              <SectionHead.section_head title={gettext("Integration points")} />
              <.integration_points_section integration_points={@task.integration_points} />
            <% end %>

            <%= if @task.technical_details && map_size(@task.technical_details) > 0 && field_visible?(@field_visibility, "technical_details") do %>
              <SectionHead.section_head title={gettext("Technical details")} />
              <.technical_details_section technical_details={@task.technical_details} />
            <% end %>

            <%= if @task.status == :completed && (@task.actual_complexity || @task.actual_files_changed || @task.time_spent_minutes) do %>
              <SectionHead.section_head title={gettext("Actual vs estimated")} />
              <.actual_vs_estimated_section task={@task} />
            <% end %>

            <%= if @task.needs_review && @task.review_status do %>
              <SectionHead.section_head title={gettext("Review status")} />
              <.review_status_section task={@task} />
            <% end %>

            <%= if review_panel_visible?(@task) do %>
              <SectionHead.section_head title={gettext("Review report")} />
              <ReviewReportPanel.review_report_panel task={@task} />
            <% end %>

            <%= if @task.workflow_steps && @task.workflow_steps != [] do %>
              <SectionHead.section_head title={gettext("Workflow steps")} />
              <.workflow_steps_section steps={@task.workflow_steps} />
            <% end %>

            <%= if @task.status == :completed && (@task.completed_at || @task.completed_by || @task.completed_by_agent || @task.completion_summary) do %>
              <SectionHead.section_head title={gettext("Completion")} />
              <.completion_section task={@task} />
            <% end %>

            <%= if @task.type == :goal && length(@task.children || []) > 0 do %>
              <SectionHead.section_head
                title={gettext("Children")}
                count_label={Integer.to_string(length(@task.children))}
              />
              <.child_tasks_section children={@task.children} />
            <% end %>

            <SectionHead.section_head title={gettext("History")} />
            <TaskActivityLog.activity_log histories={@task.task_histories} />

            <SectionHead.section_head title={gettext("Comments")} />
            <.comments_section comments={@task.comments} />
          </div>

          <aside
            data-task-detail-aside
            class="task-detail-aside"
            style={[
              "width: 280px; flex-shrink: 0;",
              "border-left: 1px solid var(--line);",
              "background: var(--surface-2);",
              "padding: 20px 18px;",
              "display: flex; flex-direction: column; gap: 16px;"
            ]}
          >
            <MetaItem.meta_item label={gettext("Status")}>
              <.status_pill status={@task.status} variant={:base} />
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.assigned_to || @task.created_by} label={gettext("Author")}>
              <.author_avatar user={@task.assigned_to || @task.created_by} />
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={parent_goal_loaded?(@task)} label={gettext("Goal")}>
              <span style="color: var(--stride-violet); display: inline-flex;">
                <.icon name="hero-flag" class="w-3 h-3" />
              </span>
              <span class="ident">{@task.parent.identifier}</span>
              <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                {@task.parent.title}
              </span>
            </MetaItem.meta_item>

            <MetaItem.meta_item label={gettext("Type")}>
              <span>{TaskTokens.type_label(@task.type)}</span>
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.priority} label={gettext("Priority")}>
              <span
                aria-hidden="true"
                style={[
                  "width: 6px; height: 6px; border-radius: 50%;",
                  "background: #{TaskTokens.priority_color(@task.priority)};"
                ]}
              ></span>
              <span>{TaskTokens.priority_word(@task.priority)}</span>
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.complexity} label={gettext("Complexity")}>
              {TaskTokens.complexity_word(@task.complexity)}
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.column} label={gettext("Column")}>
              {@task.column.name}
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={board_name_for(@task)} label={gettext("Board")}>
              {board_name_for(@task)}
            </MetaItem.meta_item>

            <MetaItem.meta_item label={gettext("Needs review")}>
              <span :if={@task.needs_review} style={needs_review_pill_style()}>
                {gettext("Required")}
              </span>
              <span :if={!@task.needs_review} style="color: var(--ink-3); font-style: italic;">
                {gettext("Auto")}
              </span>
            </MetaItem.meta_item>

            <MetaItem.meta_item
              :if={@task.required_capabilities && @task.required_capabilities != []}
              label={gettext("Capabilities")}
            >
              <span
                :for={capability <- @task.required_capabilities}
                style={[
                  "display: inline-flex; align-items: center;",
                  "padding: 1px 6px; border-radius: 999px;",
                  "background: var(--stride-violet-soft); color: var(--stride-violet-ink);",
                  "font-size: 10.5px; font-weight: 600;"
                ]}
              >
                {capability}
              </span>
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.human_task} label={gettext("Human task")}>
              {gettext("Yes")}
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.estimated_files} label={gettext("Estimated files")}>
              {@task.estimated_files}
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.inserted_at} label={gettext("Created")} mono>
              {Calendar.strftime(@task.inserted_at, "%b %d, %Y")}
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.claimed_at} label={gettext("Claimed")} mono>
              {Calendar.strftime(@task.claimed_at, "%b %d, %Y %H:%M")}
            </MetaItem.meta_item>

            <MetaItem.meta_item :if={@task.completed_at} label={gettext("Completed")} mono>
              {Calendar.strftime(@task.completed_at, "%b %d, %Y")}
            </MetaItem.meta_item>

            <div
              :if={@can_modify && @board_id}
              style="margin-top: 4px; padding-top: 14px; border-top: 1px solid var(--line);"
            >
              <.link
                patch={~p"/boards/#{@board_id}/tasks/#{@task}/edit"}
                style={[
                  "display: inline-flex; align-items: center; gap: 6px;",
                  "padding: 6px 10px; border-radius: 5px;",
                  "background: var(--surface); border: 1px solid var(--line);",
                  "color: var(--ink-2); text-decoration: none;",
                  "font-size: 11.5px; font-weight: 500;"
                ]}
              >
                <.icon name="hero-pencil" class="w-3 h-3" />
                <span>{gettext("Edit task")}</span>
              </.link>
            </div>
          </aside>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Sub-components -----------------------------------------------------

  attr :task, :map, required: true
  attr :can_modify, :boolean, required: true
  attr :board_id, :any, required: true

  defp detail_band(assigns) do
    ~H"""
    <div
      data-task-detail-band
      style={[
        "padding: 14px 22px 12px;",
        "border-bottom: 1px solid var(--line);",
        "display: flex; align-items: center; gap: 8px; flex-wrap: wrap;",
        "background: var(--surface);"
      ]}
    >
      <.type_icon type={@task.type} />
      <span class="ident" style="font-size: 11.5px; color: var(--ink-2);">
        {@task.identifier}
      </span>
      <.status_pill status={@task.status} variant={:base} />
      <span
        :if={@task.priority}
        aria-hidden="true"
        style={[
          "width: 6px; height: 6px; border-radius: 50%;",
          "background: #{TaskTokens.priority_color(@task.priority)};"
        ]}
      ></span>
      <span :if={@task.priority || @task.complexity} style="font-size: 11px; color: var(--ink-3);">
        {pretty_meta(@task.priority, @task.complexity)}
      </span>
      <span style="flex: 1;"></span>
    </div>
    """
  end

  attr :user, :map, required: true

  defp author_avatar(assigns) do
    user = assigns.user
    name = user_display_name(user)
    palette = palette_for_user(user)

    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:palette, palette)

    ~H"""
    <Avatar.avatar kind={:human} name={@name} palette={@palette} size={16} />
    <span style="font-size: 11.5px; color: var(--ink-2);">{@name}</span>
    """
  end

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  defp block(assigns) do
    assigns =
      assign(assigns, :font, if(assigns.mono, do: "var(--font-mono)", else: "var(--font-sans)"))

    ~H"""
    <div>
      <span class="ucase" style="font-size: 10.5px; color: var(--ink-3);">{@label}</span>
      <p style={[
        "margin: 4px 0 0; font-size: 13px; line-height: 1.55;",
        "color: var(--ink); white-space: pre-wrap;",
        "font-family: #{@font};",
        "text-wrap: pretty;"
      ]}>
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  # --- Helpers ------------------------------------------------------------

  defp user_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: email}) when is_binary(email), do: email
  defp user_display_name(_), do: "?"

  defp palette_for_user(%{id: id}) when is_integer(id), do: AvatarPalette.for_human(id)
  defp palette_for_user(_), do: "human-blue"

  defp pretty_meta(nil, nil), do: ""
  defp pretty_meta(priority, nil), do: TaskTokens.priority_word(priority)
  defp pretty_meta(nil, complexity), do: TaskTokens.complexity_word(complexity)

  defp pretty_meta(priority, complexity) do
    "#{TaskTokens.priority_word(priority)} · #{TaskTokens.complexity_word(complexity)}"
  end

  defp acceptance_count_label(criteria) when is_binary(criteria) do
    total =
      criteria
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> length()

    "0/#{total}"
  end

  defp acceptance_count_label(_), do: nil

  defp parent_goal_loaded?(%{parent: %Ecto.Association.NotLoaded{}}), do: false
  defp parent_goal_loaded?(%{parent: nil}), do: false
  defp parent_goal_loaded?(%{parent: _}), do: true
  defp parent_goal_loaded?(_), do: false

  defp needs_review_pill_style do
    [
      "display: inline-flex; align-items: center;",
      "padding: 1px 6px; border-radius: 999px;",
      "background: var(--st-review-soft); color: var(--st-review);",
      "font-size: 10.5px; font-weight: 600;"
    ]
  end
end
