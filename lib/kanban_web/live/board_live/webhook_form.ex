defmodule KanbanWeb.BoardLive.WebhookForm do
  @moduledoc """
  The forms that add a webhook, Slack or Discord endpoint on the board's
  Integrations view (W2228) and edit one (W2364), split from
  `KanbanWeb.BoardLive.WebhookViews`. Field errors come from the endpoint
  changeset and are translated with `translate_error/1` (the errors domain).

  The edit form never renders the stored URL: its URL input echoes only what
  the owner typed, and its hint names the stored URL's host. A Slack or
  Discord webhook URL is a credential.
  """
  use KanbanWeb, :html

  alias Kanban.Webhooks.Endpoint
  alias KanbanWeb.BoardLive.WebhookKinds
  alias KanbanWeb.BoardLive.WebhookViews

  @doc """
  The form that adds an endpoint: kind, URL and the events to send. `rev`
  changes after each create so the browser starts from an empty form.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :rev, :integer, required: true
  attr :myself, :any, required: true

  def endpoint_form(assigns) do
    assigns = assign(assigns, :kind, assigns.form[:kind].value)

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
              {WebhookKinds.label(kind)}
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
            placeholder={WebhookKinds.url_placeholder(@kind)}
            style={input_style()}
          />
          <span style="font-size: 11px; color: var(--ink-3); line-height: 1.4;">
            {WebhookKinds.url_hint(@kind)}
          </span>
          <.field_errors field={@form[:url]} />
        </label>
      </div>
      <.events_fieldset form={@form} />
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

  @doc """
  The form that edits `endpoint`: its events and, optionally, its URL. The
  kind is shown but cannot be changed. The URL input starts empty, and
  saving it empty keeps the stored URL.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :endpoint, Endpoint, required: true
  attr :myself, :any, required: true

  def edit_form(assigns) do
    assigns =
      assigns
      |> assign(:host, WebhookViews.url_host(assigns.endpoint.url))
      |> assign(:typed_url, typed_url(assigns.form))

    ~H"""
    <.form
      for={@form}
      id={"webhook-edit-form-#{@endpoint.id}"}
      phx-change="validate_edit"
      phx-submit="save_edit"
      phx-value-id={@endpoint.id}
      phx-target={@myself}
      style={[
        "margin-top: 10px; padding: 12px; border-radius: 8px;",
        "background: var(--surface-sunken); border: 1px solid var(--line);"
      ]}
    >
      <h4 style="margin: 0 0 10px; font-size: 12.5px; font-weight: 600; color: var(--ink);">
        {gettext("Edit endpoint")}
      </h4>
      <div style="display: flex; flex-wrap: wrap; gap: 10px;">
        <div style={[label_style(), "flex: 0 1 180px;"]}>
          <span class="ucase" style={caption_style()}>{gettext("Kind")}</span>
          <span
            data-edit-kind={@endpoint.kind}
            style="height: 32px; display: flex; align-items: center; font-size: 12.5px; color: var(--ink);"
          >
            {WebhookKinds.label(@endpoint.kind)}
          </span>
        </div>
        <label style={[label_style(), "flex: 1 1 260px;"]}>
          <span class="ucase" style={caption_style()}>{gettext("URL")}</span>
          <input
            type="text"
            inputmode="url"
            autocomplete="off"
            maxlength="2048"
            id={"webhook-edit-url-#{@endpoint.id}"}
            name={@form[:url].name}
            value={@typed_url}
            placeholder={@host}
            style={input_style()}
          />
          <span
            data-edit-url-hint
            style="font-size: 11px; color: var(--ink-3); line-height: 1.4;"
          >
            {gettext("Leave blank to keep the current URL (%{host}).", host: @host)}
            {WebhookKinds.url_hint(@endpoint.kind)}
          </span>
          <span
            :if={WebhookKinds.signed?(@endpoint.kind)}
            data-rotate-note
            style="font-size: 11px; color: var(--ink-3); line-height: 1.4;"
          >
            {gettext(
              "The signing secret stays the same. If the new address belongs to a different receiver, use Rotate secret to replace it."
            )}
          </span>
          <.field_errors field={@form[:url]} />
        </label>
      </div>
      <.events_fieldset form={@form} />
      <div style="display: flex; justify-content: flex-end; gap: 8px; margin-top: 12px;">
        <button
          id={"webhook-edit-cancel-#{@endpoint.id}"}
          type="button"
          phx-click="cancel_edit"
          phx-target={@myself}
          style={[
            "padding: 6px 12px; border-radius: 5px; cursor: pointer;",
            "background: var(--surface); border: 1px solid var(--line-strong);",
            "color: var(--ink); font-size: 12px; font-weight: 500;"
          ]}
        >
          {gettext("Cancel")}
        </button>
        <button
          type="submit"
          phx-disable-with={gettext("Saving...")}
          style={[
            "padding: 6px 12px; border-radius: 5px; border: none;",
            "background: var(--ink); color: var(--color-base-100);",
            "font-size: 12px; font-weight: 500; cursor: pointer;"
          ]}
        >
          {gettext("Save")}
        </button>
      </div>
    </.form>
    """
  end

  # Only the URL the owner typed, never the field's value, which falls back
  # to the stored URL.
  defp typed_url(%Phoenix.HTML.Form{params: %{"url" => url}}) when is_binary(url), do: url
  defp typed_url(_form), do: ""

  attr :form, Phoenix.HTML.Form, required: true

  # The event checkboxes. The hidden empty value comes first so unticking
  # every box is submitted, and refused, rather than leaving the field out.
  defp events_fieldset(assigns) do
    assigns = assign(assigns, :selected, List.wrap(assigns.form[:event_types].value))

    ~H"""
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
