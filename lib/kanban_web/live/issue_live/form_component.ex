defmodule KanbanWeb.IssueLive.FormComponent do
  @moduledoc """
  LiveView component for submitting GitHub issues.
  """
  use KanbanWeb, :live_component

  alias Kanban.GitHub

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-6 border border-base-300">
      <h3 class="text-lg font-semibold text-base-content mb-4">
        {gettext("Submit an Issue")}
      </h3>

      <%= if @submitted do %>
        <div class="bg-green-50 border border-green-200 rounded-lg p-4">
          <div class="flex items-center gap-2 text-green-800">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 13l4 4L19 7"
              />
            </svg>
            <span class="font-medium">{gettext("Issue submitted successfully!")}</span>
          </div>
          <p class="mt-2 text-sm text-green-700">
            {gettext("View your issue on")}
            <a href={@issue_url} target="_blank" class="underline hover:text-green-900">
              GitHub
            </a>
          </p>
          <button
            type="button"
            phx-click="reset"
            phx-target={@myself}
            class="mt-3 text-sm text-green-700 hover:text-green-900 underline"
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
        >
          <div class="space-y-4">
            <div>
              <label
                for="issue_title"
                class="block text-sm font-medium text-base-content opacity-80 mb-1"
              >
                {gettext("Title")}
              </label>
              <input
                type="text"
                name="issue[title]"
                id="issue_title"
                value={@form[:title].value}
                required
                class={"w-full px-3 py-2 h-10 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 #{if @form[:title].errors != [], do: "border-red-500", else: "border-base-300"}"}
                placeholder={gettext("Brief description of the issue")}
              />
              <%= for error <- @form[:title].errors do %>
                <p class="mt-1 text-sm text-red-600">{translate_error(error)}</p>
              <% end %>
            </div>

            <div>
              <label
                for="issue_label"
                class="block text-sm font-medium text-base-content opacity-80 mb-1"
              >
                {gettext("Type")}
              </label>
              <select
                name="issue[label]"
                id="issue_label"
                class={"w-full px-3 py-2 h-10 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 #{if @form[:label].errors != [], do: "border-red-500", else: "border-base-300"}"}
              >
                <%= for {display, value} <- label_options() do %>
                  <option value={value} selected={@form[:label].value == value}>
                    {display}
                  </option>
                <% end %>
              </select>
              <%= for error <- @form[:label].errors do %>
                <p class="mt-1 text-sm text-red-600">{translate_error(error)}</p>
              <% end %>
            </div>

            <div>
              <label
                for="issue_body"
                class="block text-sm font-medium text-base-content opacity-80 mb-1"
              >
                {gettext("Description")}
              </label>
              <textarea
                name="issue[body]"
                id="issue_body"
                rows="5"
                required
                class={"w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 #{if @form[:body].errors != [], do: "border-red-500", else: "border-base-300"}"}
                placeholder={gettext("Please provide details about the issue or feature request")}
              >{@form[:body].value}</textarea>
              <%= for error <- @form[:body].errors do %>
                <p class="mt-1 text-sm text-red-600">{translate_error(error)}</p>
              <% end %>
            </div>

            <div class="pt-2">
              <button
                type="submit"
                phx-disable-with={gettext("Submitting...")}
                class="w-full sm:w-auto px-6 py-2 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {gettext("Submit Issue")}
              </button>
            </div>

            <%= if @error do %>
              <div class="bg-red-50 border border-red-200 rounded-lg p-4">
                <div class="flex items-center gap-2 text-red-800">
                  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span class="font-medium">{gettext("Failed to submit issue")}</span>
                </div>
                <p class="mt-1 text-sm text-red-700">{@error}</p>
              </div>
            <% end %>
          </div>
        </.form>

        <div class="mt-4 pt-4 border-t border-base-300">
          <a
            href="https://github.com/cheezy/kanban/issues"
            target="_blank"
            class="inline-flex items-center gap-2 text-sm text-blue-600 hover:text-blue-800 hover:underline"
          >
            <svg
              class="w-4 h-4"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              xmlns="http://www.w3.org/2000/svg"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
              />
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
        {:noreply,
         socket
         |> assign(:submitted, true)
         |> assign(:issue_url, url)
         |> assign(:error, nil)
         |> assign(:last_submission_at, System.system_time(:second))}

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
    errors = []

    errors =
      cond do
        blank?(params["title"]) ->
          [{:title, {gettext("can't be blank"), []}} | errors]

        too_long?(params["title"], @title_max_length) ->
          [
            {:title, {gettext("must be %{n} characters or fewer", n: @title_max_length), []}}
            | errors
          ]

        true ->
          errors
      end

    errors =
      cond do
        blank?(params["body"]) ->
          [{:body, {gettext("can't be blank"), []}} | errors]

        too_long?(params["body"], @body_max_length) ->
          [
            {:body, {gettext("must be %{n} characters or fewer", n: @body_max_length), []}}
            | errors
          ]

        true ->
          errors
      end

    errors =
      if params["label"] in allowed_label_values() do
        errors
      else
        [{:label, {gettext("must be one of the listed options"), []}} | errors]
      end

    errors
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
