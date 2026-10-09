defmodule KanbanWeb.BoardLive.WebhookForm do
  @moduledoc """
  The form that adds a webhook or Slack endpoint on the board's
  Integrations view (W2228), split from `KanbanWeb.BoardLive.WebhookViews`.
  Field errors come from the endpoint changeset and are translated with
  `translate_error/1` (the errors domain).
  """
  use KanbanWeb, :html

  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.BoardLive.WebhookViews

  @doc """
  The form that adds an endpoint: kind, URL and the events to send. `rev`
  changes after each create so the browser starts from an empty form.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :rev, :integer, required: true
  attr :myself, :any, required: true

  def endpoint_form(assigns) do
    assigns =
      assigns
      |> assign(:slack?, to_string(assigns.form[:kind].value) == "slack")
      |> assign(:selected, List.wrap(assigns.form[:event_types].value))

    ~H"""
    <.form
      for={@form}
      id={"webhook-endpoint-form-#{@rev}"}
      phx-change="validate"
      phx-submit="create"
      phx-target={@myself}
      style="margin-top: 14px;"
    >
      <h4 style="margin: 0 0 10px; font-size: 12.5px; font-weight: 600; color: var(--ink);">
        {gettext("Add an endpoint")}
      </h4>
      <div style="display: flex; flex-wrap: wrap; gap: 10px;">
        <label style={[label_style(), "flex: 0 1 180px;"]}>
          <span class="ucase" style={caption_style()}>{gettext("Kind")}</span>
          <select id={@form[:kind].id} name={@form[:kind].name} style={input_style()}>
            <option
              :for={kind <- Endpoint.kinds()}
              value={kind}
              selected={to_string(@form[:kind].value) == to_string(kind)}
            >
              {WebhookViews.kind_label(kind)}
            </option>
          </select>
        </label>
        <label style={[label_style(), "flex: 1 1 260px;"]}>
          <span class="ucase" style={caption_style()}>{gettext("URL")}</span>
          <input
            type="text"
            inputmode="url"
            autocomplete="off"
            maxlength="2048"
            id={@form[:url].id}
            name={@form[:url].name}
            value={Phoenix.HTML.Form.normalize_value("text", @form[:url].value)}
            placeholder={if @slack?, do: "https://hooks.slack.com/services/…", else: "https://"}
            style={input_style()}
          />
          <span style="font-size: 11px; color: var(--ink-3); line-height: 1.4;">
            {if @slack?,
              do: gettext("Paste a Slack incoming webhook URL (https://hooks.slack.com/…)."),
              else: gettext("Stride sends a signed JSON POST to this HTTPS address.")}
          </span>
          <.field_errors field={@form[:url]} />
        </label>
      </div>
      <fieldset style="margin: 12px 0 0; padding: 0; border: none;">
        <legend class="ucase" style={caption_style()}>{gettext("Events")}</legend>
        <input type="hidden" name={@form[:event_types].name <> "[]"} value="" />
        <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 4px; margin-top: 6px;">
          <label
            :for={event <- Endpoint.event_types()}
            style="display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--ink);"
          >
            <input
              type="checkbox"
              name={@form[:event_types].name <> "[]"}
              value={event}
              checked={event in @selected}
            />
            <code style="font-family: var(--font-mono); font-size: 11px;">{event}</code>
          </label>
        </div>
        <.field_errors field={@form[:event_types]} />
      </fieldset>
      <.field_errors field={@form[:kind]} />
      <div style="display: flex; justify-content: flex-end; margin-top: 12px;">
        <button
          type="submit"
          phx-disable-with={gettext("Saving...")}
          style={[
            "padding: 6px 12px; border-radius: 5px; border: none;",
            "background: var(--ink); color: var(--color-base-100);",
            "font-size: 12px; font-weight: 500; cursor: pointer;"
          ]}
        >
          {gettext("Add endpoint")}
        </button>
      </div>
    </.form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_errors(assigns) do
    ~H"""
    <.error :for={msg <- errors_for(@field)}>{msg}</.error>
    """
  end

  defp errors_for(field) do
    if used_input?(field), do: Enum.map(field.errors, &translate_error/1), else: []
  end

  defp label_style, do: "display: flex; flex-direction: column; gap: 5px; min-width: 0;"

  defp caption_style,
    do: "font-size: 10.5px; font-weight: 500; color: var(--ink-3); letter-spacing: 0.04em;"

  defp input_style do
    [
      "height: 32px; padding: 0 10px; border-radius: 5px; min-width: 0;",
      "background: var(--surface); color: var(--ink);",
      "border: 1px solid var(--line-strong); font-size: 12.5px;"
    ]
  end
end
