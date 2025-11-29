defmodule KanbanWeb.IssueLive.FormComponent do
  @moduledoc """
  LiveView component for submitting GitHub issues.
  """
  use KanbanWeb, :live_component

  alias Kanban.GitHub

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-50 rounded-lg p-6 border border-gray-200">
      <h3 class="text-lg font-semibold text-gray-800 mb-4">
        {gettext("Submit an Issue")}
      </h3>

      <%= if @submitted do %>
        <div class="bg-green-50 border border-green-200 rounded-lg p-4">
          <div class="flex items-center gap-2 text-green-800">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
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
              <label for="issue_title" class="block text-sm font-medium text-gray-700 mb-1">
                {gettext("Title")}
              </label>
              <input
                type="text"
                name="issue[title]"
                id="issue_title"
                value={@form[:title].value}
                required
                class={"w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 #{if @form[:title].errors != [], do: "border-red-500", else: "border-gray-300"}"}
                placeholder={gettext("Brief description of the issue")}
              />
              <%= for error <- @form[:title].errors do %>
                <p class="mt-1 text-sm text-red-600">{translate_error(error)}</p>
              <% end %>
            </div>

            <div>
              <label for="issue_label" class="block text-sm font-medium text-gray-700 mb-1">
                {gettext("Type")}
              </label>
              <select
                name="issue[label]"
                id="issue_label"
                class="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              >
                <%= for {display, value} <- label_options() do %>
                  <option value={value} selected={@form[:label].value == value}>
                    {display}
                  </option>
                <% end %>
              </select>
            </div>

            <div>
              <label for="issue_body" class="block text-sm font-medium text-gray-700 mb-1">
                {gettext("Description")}
              </label>
              <textarea
                name="issue[body]"
                id="issue_body"
                rows="5"
                required
                class={"w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 #{if @form[:body].errors != [], do: "border-red-500", else: "border-gray-300"}"}
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
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span class="font-medium">{gettext("Failed to submit issue")}</span>
                </div>
                <p class="mt-1 text-sm text-red-700">{@error}</p>
              </div>
            <% end %>
          </div>
        </.form>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:submitted, fn -> false end)
     |> assign_new(:issue_url, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:form, fn -> to_form(default_params(), as: "issue") end)}
  end

  @impl true
  def handle_event("validate", %{"issue" => params}, socket) do
    form = to_form(params, as: "issue", errors: validate(params))
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"issue" => params}, socket) do
    case validate(params) do
      [] ->
        case GitHub.create_issue(params["title"], params["body"], [params["label"]]) do
          {:ok, url} ->
            {:noreply,
             socket
             |> assign(:submitted, true)
             |> assign(:issue_url, url)
             |> assign(:error, nil)}

          {:error, :not_configured} ->
            {:noreply,
             assign(socket, :error, gettext("GitHub integration is not configured"))}

          {:error, reason} ->
            {:noreply, assign(socket, :error, inspect(reason))}
        end

      errors ->
        form = to_form(params, as: "issue", errors: errors)
        {:noreply, assign(socket, form: form)}
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

  defp default_params do
    %{"title" => "", "body" => "", "label" => "defect"}
  end

  defp validate(params) do
    errors = []

    errors =
      if blank?(params["title"]) do
        [{:title, {gettext("can't be blank"), []}} | errors]
      else
        errors
      end

    errors =
      if blank?(params["body"]) do
        [{:body, {gettext("can't be blank"), []}} | errors]
      else
        errors
      end

    errors
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
