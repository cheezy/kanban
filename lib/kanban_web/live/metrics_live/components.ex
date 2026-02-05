defmodule KanbanWeb.MetricsLive.Components do
  @moduledoc """
  Shared UI components for metrics pages.

  Provides reusable function components for displaying metrics data,
  including stat cards, bar charts, and filter controls. All components
  support dark mode and are optimized for PDF export (no JavaScript).
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  Renders a stat card with title, value, and optional subtitle.

  ## Examples

      <.stat_card title="Throughput" value="42" subtitle="tasks completed" icon="hero-chart-bar" />
      <.stat_card title="Cycle Time" value="2.5h" subtitle="median: 2.1h" icon="hero-clock" />
  """
  attr :title, :string, required: true, doc: "the card title"
  attr :value, :string, required: true, doc: "the main value to display"
  attr :subtitle, :string, default: nil, doc: "optional subtitle text"
  attr :icon, :string, default: nil, doc: "heroicon name for the card icon"
  attr :link, :string, default: nil, doc: "optional link URL for 'View details'"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def stat_card(assigns) do
    ~H"""
    <div class={["bg-white dark:bg-zinc-800 overflow-hidden shadow rounded-lg", @class]}>
      <div class="p-5">
        <div class="flex items-center">
          <div :if={@icon} class="flex-shrink-0">
            <.icon name={@icon} class="h-6 w-6 text-gray-400 dark:text-gray-500" />
          </div>
          <div class={["w-0 flex-1", @icon && "ml-5"]}>
            <dl>
              <dt class="text-sm font-medium text-gray-500 dark:text-gray-400 truncate">
                {@title}
              </dt>
              <dd class="flex items-baseline">
                <div class="text-2xl font-semibold text-gray-900 dark:text-gray-100">
                  {@value}
                </div>
              </dd>
              <dd :if={@subtitle} class="mt-1 flex items-baseline">
                <div class="text-sm text-gray-900 dark:text-gray-100">
                  {@subtitle}
                </div>
              </dd>
            </dl>
          </div>
        </div>
      </div>
      <div :if={@link} class="bg-gray-50 dark:bg-zinc-900 px-5 py-3">
        <div class="text-sm">
          <a
            href={@link}
            class="font-medium text-indigo-600 dark:text-indigo-400 hover:text-indigo-500"
          >
            View details
          </a>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a horizontal bar chart using pure CSS (no JavaScript).

  Each bar displays a label, value, and percentage-based width.
  Designed to work in PDF exports and print media.

  ## Examples

      <.bar_chart
        title="Throughput by Day"
        data={[
          %{label: "Monday", value: 5, max: 10},
          %{label: "Tuesday", value: 8, max: 10}
        ]}
      />
  """
  attr :title, :string, required: true, doc: "the chart title"
  attr :data, :list, required: true, doc: "list of maps with :label, :value, and :max keys"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def bar_chart(assigns) do
    ~H"""
    <div class={["bg-white dark:bg-zinc-800 shadow rounded-lg p-5", @class]}>
      <h3 class="text-lg font-medium text-gray-900 dark:text-gray-100 mb-4">{@title}</h3>
      <div class="space-y-3">
        <div :for={item <- @data} class="relative">
          <div class="flex items-center justify-between mb-1">
            <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
              {item.label}
            </span>
            <span class="text-sm text-gray-500 dark:text-gray-400">
              {item.value}
            </span>
          </div>
          <div class="w-full bg-gray-200 dark:bg-zinc-700 rounded-full h-2">
            <div
              class="bg-indigo-600 dark:bg-indigo-500 h-2 rounded-full transition-all duration-300"
              style={"width: #{calculate_percentage(item.value, item.max)}%"}
              role="progressbar"
              aria-valuenow={item.value}
              aria-valuemin="0"
              aria-valuemax={item.max}
              aria-label={"#{item.label}: #{item.value}"}
            >
            </div>
          </div>
        </div>
        <div :if={Enum.empty?(@data)} class="text-center py-8 text-gray-500 dark:text-gray-400">
          No data available
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a time range filter dropdown.

  ## Examples

      <.time_range_filter
        current_range={:last_30_days}
        on_change="filter_time_range"
      />
  """
  attr :current_range, :atom, required: true, doc: "currently selected time range atom"
  attr :on_change, :string, required: true, doc: "phx-change event name"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def time_range_filter(assigns) do
    ~H"""
    <div class={["flex-1 min-w-[200px]", @class]}>
      <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
        Time Range
      </label>
      <select
        phx-change={@on_change}
        name="time_range"
        class="block w-full rounded-md border-gray-300 dark:border-zinc-600 bg-white dark:bg-zinc-700 text-gray-900 dark:text-gray-100 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
        aria-label="Select time range"
      >
        <option value="last_7_days" selected={@current_range == :last_7_days}>
          Last 7 Days
        </option>
        <option value="last_30_days" selected={@current_range == :last_30_days}>
          Last 30 Days
        </option>
        <option value="last_90_days" selected={@current_range == :last_90_days}>
          Last 90 Days
        </option>
        <option value="all_time" selected={@current_range == :all_time}>All Time</option>
      </select>
    </div>
    """
  end

  @doc """
  Renders an agent filter dropdown.

  ## Examples

      <.agent_filter
        agents={["Claude Sonnet 4.5", "GPT-4"]}
        current_agent={nil}
        on_change="filter_agent"
      />
  """
  attr :agents, :list, default: [], doc: "list of available agent names"
  attr :current_agent, :string, default: nil, doc: "currently selected agent name"
  attr :on_change, :string, required: true, doc: "phx-change event name"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def agent_filter(assigns) do
    ~H"""
    <div class={["flex-1 min-w-[200px]", @class]}>
      <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
        Agent Filter
      </label>
      <select
        phx-change={@on_change}
        name="agent_name"
        class="block w-full rounded-md border-gray-300 dark:border-zinc-600 bg-white dark:bg-zinc-700 text-gray-900 dark:text-gray-100 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
        aria-label="Filter by agent"
      >
        <option value="" selected={is_nil(@current_agent)}>All Agents</option>
        <option
          :for={agent <- @agents}
          value={agent}
          selected={@current_agent == agent}
        >
          {agent}
        </option>
      </select>
    </div>
    """
  end

  @doc """
  Renders a weekend exclusion toggle checkbox.

  ## Examples

      <.weekend_toggle
        exclude_weekends={false}
        on_change="toggle_weekends"
      />
  """
  attr :exclude_weekends, :boolean, required: true, doc: "whether weekends are excluded"
  attr :on_change, :string, required: true, doc: "phx-change event name"
  attr :class, :string, default: "", doc: "additional CSS classes"

  def weekend_toggle(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 mt-6", @class]}>
      <input
        type="checkbox"
        id="exclude_weekends"
        phx-change={@on_change}
        name="exclude_weekends"
        value={to_string(!@exclude_weekends)}
        checked={@exclude_weekends}
        class="h-4 w-4 rounded border-gray-300 dark:border-zinc-600 text-indigo-600 focus:ring-indigo-500"
        aria-label="Exclude weekends from calculations"
      />
      <label
        for="exclude_weekends"
        class="text-sm font-medium text-gray-700 dark:text-gray-300"
      >
        Exclude Weekends
      </label>
    </div>
    """
  end

  # Private helper for .icon component
  attr :name, :string, required: true
  attr :class, :string, default: nil

  defp icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # Helper function to calculate percentage for bar chart
  defp calculate_percentage(_value, 0), do: 0

  defp calculate_percentage(value, max) when value > 0 and max > 0 do
    min(Float.round(value / max * 100, 1), 100)
  end

  defp calculate_percentage(_, _), do: 0
end
