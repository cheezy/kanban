defmodule KanbanWeb.BoardLive.WebhookViews do
  @moduledoc """
  Function components for the webhook section of the board's Integrations
  view (W2228), rendered by `KanbanWeb.BoardLive.IntegrationsComponent`:
  the one-time secret reveal, an endpoint row and its delivery log. The
  create form is `KanbanWeb.BoardLive.WebhookForm`.

  Every control that sends an event carries `phx-target={@myself}`, so the
  event reaches the component, which re-checks ownership; the secret's Copy
  button only runs client-side. An endpoint's URL is never rendered,
  only its host: a Slack incoming-webhook URL is a credential. Text a
  receiver sent back (the delivery error) is shown escaped and cut short.
  """
  use KanbanWeb, :html

  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.TaskTokens
  alias KanbanWeb.TimeAgo

  @error_preview 160

  @doc """
  The signing secret, shown once after a create or a rotation, with a copy
  button and a dismiss button.
  """
  attr :secret, :string, required: true
  attr :myself, :any, required: true

  def secret_reveal(assigns) do
    ~H"""
    <section
      id="webhook-secret"
      style={[
        "background: var(--stride-orange-soft); border: 1px solid var(--line);",
        "border-radius: 10px; padding: 14px 16px; margin-bottom: 14px;",
        "display: flex; align-items: flex-start; gap: 12px;"
      ]}
    >
      <span style="color: var(--stride-orange-ink); display: inline-flex; margin-top: 2px;">
        <.icon name="hero-key" class="w-5 h-5" />
      </span>
      <div style="flex: 1; min-width: 0;">
        <div style="font-size: 13px; font-weight: 600; color: var(--ink);">
          {gettext("Signing secret")}
        </div>
        <p style="margin: 4px 0 0; font-size: 11.5px; color: var(--ink-2); line-height: 1.5;">
          {gettext("Copy it now — you won't be able to see it again.")}
          {gettext("Use it to verify the X-Stride-Signature header on each request.")}
        </p>
        <div style="display: flex; align-items: center; gap: 8px; margin-top: 10px; flex-wrap: wrap;">
          <code
            id="webhook-secret-value"
            style={[
              "flex: 1 1 220px; min-width: 0; padding: 6px 10px; border-radius: 5px;",
              "background: var(--surface); border: 1px solid var(--line-strong);",
              "color: var(--ink); font-family: var(--font-mono);",
              "font-size: 11.5px; word-break: break-all; user-select: all;"
            ]}
          >{@secret}</code>
          <button
            id="webhook-secret-copy"
            type="button"
            phx-click={
              JS.dispatch("stride:copy", to: "#webhook-secret-value")
              |> JS.show(to: "#webhook-secret-copied")
            }
            style={[
              "padding: 6px 12px; border-radius: 5px; border: none;",
              "background: var(--ink); color: var(--color-base-100);",
              "font-size: 12px; font-weight: 500; cursor: pointer;"
            ]}
          >
            {gettext("Copy")}
          </button>
          <span
            id="webhook-secret-copied"
            role="status"
            style="display: none; font-size: 11.5px; color: var(--ink-2);"
          >
            {gettext("Copied!")}
          </span>
        </div>
      </div>
      <button
        id="webhook-secret-dismiss"
        type="button"
        phx-click="dismiss_secret"
        phx-target={@myself}
        aria-label={gettext("Dismiss")}
        style="padding: 4px; border-radius: 4px; border: none; background: transparent; cursor: pointer; color: var(--ink-3);"
      >
        <.icon name="hero-x-mark" class="w-4 h-4" />
      </button>
    </section>
    """
  end

  @doc """
  One endpoint: kind, host, events, the enabled switch and its actions,
  plus its delivery log when `log_open?`.
  """
  attr :endpoint, Endpoint, required: true
  attr :myself, :any, required: true
  attr :log_open?, :boolean, default: false
  attr :deliveries, :list, default: []

  def endpoint_row(assigns) do
    ~H"""
    <li
      id={"webhook-endpoint-#{@endpoint.id}"}
      style="padding: 12px 0; border-top: 1px solid var(--line); list-style: none;"
    >
      <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
        <.kind_badge kind={@endpoint.kind} />
        <span
          data-endpoint-host
          style="font-size: 12.5px; font-weight: 500; color: var(--ink); overflow-wrap: anywhere;"
        >
          {url_host(@endpoint.url)}
        </span>
        <span
          :if={!@endpoint.enabled}
          data-endpoint-disabled
          style={[
            "font-size: 10.5px; font-weight: 600; padding: 1px 6px; border-radius: 4px;",
            "background: var(--st-blocked-soft); color: var(--st-blocked);"
          ]}
        >
          {gettext("Disabled")}
        </span>
      </div>
      <div style="display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px;">
        <code
          :for={event <- @endpoint.event_types}
          style={[
            "font-family: var(--font-mono); font-size: 10.5px; color: var(--ink-2);",
            "background: var(--surface-sunken); padding: 1px 6px; border-radius: 4px;"
          ]}
        >
          {event}
        </code>
      </div>
      <div style="display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-top: 8px;">
        <button
          id={"webhook-toggle-#{@endpoint.id}"}
          type="button"
          data-enabled={to_string(@endpoint.enabled)}
          phx-click="toggle"
          phx-value-id={@endpoint.id}
          phx-target={@myself}
          style={action_style()}
        >
          <.icon
            name={if @endpoint.enabled, do: "hero-pause", else: "hero-play"}
            class="w-3.5 h-3.5"
          />
          {if @endpoint.enabled, do: gettext("Disable"), else: gettext("Enable")}
        </button>
        <button
          id={"webhook-test-#{@endpoint.id}"}
          type="button"
          phx-click="send_test"
          phx-value-id={@endpoint.id}
          phx-target={@myself}
          style={action_style()}
        >
          <.icon name="hero-paper-airplane" class="w-3.5 h-3.5" />
          {gettext("Send test")}
        </button>
        <button
          id={"webhook-log-toggle-#{@endpoint.id}"}
          type="button"
          phx-click={if @log_open?, do: "hide_log", else: "show_log"}
          phx-value-id={@endpoint.id}
          phx-target={@myself}
          aria-expanded={to_string(@log_open?)}
          style={action_style()}
        >
          <.icon name="hero-list-bullet" class="w-3.5 h-3.5" />
          {gettext("Deliveries")}
        </button>
        <button
          :if={@endpoint.kind == :generic}
          id={"webhook-rotate-#{@endpoint.id}"}
          type="button"
          phx-click="rotate"
          phx-value-id={@endpoint.id}
          phx-target={@myself}
          data-confirm={
            gettext("Rotate the signing secret? The old secret stops working immediately.")
          }
          style={action_style()}
        >
          <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
          {gettext("Rotate secret")}
        </button>
        <button
          id={"webhook-delete-#{@endpoint.id}"}
          type="button"
          phx-click="delete"
          phx-value-id={@endpoint.id}
          phx-target={@myself}
          data-confirm={gettext("Delete this endpoint and its delivery log?")}
          style={action_style("var(--st-blocked)")}
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" />
          {gettext("Delete")}
        </button>
      </div>
      <.delivery_log
        :if={@log_open?}
        endpoint_id={@endpoint.id}
        deliveries={@deliveries}
        myself={@myself}
      />
    </li>
    """
  end

  attr :kind, :atom, required: true

  defp kind_badge(assigns) do
    ~H"""
    <span
      data-endpoint-kind={@kind}
      style={[
        "font-size: 10.5px; font-weight: 600; padding: 1px 6px; border-radius: 4px;",
        kind_colors(@kind)
      ]}
    >
      {kind_label(@kind)}
    </span>
    """
  end

  defp kind_colors(:slack),
    do: "background: var(--stride-violet-soft); color: var(--stride-violet-ink);"

  defp kind_colors(_kind), do: "background: var(--surface-sunken); color: var(--ink-2);"

  @doc """
  An endpoint's most recent delivery attempts, newest first, with a refresh
  button. A delivery appears once the worker has made the attempt.
  """
  attr :endpoint_id, :integer, required: true
  attr :deliveries, :list, required: true
  attr :myself, :any, required: true

  def delivery_log(assigns) do
    ~H"""
    <div
      id={"webhook-log-#{@endpoint_id}"}
      style={[
        "margin-top: 10px; padding: 10px 12px; border-radius: 8px;",
        "background: var(--surface-sunken);"
      ]}
    >
      <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px;">
        <span style="font-size: 11.5px; font-weight: 600; color: var(--ink-2);">
          {gettext("Recent deliveries")}
        </span>
        <button
          id={"webhook-log-refresh-#{@endpoint_id}"}
          type="button"
          phx-click="show_log"
          phx-value-id={@endpoint_id}
          phx-target={@myself}
          style={action_style()}
        >
          <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
          {gettext("Refresh")}
        </button>
      </div>
      <p
        :if={@deliveries == []}
        data-deliveries-empty
        style="margin: 8px 0 0; font-size: 11.5px; color: var(--ink-3);"
      >
        {gettext("No deliveries yet.")}
      </p>
      <div :if={@deliveries != []} style="overflow-x: auto; margin-top: 8px;">
        <table style="width: 100%; border-collapse: collapse; font-size: 11.5px; color: var(--ink);">
          <thead>
            <tr style="text-align: left; color: var(--ink-3);">
              <th style={cell_style()}>{gettext("Event")}</th>
              <th style={cell_style()}>{gettext("Status")}</th>
              <th style={cell_style()}>{gettext("Attempt")}</th>
              <th style={cell_style()}>{gettext("Response")}</th>
              <th style={cell_style()}>{gettext("Error")}</th>
              <th style={cell_style()}>{gettext("Time")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={delivery <- @deliveries}
              id={"webhook-delivery-#{delivery.id}"}
              style="border-top: 1px solid var(--line);"
            >
              <td style={[cell_style(), "font-family: var(--font-mono);"]}>{delivery.event}</td>
              <td style={cell_style()}><.delivery_status status={delivery.status} /></td>
              <td style={cell_style()}>#{delivery.attempt}</td>
              <td style={cell_style()}>{delivery.response_status || "—"}</td>
              <td
                title={delivery.error}
                style={[
                  cell_style(),
                  "max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"
                ]}
              >
                {truncate(delivery.error, error_preview())}
              </td>
              <td style={[cell_style(), "white-space: nowrap;"]}>
                <time datetime={DateTime.to_iso8601(delivery.inserted_at)}>
                  {TimeAgo.format_age(delivery.inserted_at, :coarse)}
                </time>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp delivery_status(assigns) do
    assigns = assign(assigns, :task_status, task_status(assigns.status))

    ~H"""
    <span
      data-delivery-status={@status}
      style={[
        "font-size: 10.5px; font-weight: 600; padding: 1px 6px; border-radius: 4px;",
        "white-space: nowrap;",
        "background: #{TaskTokens.status_soft(@task_status)};",
        "color: #{TaskTokens.status_ink(@task_status)};"
      ]}
    >
      {status_label(@status)}
    </span>
    """
  end

  defp task_status(:succeeded), do: :completed
  defp task_status(:failed), do: :blocked
  defp task_status(_pending), do: :open

  defp status_label(:succeeded), do: gettext("Succeeded")
  defp status_label(:failed), do: gettext("Failed")
  defp status_label(_pending), do: gettext("Pending")

  @doc "The display name of an endpoint kind."
  def kind_label(kind) when kind in [:slack, "slack"], do: gettext("Slack")
  def kind_label(_kind), do: gettext("Generic webhook")

  @doc """
  The host of `url`, the only part of an endpoint's URL the page shows.
  """
  def url_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> gettext("unknown host")
    end
  end

  def url_host(_url), do: gettext("unknown host")

  @doc """
  `text` cut to at most `max` characters, with an ellipsis when it was
  longer. `nil` becomes an empty string.
  """
  def truncate(nil, _max), do: ""

  def truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp action_style(color \\ "var(--ink-2)") do
    [
      "display: inline-flex; align-items: center; gap: 4px;",
      "padding: 3px 8px; border-radius: 5px; cursor: pointer;",
      "background: var(--surface); border: 1px solid var(--line);",
      "font-size: 11.5px; font-weight: 500; color: #{color};"
    ]
  end

  defp error_preview, do: @error_preview

  defp cell_style, do: "padding: 5px 8px 5px 0; vertical-align: top;"
end
