defmodule KanbanWeb.TaskLive.Components.ExplorerResultSection do
  @moduledoc """
  Renders the `explorer_result` recorded at task completion — either the
  dispatched shape (summary plus a human-readable duration) or the skip
  shape (summary plus the translated skip reason).

  Caller is responsible for the outer presence/visibility guard —
  `KanbanWeb.ReviewReportHelpers.explorer_panel_visible?/1`.

  Every field is optional at render time. Legacy grace-mode rows may omit
  the summary, the duration, or the reason, so each is rendered only when
  it is actually usable rather than assumed present.
  """
  use KanbanWeb, :html

  alias KanbanWeb.ReviewReportHelpers

  attr :explorer_result, :map, required: true

  def explorer_result_section(assigns) do
    ~H"""
    <div class="bg-[var(--stride-orange-soft)] border border-[var(--stride-orange)] rounded-lg p-4">
      <h4 class="text-sm font-semibold text-[var(--stride-orange-ink)] mb-2">
        {gettext("Explorer Result")}
      </h4>
      <div class="text-[var(--stride-orange-ink)] text-sm space-y-2">
        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <span class="font-semibold break-words">
            {status_label(@explorer_result)}
          </span>
          <span :if={duration_label(@explorer_result)} class="text-xs opacity-70">
            {duration_label(@explorer_result)}
          </span>
          <p :if={reason_label(@explorer_result)} class="w-full text-xs opacity-80 break-words">
            <span class="font-semibold">{gettext("Reason")}:</span> {reason_label(@explorer_result)}
          </p>
        </div>
        <p
          :if={summary(@explorer_result)}
          class="text-xs opacity-80 whitespace-pre-wrap break-words"
        >
          {summary(@explorer_result)}
        </p>
      </div>
    </div>
    """
  end

  # explorer_result round-trips through a jsonb column, so its keys arrive as
  # strings — but tests and in-memory assigns may hand over an atom-keyed
  # literal, so tolerate both the way the module's sibling helpers do. Both
  # key forms are compile-time literals from this module; nothing the caller
  # supplies is ever converted to an atom.
  defp field(result, string_key, atom_key) when is_map(result) do
    case Map.fetch(result, string_key) do
      {:ok, value} -> value
      :error -> Map.get(result, atom_key)
    end
  end

  defp field(_result, _string_key, _atom_key), do: nil

  # A legacy grace-mode row can carry the JSON string "false" rather than the
  # boolean, and reporting that as "Dispatched" would misstate the one fact
  # this panel exists to convey. The asymmetry is deliberate: there is no
  # matching "true" arm because anything unrecognized already falls through to
  # "Dispatched", which is the correct default and matches
  # workflow_steps_section.ex — so a "true" arm would be dead code.
  defp status_label(result) do
    case field(result, "dispatched", :dispatched) do
      flag when flag in [false, "false"] -> gettext("Not dispatched")
      _ -> gettext("Dispatched")
    end
  end

  defp summary(result) do
    case field(result, "summary", :summary) do
      summary when is_binary(summary) ->
        case String.trim(summary) do
          "" -> nil
          _ -> summary
        end

      _ ->
        nil
    end
  end

  defp reason_label(result) do
    case field(result, "reason", :reason) do
      reason when is_binary(reason) and reason != "" ->
        case ReviewReportHelpers.skip_reason_label(reason) do
          "" -> nil
          label -> label
        end

      _ ->
        nil
    end
  end

  # KanbanWeb.Duration.format_minutes/2 is deliberately not reused here: it
  # takes MINUTES, and an explorer dispatch is normally seconds to a few
  # minutes, so every short run would collapse to "0m". Formatting stays
  # local and small instead of bending a helper built for a different unit.
  defp duration_label(result) do
    result |> field("duration_ms", :duration_ms) |> format_duration()
  end

  defp format_duration(ms) when is_integer(ms) and ms >= 0 and ms < 1_000 do
    gettext("%{ms} ms", ms: ms)
  end

  # A whole number of seconds renders without a fractional part, so 12_000 ms
  # reads "12s" rather than "12.0s".
  defp format_duration(ms) when is_integer(ms) and ms >= 0 and ms < 60_000 do
    seconds =
      case rem(ms, 1_000) do
        0 -> div(ms, 1_000)
        _ -> Float.round(ms / 1_000, 1)
      end

    gettext("%{seconds}s", seconds: seconds)
  end

  defp format_duration(ms) when is_integer(ms) and ms >= 0 do
    gettext("%{minutes}m %{seconds}s",
      minutes: div(ms, 60_000),
      seconds: div(rem(ms, 60_000), 1_000)
    )
  end

  defp format_duration(_), do: nil
end
