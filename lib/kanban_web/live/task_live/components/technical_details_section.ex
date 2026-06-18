defmodule KanbanWeb.TaskLive.Components.TechnicalDetailsSection do
  @moduledoc """
  Renders the free-form `technical_details` map generically: each top-level
  key becomes a labelled block, with scalar values shown inline and nested
  object/array values pretty-printed as JSON. Because the field is free-form,
  keys are iterated generically rather than matched against a fixed set.

  The caller is responsible for the outer visibility/presence guard; the
  component also guards internally so it renders nothing for an empty map.
  """
  use KanbanWeb, :html

  attr :technical_details, :map, required: true

  def technical_details_section(assigns) do
    ~H"""
    <div
      :if={map_size(@technical_details) > 0}
      class="bg-[var(--stride-violet-soft)] border border-[var(--stride-violet)] rounded-lg p-4"
    >
      <div class="space-y-3">
        <%!-- Keys are free-form agent-supplied data, not UI chrome, so they are
        rendered verbatim (auto-escaped) and intentionally not wrapped in gettext. --%>
        <div :for={{key, value} <- @technical_details}>
          <p class="text-xs font-semibold text-[var(--stride-violet-ink)] opacity-70 mb-1">
            {key}
          </p>
          {render_value(value)}
        </div>
      </div>
    </div>
    """
  end

  # Scalars render inline as escaped text; nested object/array values are
  # pretty-printed as JSON inside a wrapping <pre>. All output flows through
  # HEEx auto-escaping — never raw/1 — so stored agent content cannot inject
  # markup.
  defp render_value(value) when is_binary(value) do
    assigns = %{value: value}

    ~H"""
    <p class="text-[var(--stride-violet-ink)] text-xs whitespace-pre-wrap break-words">{@value}</p>
    """
  end

  defp render_value(value) when is_number(value) or is_boolean(value) do
    assigns = %{value: to_string(value)}

    ~H"""
    <p class="text-[var(--stride-violet-ink)] font-mono text-xs">{@value}</p>
    """
  end

  defp render_value(value) when is_list(value) or is_map(value) do
    assigns = %{json: Jason.encode!(value, pretty: true)}

    ~H"""
    <pre class="text-[var(--stride-violet-ink)] font-mono text-xs whitespace-pre-wrap break-words overflow-x-auto">{@json}</pre>
    """
  end

  defp render_value(value) do
    assigns = %{value: inspect(value)}

    ~H"""
    <p class="text-[var(--stride-violet-ink)] font-mono text-xs">{@value}</p>
    """
  end
end
