defmodule KanbanWeb.ReviewDetailHeader do
  @moduledoc """
  Header bar for the Review detail panel at `/review`.

  Surfaces the completing agent's identity (avatar, name) alongside the
  task identifier, a "completed" label, and the relative age of the
  completion. The right edge carries two action buttons — Request changes
  and Approve — wired to `phx-click` event names supplied by the parent
  LiveView.

  PR / branch metadata is intentionally not rendered: `Kanban.Tasks.Task`
  does not currently persist PR data for completed reviews, and the
  initiative this component lands under (G/W567) keeps that surface out
  of scope.

  Purely presentational — the LiveView owns review state, modals, and
  optimistic UI. Buttons emit raw events via `phx-click`; this component
  does not manage confirmation dialogs.
  """
  use KanbanWeb, :html

  alias KanbanWeb.TimeAgo

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette

  @doc """
  Renders the review detail header.

  ## Attrs

    * `task` — required. A `%Kanban.Tasks.Task{}` (or compatible map)
      exposing `:identifier`, `:completed_at`, and `:completed_by_agent`.
    * `on_approve` — required. The `phx-click` event name fired by the
      Approve button.
    * `on_request_changes` — required. The `phx-click` event name fired
      by the Request changes button.
  """
  attr :task, :map, required: true
  attr :on_approve, :string, required: true
  attr :on_request_changes, :string, required: true

  def review_detail_header(assigns) do
    task = assigns.task

    assigns =
      assigns
      |> assign(:agent_name, agent_name_for(task))
      |> assign(:age_label, age_label_for(task))
      |> assign(:completed_by_user, completed_by_user(task))

    ~H"""
    <header
      data-review-detail-header
      style={[
        "display: flex; flex-wrap: wrap; align-items: flex-start; gap: 6px 12px;",
        "padding: 12px 16px; border-bottom: 1px solid var(--line);",
        "background: var(--surface); color: var(--ink);"
      ]}
    >
      <Avatar.avatar
        kind={:agent}
        name={@agent_name || "Unknown agent"}
        palette={AvatarPalette.for_agent(@agent_name)}
        size={20}
      />

      <div style="display: flex; flex-direction: column; gap: 2px;">
        <div style="display: flex; align-items: center; flex-wrap: wrap; gap: 6px 8px;">
          <span
            data-review-detail-header-agent-name
            style="font-size: 13px; font-weight: 600; color: var(--ink);"
          >
            {@agent_name || gettext("Unknown agent")}
          </span>

          <span
            data-review-detail-header-label
            style="font-size: 12px; color: var(--ink-3);"
          >
            {gettext("completed")}
          </span>

          <span
            data-review-detail-header-ident
            style={[
              "font-size: 11px; font-family: var(--font-mono);",
              "color: var(--ink-3);"
            ]}
          >
            {@task.identifier}
          </span>

          <time
            :if={@age_label}
            data-review-detail-header-time
            datetime={DateTime.to_iso8601(@task.completed_at)}
            style={[
              "font-size: 11px; font-family: var(--font-mono);",
              "color: var(--ink-3);"
            ]}
          >
            {@age_label}
          </time>
        </div>

        <div
          :if={@completed_by_user}
          data-review-detail-header-completed-by
          style={[
            "display: flex; align-items: center; gap: 5px;",
            "font-size: 11.5px; color: var(--ink-3);"
          ]}
        >
          <span>{gettext("by")}</span>
          <span
            data-review-detail-header-completed-by-name
            style="color: var(--ink-2); font-weight: 500;"
          >
            {completed_by_display_name(@completed_by_user)}
          </span>
          <a
            :if={@completed_by_user.email}
            data-review-detail-header-completed-by-email
            href={"mailto:#{@completed_by_user.email}"}
            title={gettext("Email %{name}", name: completed_by_display_name(@completed_by_user))}
            style={[
              "display: inline-flex; align-items: center; gap: 3px;",
              "color: var(--ink-3); text-decoration: none;"
            ]}
          >
            <.icon name="hero-envelope" class="w-3 h-3" />
            <span style="font-family: var(--font-mono);">
              {@completed_by_user.email}
            </span>
          </a>
        </div>
      </div>

      <span style="flex: 1;" />

      <div
        data-review-detail-header-actions
        class="flex flex-wrap items-center gap-2"
      >
        <.button phx-click={@on_request_changes} data-review-detail-header-request-changes>
          {gettext("Request changes")}
        </.button>
        <.button
          variant="primary"
          phx-click={@on_approve}
          data-review-detail-header-approve
        >
          {gettext("Approve")}
        </.button>
      </div>
    </header>
    """
  end

  defp completed_by_user(%{completed_by: %{} = user}) when not is_nil(user), do: user
  defp completed_by_user(_), do: nil

  defp completed_by_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp completed_by_display_name(%{email: email}) when is_binary(email), do: email
  defp completed_by_display_name(_), do: ""

  defp agent_name_for(%{completed_by_agent: agent}) when is_binary(agent) and agent != "",
    do: agent

  defp agent_name_for(_), do: nil

  defp age_label_for(%{completed_at: %DateTime{} = dt}), do: TimeAgo.format_age(dt, :fine)
  defp age_label_for(_), do: nil
end
