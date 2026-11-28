defmodule KanbanWeb.ReviewQueueSubtitle do
  @moduledoc """
  The Review Queue's subtitle at `/review`: how many tasks wait on the
  viewer, from how many agents, and how long the oldest has waited, from
  `Kanban.Reviews.queue_stats/1`.
  """
  use Gettext, backend: KanbanWeb.Gettext

  @doc """
  "3 tasks from 2 agents waiting on you · oldest 4h ago", without the age
  when the queue reports none, or "0 tasks waiting on you." for an empty
  queue.
  """
  @spec text(map()) :: String.t()
  def text(%{count: 0}) do
    gettext("0 tasks waiting on you.")
  end

  def text(%{count: count, distinct_agents: agents, oldest_age_minutes: oldest}) do
    head =
      ngettext(
        "%{count} task from %{agents} agent waiting on you",
        "%{count} tasks from %{agents} agents waiting on you",
        count,
        count: count,
        agents: agents
      )

    case oldest_age_label(oldest) do
      nil -> head
      age -> "#{head} · #{gettext("oldest %{age}", age: age)}"
    end
  end

  defp oldest_age_label(nil), do: nil
  defp oldest_age_label(0), do: gettext("just now")
  defp oldest_age_label(minutes) when minutes < 60, do: gettext("%{m}m ago", m: minutes)

  defp oldest_age_label(minutes) when minutes < 1440,
    do: gettext("%{h}h ago", h: div(minutes, 60))

  defp oldest_age_label(minutes), do: gettext("%{d}d ago", d: div(minutes, 1440))
end
