defmodule KanbanWeb.MetricsLive.Components.ExportDropdown do
  @moduledoc """
  The PDF and Excel export dropdowns for the metrics pages:
  `export_dropdown/1` for the board metrics pages and
  `workspace_export_dropdown/1` for the workspace metrics page, sharing one
  private markup shell, plus the helpers that build each export link's query
  string from the page's filters.

  Split from `KanbanWeb.MetricsLive.Components` to keep that module under the
  module-size guidance in `AGENTS.md`. Callers import or alias this module
  directly, so HEEx checks each call's attributes at compile time.
  """
  use Phoenix.Component
  use Gettext, backend: KanbanWeb.Gettext

  import KanbanWeb.MetricsLive.Components.Icon

  @doc """
  Renders the metrics export dropdown (PDF + Excel) with shared filter query params.

  The `export_base_path` is the URL path to the export endpoint without
  query parameters (e.g., `"/boards/1/metrics/cycle-time/export"`). The
  current filter values are appended as a query string for the PDF link
  and an additional `format=excel` parameter is added for the Excel link.
  """
  attr :export_base_path, :string, required: true
  attr :time_range, :atom, required: true
  attr :agent_name, :string, default: nil
  attr :exclude_weekends, :boolean, default: false

  def export_dropdown(assigns) do
    assigns =
      assign(assigns,
        pdf_href: build_export_href(assigns, :pdf),
        excel_href: build_export_href(assigns, :excel)
      )

    ~H"""
    <.export_dropdown_shell pdf_href={@pdf_href} excel_href={@excel_href} />
    """
  end

  @doc """
  Renders the workspace metrics export dropdown (PDF + Excel).

  The workspace sibling of `export_dropdown/1`. The two are deliberately
  separate components rather than one parameterized by both pages' filters:
  the board pages filter by time range and agent and have no board subset,
  while the workspace page filters by a day window and a board subset and has
  no agent. A single component taking the union would make every caller pass
  parameters that do not apply to it. Only the markup is shared, through
  `export_dropdown_shell/1`.

  `board_ids` is omitted from the links when the selection is empty, which the
  export route reads as "every visible board" — the same meaning the page gives
  an empty selection. The subset is only ever a hint: the route intersects it
  with the boards the caller may actually see.
  """
  attr :export_base_path, :string, required: true
  attr :window_days, :integer, required: true
  attr :board_ids, :list, default: []
  attr :exclude_weekends, :boolean, default: false
  attr :timezone, :string, required: true

  def workspace_export_dropdown(assigns) do
    assigns =
      assign(assigns,
        pdf_href: build_workspace_export_href(assigns, :pdf),
        excel_href: build_workspace_export_href(assigns, :excel)
      )

    ~H"""
    <.export_dropdown_shell
      id="workspace-export-dropdown"
      pdf_href={@pdf_href}
      excel_href={@excel_href}
    />
    """
  end

  # The markup both dropdowns render. Kept private and href-only so neither
  # page's filter vocabulary leaks into the shared shell.
  attr :id, :string, default: "export-dropdown"
  attr :pdf_href, :string, required: true
  attr :excel_href, :string, required: true

  defp export_dropdown_shell(assigns) do
    ~H"""
    <div style="position: relative; margin-left: 8px;" id={@id} phx-hook="Dropdown">
      <button
        type="button"
        data-dropdown-toggle
        style={[
          "display: inline-flex; align-items: center; gap: 6px;",
          "padding: 6px 10px; border-radius: 6px;",
          "background: var(--surface); color: var(--ink-2);",
          "border: 1px solid var(--line);",
          "font: inherit; font-size: 12px; font-weight: 500;",
          "cursor: pointer;"
        ]}
      >
        <span style="display: inline-flex; color: var(--ink-3);">
          <.icon name="hero-arrow-down-tray" class="h-4 w-4" />
        </span>
        {gettext("Export")}
        <span style="display: inline-flex; color: var(--ink-4);">
          <.icon name="hero-chevron-down" class="h-3 w-3" />
        </span>
      </button>
      <div
        data-dropdown-menu
        class="hidden"
        style={[
          "position: absolute; right: 0; top: 100%; margin-top: 4px;",
          "min-width: 140px; padding: 4px 0; z-index: 50;",
          "background: var(--surface);",
          "border: 1px solid var(--line); border-radius: 6px;",
          "box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);"
        ]}
      >
        <a
          href={@pdf_href}
          target="_blank"
          style={[
            "display: flex; align-items: center; gap: 8px;",
            "padding: 8px 12px;",
            "font-size: 12px; color: var(--ink-2);",
            "text-decoration: none;"
          ]}
        >
          <.icon name="hero-document" class="h-4 w-4" /> {gettext("PDF")}
        </a>
        <a
          href={@excel_href}
          style={[
            "display: flex; align-items: center; gap: 8px;",
            "padding: 8px 12px;",
            "font-size: 12px; color: var(--ink-2);",
            "text-decoration: none;"
          ]}
        >
          <.icon name="hero-table-cells" class="h-4 w-4" /> {gettext("Excel")}
        </a>
      </div>
    </div>
    """
  end

  defp build_export_href(assigns, format) do
    params = [
      {"time_range", Atom.to_string(assigns.time_range)},
      {"agent_name", assigns.agent_name || ""},
      {"exclude_weekends", to_string(assigns.exclude_weekends)}
    ]

    params =
      case format do
        :excel -> [{"format", "excel"} | params]
        _ -> params
      end

    "#{assigns.export_base_path}?#{URI.encode_query(params)}"
  end

  # The timezone is the parameter most easily forgotten here: unlike the other
  # filters it is not a URL parameter on the page, it is read from the browser
  # at mount. Omitting it makes the export bucket days in UTC and disagree with
  # the charts on screen, silently and with no error.
  #
  # Each selected board contributes its own `board_ids[]` pair rather than one
  # joined value. URI.encode_query/1 percent-encodes the brackets, which Plug
  # still decodes back into a list, so the repeated key round-trips.
  defp build_workspace_export_href(assigns, format) do
    params =
      [{"window_days", to_string(assigns.window_days)}] ++
        board_id_params(assigns.board_ids) ++
        [
          {"exclude_weekends", to_string(assigns.exclude_weekends)},
          {"timezone", assigns.timezone}
        ]

    params =
      case format do
        :excel -> [{"format", "excel"} | params]
        _ -> params
      end

    "#{assigns.export_base_path}?#{URI.encode_query(params)}"
  end

  defp board_id_params(board_ids) do
    Enum.map(board_ids || [], fn id -> {"board_ids[]", to_string(id)} end)
  end
end
