defmodule KanbanWeb.TaskLive.Components.DependenciesSection do
  @moduledoc """
  Renders the dependency list for a task. Caller is responsible for the
  outer presence/empty guard.
  """
  use KanbanWeb, :html

  attr :dependencies, :list, required: true

  def dependencies_section(assigns) do
    ~H"""
    <div>
      <h4 class="text-sm font-semibold text-base-content opacity-80 mb-2">
        {gettext("Dependencies")}
      </h4>
      <p class="text-base-content">
        {gettext("Depends on tasks")}: {Enum.join(@dependencies, ", ")}
      </p>
    </div>
    """
  end
end
