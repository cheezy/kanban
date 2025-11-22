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
     |> assign(:can_modify, Map.get(assigns, :can_modify, false))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="border-b border-gray-200 pb-4">
        <div class="flex items-start justify-between mb-2">
          <div class="flex items-center gap-3">
            <h2 class="text-2xl font-bold text-gray-900">{@task.identifier}</h2>
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
        <h3 class="text-xl text-gray-800">{@task.title}</h3>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div>
          <h4 class="text-sm font-semibold text-gray-700 mb-1">{gettext("Status")}</h4>
          <p class="text-gray-900">{@task.column.name}</p>
        </div>

        <div>
          <h4 class="text-sm font-semibold text-gray-700 mb-1">{gettext("Priority")}</h4>
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
          <h4 class="text-sm font-semibold text-gray-700 mb-1">{gettext("Assigned To")}</h4>
          <p class="text-gray-900">
            <%= if @task.assigned_to do %>
              {@task.assigned_to.name || @task.assigned_to.email}
            <% else %>
              {gettext("Unassigned")}
            <% end %>
          </p>
        </div>

        <div>
          <h4 class="text-sm font-semibold text-gray-700 mb-1">{gettext("Created")}</h4>
          <p class="text-gray-900">{Calendar.strftime(@task.inserted_at, "%B %d, %Y at %I:%M %p")}</p>
        </div>
      </div>

      <%= if @task.description do %>
        <div>
          <h4 class="text-sm font-semibold text-gray-700 mb-1">{gettext("Description")}</h4>
          <p class="text-gray-900 whitespace-pre-wrap">{@task.description}</p>
        </div>
      <% end %>

      <div>
        <h4 class="text-sm font-semibold text-gray-700 mb-2">{gettext("History")}</h4>
        <%= if Enum.empty?(@task.task_histories) do %>
          <p class="text-gray-500 text-sm">{gettext("No history available")}</p>
        <% else %>
          <div class="space-y-3 max-h-48 overflow-y-auto">
            <%= for history <- @task.task_histories do %>
              <div class="flex items-start gap-2 text-sm">
                <div class="mt-0.5">
                  <%= if history.type == :creation do %>
                    <.icon name="hero-plus-circle" class="w-4 h-4 text-green-600" />
                  <% else %>
                    <.icon name="hero-arrow-right-circle" class="w-4 h-4 text-blue-600" />
                  <% end %>
                </div>
                <div class="flex-1">
                  <p class="text-gray-900">
                    <span class="font-semibold">
                      {case history.type do
                        :creation -> gettext("Created")
                        :move -> gettext("Moved")
                      end}
                    </span>
                    <%= if history.type == :move do %>
                      {gettext("from")} <span class="font-semibold">{history.from_column}</span> {gettext(
                        "to"
                      )} <span class="font-semibold">{history.to_column}</span>
                    <% end %>
                  </p>
                  <p class="text-xs text-gray-500">
                    {Calendar.strftime(history.inserted_at, "%B %d, %Y at %I:%M %p")}
                  </p>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div>
        <h4 class="text-sm font-semibold text-gray-700 mb-2">{gettext("Comments")}</h4>
        <%= if Enum.empty?(@task.comments) do %>
          <p class="text-gray-500 text-sm">{gettext("No comments yet")}</p>
        <% else %>
          <div class="space-y-3 max-h-48 overflow-y-auto">
            <%= for comment <- @task.comments do %>
              <div class="flex items-start gap-2 text-sm">
                <div class="mt-0.5">
                  <.icon name="hero-chat-bubble-left" class="w-4 h-4 text-gray-400" />
                </div>
                <div class="flex-1">
                  <p class="text-gray-900 whitespace-pre-wrap">{comment.content}</p>
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
