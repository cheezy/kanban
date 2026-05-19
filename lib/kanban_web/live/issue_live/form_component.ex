defmodule KanbanWeb.IssueLive.FormComponent do
  @moduledoc """
  LiveView component for submitting GitHub issues.
  """
  use KanbanWeb, :live_component

  alias Kanban.GitHub

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="stride-screen"
      style="background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 24px;"
    >
      <h3 style="margin: 0 0 16px; font-size: 17px; font-weight: 600; letter-spacing: -0.015em; color: var(--ink);">
        {gettext("Submit an Issue")}
      </h3>

      <%= if @submitted do %>
        <div style="background: var(--st-done-soft); border: 1px solid var(--st-done); border-radius: 8px; padding: 14px;">
          <div style="display: flex; align-items: center; gap: 8px; color: var(--st-done);">
            <svg
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M5 13l4 4L19 7" />
            </svg>
            <span style="font-weight: 500;">{gettext("Issue submitted successfully!")}</span>
          </div>
          <p style="margin: 8px 0 0; font-size: 13px; color: var(--ink-2);">
            {gettext("View your issue on")}
            <a
              href={@issue_url}
              target="_blank"
              rel="noopener noreferrer"
              style="color: var(--ink); text-decoration: underline;"
            >
              GitHub
            </a>
          </p>
          <button
            type="button"
            phx-click="reset"
            phx-target={@myself}
            style="margin-top: 12px; font-size: 12.5px; color: var(--ink-2); background: transparent; border: none; padding: 0; cursor: pointer; text-decoration: underline;"
          >
            {gettext("Submit another issue")}
          </button>
        </div>
      <% else %>
        <.form
          for={@form}
          id="issue-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
          style="display: flex; flex-direction: column; gap: 14px;"
        >
          <label style="display: flex; flex-direction: column; gap: 5px;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Title")}
            </span>
            <input
              type="text"
              name="issue[title]"
              id="issue_title"
              value={@form[:title].value}
              required
              placeholder={gettext("Brief description of the issue")}
              style={[
                "padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid ",
                if(@form[:title].errors != [],
                  do: "var(--st-blocked); ",
                  else: "var(--line-strong); "
                ),
                "font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit;"
              ]}
            />
            <%= for error <- @form[:title].errors do %>
              <span style="font-size: 11.5px; color: var(--st-blocked);">
                {translate_error(error)}
              </span>
            <% end %>
          </label>

          <label style="display: flex; flex-direction: column; gap: 5px;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Type")}
            </span>
            <select
              name="issue[label]"
              id="issue_label"
              style={[
                "padding: 0 10px; height: 36px; border-radius: 6px; background: var(--surface); border: 1px solid ",
                if(@form[:label].errors != [],
                  do: "var(--st-blocked); ",
                  else: "var(--line-strong); "
                ),
                "font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit;"
              ]}
            >
              <%= for {display, value} <- label_options() do %>
                <option value={value} selected={@form[:label].value == value}>
                  {display}
                </option>
              <% end %>
            </select>
            <%= for error <- @form[:label].errors do %>
              <span style="font-size: 11.5px; color: var(--st-blocked);">
                {translate_error(error)}
              </span>
            <% end %>
          </label>

          <label style="display: flex; flex-direction: column; gap: 5px;">
            <span style="font-size: 12px; font-weight: 500; color: var(--ink-2);">
              {gettext("Description")}
            </span>
            <textarea
              name="issue[body]"
              id="issue_body"
              rows="5"
              required
              placeholder={gettext("Please provide details about the issue or feature request")}
              style={[
                "padding: 10px; border-radius: 6px; background: var(--surface); border: 1px solid ",
                if(@form[:body].errors != [],
                  do: "var(--st-blocked); ",
                  else: "var(--line-strong); "
                ),
                "font-size: 13.5px; color: var(--ink); outline: none; font-family: inherit; resize: vertical;"
              ]}
            >{@form[:body].value}</textarea>
            <%= for error <- @form[:body].errors do %>
              <span style="font-size: 11.5px; color: var(--st-blocked);">
                {translate_error(error)}
              </span>
            <% end %>
          </label>

          <div style="padding-top: 4px;">
            <button
              type="submit"
              phx-disable-with={gettext("Submitting...")}
              style="height: 40px; padding: 0 18px; border-radius: 6px; background: var(--ink); color: var(--color-primary-content); border: none; font-size: 13.5px; font-weight: 500; letter-spacing: -0.005em; cursor: pointer; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) inset, 0 1px 3px rgba(0, 0, 0, 0.2);"
            >
              {gettext("Submit Issue")}
            </button>
          </div>

          <%= if @error do %>
            <div style="background: var(--st-blocked-soft); border: 1px solid var(--st-blocked); border-radius: 8px; padding: 14px;">
              <div style="display: flex; align-items: center; gap: 8px; color: var(--st-blocked);">
                <svg
                  width="20"
                  height="20"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                </svg>
                <span style="font-weight: 500;">{gettext("Failed to submit issue")}</span>
              </div>
              <p style="margin: 4px 0 0; font-size: 13px; color: var(--ink-2);">{@error}</p>
            </div>
          <% end %>
        </.form>

        <div style="margin-top: 16px; padding-top: 16px; border-top: 1px solid var(--line);">
          <a
            href="https://github.com/cheezy/kanban/issues"
            target="_blank"
            rel="noopener noreferrer"
            style="display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; color: var(--ink-2); text-decoration: none;"
          >
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
            </svg>
            {gettext("See existing issues")}
          </a>
        </div>
      <% end %>
    </div>
    """
  end

  # W402: bound the abuse surface of the publicly-mountable issue form. Even
  # without a session-level or IP-level rate limiter (would require a new dep
  # like Hammer or PlugAttack), these guards stop the runaway-loop spam shape
  # and bound payload size so a malicious client cannot exhaust the server's
  # GitHub rate limit with a single request. Future work: add Hammer-backed
  # per-IP throttling once a dep upgrade can be scoped.
  @title_max_length 200
  @body_max_length 4_000
  @min_submission_interval_seconds 30

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:submitted, fn -> false end)
     |> assign_new(:issue_url, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:last_submission_at, fn -> nil end)
     |> assign_new(:form, fn -> to_form(default_params(), as: "issue") end)}
  end

  @impl true
  def handle_event("validate", %{"issue" => params}, socket) do
    form = to_form(params, as: "issue", errors: validate(params))
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"issue" => params}, socket) do
    cond do
      rate_limited?(socket) ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Please wait a moment before submitting another issue.")
         )}

      validate(params) != [] ->
        form = to_form(params, as: "issue", errors: validate(params))
        {:noreply, assign(socket, form: form)}

      true ->
        do_submit(socket, params)
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:submitted, false)
     |> assign(:issue_url, nil)
     |> assign(:error, nil)
     |> assign(:form, to_form(default_params(), as: "issue"))}
  end

  defp do_submit(socket, params) do
    case GitHub.create_issue(params["title"], params["body"], [params["label"]]) do
      {:ok, url} ->
        {:noreply, assign_submission_success(socket, url)}

      {:error, :not_configured} ->
        {:noreply, assign(socket, :error, gettext("GitHub integration is not configured"))}

      {:error, _reason} ->
        # W402: do not surface inspect(reason) — request/response details may
        # leak internal URLs, headers, or other server metadata. Log the full
        # reason server-side and return a fixed gettext message to the client.
        require Logger
        Logger.error("KanbanWeb.IssueLive.FormComponent: GitHub.create_issue failed")

        {:noreply,
         assign(
           socket,
           :error,
           gettext("Failed to submit the issue. Please try again later.")
         )}
    end
  end

  defp assign_submission_success(socket, url) do
    socket
    |> assign(:submitted, true)
    |> assign(:issue_url, url)
    |> assign(:error, nil)
    |> assign(:last_submission_at, System.system_time(:second))
  end

  defp rate_limited?(socket) do
    case socket.assigns[:last_submission_at] do
      nil ->
        false

      last ->
        System.system_time(:second) - last < @min_submission_interval_seconds
    end
  end

  defp default_params do
    %{"title" => "", "body" => "", "label" => "defect"}
  end

  defp validate(params) do
    []
    |> validate_title(params["title"])
    |> validate_body(params["body"])
    |> validate_label(params["label"])
  end

  defp validate_title(errors, title) do
    cond do
      blank?(title) ->
        [{:title, {gettext("can't be blank"), []}} | errors]

      too_long?(title, @title_max_length) ->
        [
          {:title, {gettext("must be %{n} characters or fewer", n: @title_max_length), []}}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_body(errors, body) do
    cond do
      blank?(body) ->
        [{:body, {gettext("can't be blank"), []}} | errors]

      too_long?(body, @body_max_length) ->
        [
          {:body, {gettext("must be %{n} characters or fewer", n: @body_max_length), []}}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_label(errors, label) do
    if label in allowed_label_values() do
      errors
    else
      [{:label, {gettext("must be one of the listed options"), []}} | errors]
    end
  end

  defp too_long?(nil, _), do: false
  defp too_long?(str, max) when is_binary(str), do: String.length(str) > max
  defp too_long?(_, _), do: false

  defp allowed_label_values do
    Enum.map(label_options(), fn {_display, value} -> value end)
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  defp label_options do
    [
      {gettext("Defect"), "defect"},
      {gettext("Feature Request"), "feature request"},
      {gettext("Translation"), "translation"}
    ]
  end
end
