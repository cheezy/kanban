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

  @doc """
  Renders an elaborate metrics filter form with time range, agent, and weekend toggle.
  """
  attr :time_range, :atom, required: true
  attr :agent_name, :string, default: nil
  attr :exclude_weekends, :boolean, required: true
  attr :agents, :list, required: true
  attr :view_name, :string, required: true
  attr :show_agent_filter, :boolean, default: true

  def metric_filters(assigns) do
    ~H"""
    <div class="mt-8 bg-gradient-to-br from-white via-indigo-50/30 to-purple-50/30 dark:from-zinc-800 dark:via-zinc-800 dark:to-zinc-900 shadow-xl rounded-2xl p-6 border-2 border-indigo-100 dark:border-zinc-700 backdrop-blur-sm">
      <div class="flex items-center gap-3 mb-6 pb-4 border-b-2 border-indigo-100 dark:border-zinc-700">
        <div class="p-2 bg-gradient-to-br from-indigo-500 to-purple-600 rounded-lg shadow-lg">
          <.icon name="hero-funnel-solid" class="h-5 w-5 text-white" />
        </div>
        <div>
          <h3 class="text-lg font-bold text-gray-900 dark:text-gray-100">Filters</h3>
          <p class="text-xs text-gray-600 dark:text-gray-400">
            Customize your {@view_name} view
          </p>
        </div>
      </div>
      <form phx-change="filter_change">
        <div class="flex flex-wrap gap-4 items-center">
          <div class="flex items-center gap-3 px-4 py-3 bg-gradient-to-r from-white to-gray-50 dark:from-zinc-700 dark:to-zinc-700/50 rounded-xl border-2 border-gray-200 dark:border-zinc-600 shadow-sm hover:shadow-md hover:border-indigo-200 dark:hover:border-indigo-700 transition-all duration-200 flex-1 min-w-[280px]">
            <label class="flex items-center gap-2 text-sm font-bold text-gray-700 dark:text-gray-200 whitespace-nowrap">
              <div class="p-1.5 bg-indigo-100 dark:bg-indigo-900/40 rounded-md">
                <.icon name="hero-calendar" class="h-4 w-4 text-indigo-600 dark:text-indigo-400" />
              </div>
              <span class="uppercase tracking-wide text-xs">Time Range</span>
            </label>
            <select
              name="time_range"
              class="flex-1 rounded-lg border-0 bg-transparent text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-indigo-500/20 sm:text-sm font-medium transition-all duration-200"
            >
              <option value="today" selected={@time_range == :today}>
                🌅 Today
              </option>
              <option value="last_7_days" selected={@time_range == :last_7_days}>
                📅 Last 7 Days
              </option>
              <option value="last_30_days" selected={@time_range == :last_30_days}>
                📅 Last 30 Days
              </option>
              <option value="last_90_days" selected={@time_range == :last_90_days}>
                📅 Last 90 Days
              </option>
              <option value="all_time" selected={@time_range == :all_time}>
                ♾️ All Time
              </option>
            </select>
          </div>

          <div
            :if={@show_agent_filter}
            class="flex items-center gap-3 px-4 py-3 bg-gradient-to-r from-white to-gray-50 dark:from-zinc-700 dark:to-zinc-700/50 rounded-xl border-2 border-gray-200 dark:border-zinc-600 shadow-sm hover:shadow-md hover:border-purple-200 dark:hover:border-purple-700 transition-all duration-200 flex-1 min-w-[280px]"
          >
            <label class="flex items-center gap-2 text-sm font-bold text-gray-700 dark:text-gray-200 whitespace-nowrap">
              <div class="p-1.5 bg-purple-100 dark:bg-purple-900/40 rounded-md">
                <.icon
                  name="hero-user-circle"
                  class="h-4 w-4 text-purple-600 dark:text-purple-400"
                />
              </div>
              <span class="uppercase tracking-wide text-xs">Agent Filter</span>
            </label>
            <select
              name="agent_name"
              class="flex-1 rounded-lg border-0 bg-transparent text-gray-900 dark:text-gray-100 focus:ring-2 focus:ring-purple-500/20 sm:text-sm font-medium transition-all duration-200"
            >
              <option value="" selected={is_nil(@agent_name)}>🤖 All Agents</option>
              <option :for={agent <- @agents} value={agent} selected={@agent_name == agent}>
                {agent}
              </option>
            </select>
          </div>

          <div class="flex items-center gap-3 px-5 py-3 bg-gradient-to-r from-white to-gray-50 dark:from-zinc-700 dark:to-zinc-700/50 rounded-xl border-2 border-gray-200 dark:border-zinc-600 shadow-sm hover:shadow-md hover:border-indigo-200 dark:hover:border-indigo-700 transition-all duration-200 cursor-pointer group">
            <input
              type="checkbox"
              id="exclude_weekends"
              name="exclude_weekends"
              value="true"
              checked={@exclude_weekends}
              class="h-5 w-5 rounded-md border-2 border-gray-300 dark:border-zinc-500 text-indigo-600 focus:ring-4 focus:ring-indigo-500/20 transition-all cursor-pointer"
            />
            <label
              for="exclude_weekends"
              class="text-sm font-semibold text-gray-700 dark:text-gray-200 cursor-pointer group-hover:text-indigo-600 dark:group-hover:text-indigo-400 transition-colors flex items-center gap-2"
            >
              <.icon
                name="hero-calendar-days"
                class="h-4 w-4 text-gray-500 dark:text-gray-400 group-hover:text-indigo-600 dark:group-hover:text-indigo-400 transition-colors"
              />
              <span>Exclude Weekends</span>
            </label>
          </div>
        </div>
      </form>
    </div>
    """
  end

  @doc """
  Renders a 4-card summary statistics display with gradient styling.
  """
  attr :stats, :map, required: true
  attr :format_fn, :any, required: true

  def summary_stats(assigns) do
    ~H"""
    <div class="mt-8 grid grid-cols-1 gap-6 lg:grid-cols-4">
      <div class="group bg-gradient-to-br from-white to-blue-50 dark:from-zinc-800 dark:to-zinc-900 overflow-hidden shadow-lg rounded-xl border-l-4 border-blue-500 hover:shadow-2xl transition-all duration-300 p-6">
        <div class="flex items-center gap-3 mb-2">
          <div class="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-lg">
            <.icon name="hero-clock-solid" class="h-6 w-6 text-blue-600 dark:text-blue-400" />
          </div>
          <h3 class="text-sm font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wide">
            Average
          </h3>
        </div>
        <div class="text-4xl font-bold text-gray-900 dark:text-gray-100">
          {@format_fn.(@stats.average_hours * 3600)}
        </div>
      </div>

      <div class="group bg-gradient-to-br from-white to-purple-50 dark:from-zinc-800 dark:to-zinc-900 overflow-hidden shadow-lg rounded-xl border-l-4 border-purple-500 hover:shadow-2xl transition-all duration-300 p-6">
        <div class="flex items-center gap-3 mb-2">
          <div class="p-2 bg-purple-100 dark:bg-purple-900/30 rounded-lg">
            <.icon name="hero-chart-bar-solid" class="h-6 w-6 text-purple-600 dark:text-purple-400" />
          </div>
          <h3 class="text-sm font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wide">
            Median
          </h3>
        </div>
        <div class="text-4xl font-bold text-gray-900 dark:text-gray-100">
          {@format_fn.(@stats.median_hours * 3600)}
        </div>
      </div>

      <div class="group bg-gradient-to-br from-white to-green-50 dark:from-zinc-800 dark:to-zinc-900 overflow-hidden shadow-lg rounded-xl border-l-4 border-green-500 hover:shadow-2xl transition-all duration-300 p-6">
        <div class="flex items-center gap-3 mb-2">
          <div class="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
            <.icon name="hero-arrow-down-solid" class="h-6 w-6 text-green-600 dark:text-green-400" />
          </div>
          <h3 class="text-sm font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wide">
            Min
          </h3>
        </div>
        <div class="text-4xl font-bold text-gray-900 dark:text-gray-100">
          {@format_fn.(@stats.min_hours * 3600)}
        </div>
      </div>

      <div class="group bg-gradient-to-br from-white to-red-50 dark:from-zinc-800 dark:to-zinc-900 overflow-hidden shadow-lg rounded-xl border-l-4 border-red-500 hover:shadow-2xl transition-all duration-300 p-6">
        <div class="flex items-center gap-3 mb-2">
          <div class="p-2 bg-red-100 dark:bg-red-900/30 rounded-lg">
            <.icon name="hero-arrow-up-solid" class="h-6 w-6 text-red-600 dark:text-red-400" />
          </div>
          <h3 class="text-sm font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wide">
            Max
          </h3>
        </div>
        <div class="text-4xl font-bold text-gray-900 dark:text-gray-100">
          {@format_fn.(@stats.max_hours * 3600)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders an SVG trend chart with optional trend line.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :daily_times, :list, required: true
  attr :format_fn, :any, required: true
  attr :empty_message, :string, default: "No data available"

  def trend_chart(assigns) do
    ~H"""
    <div class="mt-8 bg-white dark:bg-zinc-800 shadow-xl rounded-2xl p-6 border-2 border-gray-100 dark:border-zinc-700">
      <div class="flex items-center gap-3 mb-6 pb-4 border-b-2 border-gray-100 dark:border-zinc-700">
        <div class="p-2 bg-gradient-to-br from-indigo-500 to-blue-600 rounded-lg shadow-lg">
          <.icon name="hero-chart-bar-solid" class="h-5 w-5 text-white" />
        </div>
        <div>
          <h3 class="text-lg font-bold text-gray-900 dark:text-gray-100">{@title}</h3>
          <p class="text-xs text-gray-600 dark:text-gray-400">
            {@subtitle}
          </p>
        </div>
      </div>

      <div :if={length(@daily_times) > 0} class="relative">
        <svg viewBox="0 0 800 400" class="w-full h-auto" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="lineGradient" x1="0%" y1="0%" x2="100%" y2="0%">
              <stop offset="0%" style="stop-color:rgb(99, 102, 241);stop-opacity:1" />
              <stop offset="100%" style="stop-color:rgb(59, 130, 246);stop-opacity:1" />
            </linearGradient>
          </defs>
          <%= for i <- 0..4 do %>
            <line
              x1="60"
              y1={50 + i * 75}
              x2="780"
              y2={50 + i * 75}
              stroke="currentColor"
              class="stroke-gray-200 dark:stroke-zinc-700"
              stroke-width="1"
            />
          <% end %>
          <%= if length(@daily_times) > 0 do %>
            <% max_hours = KanbanWeb.MetricsLive.Helpers.get_max_time(@daily_times) %>
            <% label_interval = max(1, div(length(@daily_times), 10)) %>
            <% points =
              @daily_times
              |> Enum.with_index()
              |> Enum.map(fn {day, index} ->
                x = 60 + index * (720 / max(length(@daily_times) - 1, 1))
                y = 350 - day.average_hours / max(max_hours, 1) * 300
                "#{x},#{y}"
              end)
              |> Enum.join(" ") %>
            <polyline
              points={points}
              fill="none"
              stroke="url(#lineGradient)"
              stroke-width="3"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
            <%= if trend = KanbanWeb.MetricsLive.Helpers.calculate_trend_line(@daily_times) do %>
              <% trend_points =
                [0, length(@daily_times) - 1]
                |> Enum.map(fn index ->
                  x = 60 + index * (720 / max(length(@daily_times) - 1, 1))
                  trend_y = trend.slope * index + trend.intercept
                  y = 350 - trend_y / max(max_hours, 1) * 300
                  "#{x},#{y}"
                end)
                |> Enum.join(" ") %>
              <polyline
                points={trend_points}
                fill="none"
                stroke="#9ca3af"
                stroke-width="2"
                stroke-dasharray="5,5"
                stroke-linecap="round"
                opacity="0.7"
              />
            <% end %>
            <%= for {day, index} <- Enum.with_index(@daily_times) do %>
              <% x = 60 + index * (720 / max(length(@daily_times) - 1, 1)) %>
              <% y = 350 - day.average_hours / max(max_hours, 1) * 300 %>
              <% last_index = length(@daily_times) - 1 %>
              <% is_last = index == last_index %>
              <% is_interval_match = rem(index, label_interval) == 0 %>
              <% distance_from_last = last_index - index %>
              <% show_label =
                is_interval_match or (is_last and distance_from_last >= div(label_interval, 2)) %>
              <circle cx={x} cy={y} r="5" fill="rgb(59, 130, 246)" stroke="white" stroke-width="2" />
              <%= if show_label do %>
                <text
                  x={x}
                  y="380"
                  text-anchor="middle"
                  class="fill-gray-600 dark:fill-gray-400 text-xs"
                  font-size="12"
                >
                  {Calendar.strftime(day.date, "%m/%d")}
                </text>
              <% end %>
            <% end %>
            <%= for i <- 0..4 do %>
              <% value = max_hours * (4 - i) / 4 %>
              <text
                x="50"
                y={55 + i * 75}
                text-anchor="end"
                class="fill-gray-600 dark:fill-gray-400 text-xs"
                font-size="12"
              >
                {@format_fn.(value)}
              </text>
            <% end %>
          <% end %>
        </svg>
      </div>

      <div :if={length(@daily_times) == 0} class="text-center py-8">
        <.icon
          name="hero-chart-bar"
          class="h-12 w-12 text-gray-300 dark:text-gray-600 mx-auto mb-3"
        />
        <p class="text-gray-500 dark:text-gray-400">{@empty_message}</p>
      </div>
    </div>
    """
  end

  @doc """
  Renders a centered empty state with icon and message.
  """
  attr :icon_name, :string, required: true
  attr :message, :string, required: true
  attr :size, :string, default: "large"

  def empty_state(assigns) do
    icon_class =
      if assigns.size == "large",
        do: "h-16 w-16",
        else: "h-12 w-12"

    text_class =
      if assigns.size == "large",
        do: "text-lg font-medium",
        else: "text-base"

    assigns = assign(assigns, icon_class: icon_class, text_class: text_class)

    ~H"""
    <div class="text-center py-12">
      <.icon
        name={@icon_name}
        class={"#{@icon_class} text-gray-300 dark:text-gray-600 mx-auto mb-4"}
      />
      <p class={"text-gray-500 dark:text-gray-400 #{@text_class}"}>
        {@message}
      </p>
    </div>
    """
  end

  # Helper function to calculate percentage for bar chart
  defp calculate_percentage(_value, 0), do: 0

  defp calculate_percentage(value, max) when value > 0 and max > 0 do
    min(Float.round(value / max * 100, 1), 100)
  end

  defp calculate_percentage(_, _), do: 0
end
