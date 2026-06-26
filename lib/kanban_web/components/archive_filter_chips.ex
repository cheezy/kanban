defmodule KanbanWeb.ArchiveFilterChips do
  @moduledoc """
  Filter chip row for the Archive view at `/boards/:id/archive`.

  Renders the "All" chip followed by the "Completed" archive-reason
  chip with the per-bucket counts from `Kanban.Archives.archive_stats/1`.
  A divider separates these from the active "Assignee" filter chip and
  the visually disabled "Date range" placeholder chip that maps to a
  v1-out-of-scope filter.

  Reason chips emit a `phx-click` event with `phx-value-reason` set to
  the string form of the reason atom (e.g. `"completed"`) or `"all"`.
  The "Assignee" chip toggles a dropdown of the board's archived
  assignees; each item fires `on_assignee_select` with `phx-value-assignee`
  set to the user id (string), `"unassigned"`, or `"all"`. The parent
  LiveView coerces those strings — never `String.to_atom/1`.

  Mirrors the `FilterChip` block in
  `design_handoff_stride/design_source/screens/archive.jsx` lines
  280-300.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar
  alias KanbanWeb.AvatarPalette

  @reasons [
    {:completed, "completed", "done"}
  ]

  @doc """
  Renders the filter chip row.

  ## Attrs

    * `counts` — map keyed by `:all` and the `:completed` reason atom.
      Missing keys render as `0`.
    * `active` — currently active filter, one of `:all` or any reason
      atom. Drives the inverted (ink-bg / white-fg) chip styling.
    * `on_filter_change` — required `phx-click` event name. Fired with
      `phx-value-reason` set to the string form of the chip's reason
      (e.g. `"all"`, `"completed"`).
    * `assignees` — list of `%{id, name}` maps for the assignee dropdown.
    * `assignee_filter` — current selection, one of `:all`, an integer
      user id, or `:unassigned`. Drives the inverted chip styling.
    * `assignee_menu_open` — whether the assignee dropdown is open.
    * `has_unassigned` — whether to offer the "Unassigned" option.
    * `on_assignee_toggle` — event name to open/close the dropdown.
    * `on_assignee_select` — event name fired on item click, carrying
      `phx-value-assignee` (`"all"`, `"unassigned"`, or the user id).
  """
  attr :counts, :map, required: true
  attr :active, :atom, required: true
  attr :on_filter_change, :string, required: true
  attr :assignees, :list, default: []
  attr :assignee_filter, :any, default: :all
  attr :assignee_menu_open, :boolean, default: false
  attr :has_unassigned, :boolean, default: false
  attr :on_assignee_toggle, :string, required: true
  attr :on_assignee_select, :string, required: true

  def archive_filter_chips(assigns) do
    ~H"""
    <div
      data-archive-filter-chips
      style={[
        "display: flex; align-items: center; gap: 6px;",
        "flex-wrap: wrap;",
        "padding: 0 28px 12px;"
      ]}
    >
      <.chip
        marker="all"
        reason_value="all"
        label={gettext("All")}
        count={Map.get(@counts, :all, 0)}
        show_count={false}
        active={@active == :all}
        tone={nil}
        on_filter_change={@on_filter_change}
      />

      <.chip
        :for={{reason, value, tone} <- reasons()}
        marker={value}
        reason_value={value}
        label={reason_label(reason)}
        count={Map.get(@counts, reason, 0)}
        show_count={true}
        active={@active == reason}
        tone={tone}
        on_filter_change={@on_filter_change}
      />

      <span
        aria-hidden="true"
        data-archive-filter-divider
        style="width: 1px; height: 18px; background: var(--line); margin: 0 4px;"
      />

      <.assignee_chip
        assignees={@assignees}
        assignee_filter={@assignee_filter}
        menu_open={@assignee_menu_open}
        has_unassigned={@has_unassigned}
        on_toggle={@on_assignee_toggle}
        on_select={@on_assignee_select}
      />
      <.placeholder_chip
        marker="date-range"
        label={gettext("Date range")}
        icon="hero-clock"
      />
    </div>
    """
  end

  # --- Active assignee chip + dropdown -------------------------------------

  attr :assignees, :list, required: true
  attr :assignee_filter, :any, required: true
  attr :menu_open, :boolean, required: true
  attr :has_unassigned, :boolean, required: true
  attr :on_toggle, :string, required: true
  attr :on_select, :string, required: true

  defp assignee_chip(assigns) do
    active? = assigns.assignee_filter != :all
    palette = chip_palette(active?, nil)

    assigns =
      assigns
      |> assign(:active?, active?)
      |> assign(:palette, palette)

    # phx-click-away lives on the wrapper that holds BOTH the toggle button and
    # the dropdown, so clicking the button (inside the wrapper) does not trip
    # click-away while genuine outside clicks still close the menu.
    ~H"""
    <span
      style="position: relative; display: inline-flex;"
      phx-click-away={@menu_open && "close_assignee_menu"}
    >
      <button
        type="button"
        data-archive-filter-chip="assignee"
        aria-haspopup="listbox"
        aria-expanded={if @menu_open, do: "true", else: "false"}
        aria-pressed={if @active?, do: "true", else: "false"}
        phx-click={@on_toggle}
        style={[
          "display: inline-flex; align-items: center; gap: 5px;",
          "padding: 3px 8px; border-radius: 4px;",
          "font: inherit; font-size: 11.5px; font-weight: 500;",
          "border: 1px solid #{@palette.border};",
          "background: #{@palette.bg};",
          "color: #{@palette.fg};",
          "cursor: pointer;"
        ]}
      >
        <.icon name="hero-user" class="w-2.5 h-2.5" />
        <span>{assignee_chip_label(@assignee_filter, @assignees)}</span>
      </button>

      <div
        :if={@menu_open}
        data-archive-assignee-menu
        role="listbox"
        style={[
          "position: absolute; left: 0; top: 28px; z-index: 10;",
          "background: var(--surface);",
          "border: 1px solid var(--line); border-radius: 6px;",
          "box-shadow: 0 4px 14px rgba(0, 0, 0, 0.08);",
          "display: flex; flex-direction: column;",
          "min-width: 180px; max-height: 280px; overflow-y: auto;"
        ]}
      >
        <.assignee_option
          value="all"
          selected={@assignee_filter == :all}
          on_select={@on_select}
          first={true}
        >
          {gettext("All assignees")}
        </.assignee_option>

        <.assignee_option
          :for={a <- @assignees}
          value={a.id}
          selected={@assignee_filter == a.id}
          on_select={@on_select}
          first={false}
        >
          <Avatar.avatar
            kind={:human}
            name={a.name}
            palette={AvatarPalette.for_human(a.id)}
            size={18}
          />
          <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            {a.name}
          </span>
        </.assignee_option>

        <.assignee_option
          :if={@has_unassigned}
          value="unassigned"
          selected={@assignee_filter == :unassigned}
          on_select={@on_select}
          first={false}
        >
          <span style="display: inline-flex; align-items: center; gap: 6px; color: var(--ink-3);">
            <.icon name="hero-user" class="w-3 h-3" />
            <span>{gettext("Unassigned")}</span>
          </span>
        </.assignee_option>
      </div>
    </span>
    """
  end

  attr :value, :any, required: true
  attr :selected, :boolean, required: true
  attr :on_select, :string, required: true
  attr :first, :boolean, default: false
  slot :inner_block, required: true

  defp assignee_option(assigns) do
    ~H"""
    <button
      type="button"
      role="option"
      data-archive-assignee-option={@value}
      aria-selected={if @selected, do: "true", else: "false"}
      phx-click={@on_select}
      phx-value-assignee={@value}
      style={[
        "display: inline-flex; align-items: center; gap: 6px;",
        "padding: 8px 12px; border: 0;",
        if(@first, do: "", else: "border-top: 1px solid var(--line);"),
        if(@selected, do: "background: var(--surface-sunken);", else: "background: transparent;"),
        "text-align: left; font: inherit; font-size: 12px;",
        "color: var(--ink); cursor: pointer;"
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # --- Active chip ---------------------------------------------------------

  attr :marker, :string, required: true
  attr :reason_value, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :show_count, :boolean, required: true
  attr :active, :boolean, required: true
  attr :tone, :any, default: nil
  attr :on_filter_change, :string, required: true

  defp chip(assigns) do
    palette = chip_palette(assigns.active, assigns.tone)
    assigns = assign(assigns, :palette, palette)

    ~H"""
    <button
      type="button"
      data-archive-filter-chip={@marker}
      aria-pressed={if @active, do: "true", else: "false"}
      phx-click={@on_filter_change}
      phx-value-reason={@reason_value}
      style={[
        "display: inline-flex; align-items: center; gap: 5px;",
        "padding: 3px 8px; border-radius: 4px;",
        "font: inherit; font-size: 11.5px; font-weight: 500;",
        "border: 1px solid #{@palette.border};",
        "background: #{@palette.bg};",
        "color: #{@palette.fg};",
        "cursor: pointer;"
      ]}
    >
      <span>{@label}</span>
      <span :if={@show_count} style="font-variant-numeric: tabular-nums;">
        · {@count}
      </span>
    </button>
    """
  end

  # --- Decorative placeholder chip ----------------------------------------

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp placeholder_chip(assigns) do
    ~H"""
    <span
      data-archive-filter-chip-placeholder={@marker}
      aria-disabled="true"
      style={[
        "display: inline-flex; align-items: center; gap: 5px;",
        "padding: 3px 8px; border-radius: 4px;",
        "font-size: 11.5px; font-weight: 500;",
        "border: 1px solid var(--line);",
        "background: var(--surface);",
        "color: var(--ink-3);",
        "cursor: not-allowed; opacity: 0.7;"
      ]}
    >
      <.icon name={@icon} class="w-2.5 h-2.5" />
      <span>{@label}</span>
    </span>
    """
  end

  # --- Helpers -------------------------------------------------------------

  defp reasons, do: @reasons

  defp reason_label(:completed), do: gettext("Completed")

  # Label shown on the assignee chip itself: the generic "Assignee" when no
  # assignee is selected, "Unassigned" for the nil-assignee bucket, or the
  # selected person's name (falling back to "Assignee" if they have left the
  # currently-loaded rows).
  defp assignee_chip_label(:all, _assignees), do: gettext("Assignee")
  defp assignee_chip_label(:unassigned, _assignees), do: gettext("Unassigned")

  defp assignee_chip_label(id, assignees) when is_integer(id) do
    case Enum.find(assignees, &(&1.id == id)) do
      %{name: name} -> name
      nil -> gettext("Assignee")
    end
  end

  # Returns a %{bg, fg, border} map. Active chips invert against the page —
  # bg uses var(--ink) and fg uses var(--surface) so both tokens flip together
  # with the theme, keeping high contrast in both modes (W907 fixed the
  # earlier fg="white" which was invisible in dark mode where --ink flips to
  # near-white).
  defp chip_palette(true, _tone) do
    %{bg: "var(--ink)", fg: "var(--surface)", border: "var(--ink)"}
  end

  defp chip_palette(false, "done") do
    %{
      bg: "var(--st-done-soft)",
      fg: "var(--st-done)",
      border: "transparent"
    }
  end

  defp chip_palette(false, _) do
    %{
      bg: "var(--surface)",
      fg: "var(--ink-2)",
      border: "var(--line)"
    }
  end
end
