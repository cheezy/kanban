defmodule KanbanWeb.BoardsHeader do
  @moduledoc """
  Workspace-level stat cluster for the Boards index title row: the four
  aggregated To Do/Doing/Review/Done counts plus an avatar stack of every
  person and agent across the boards the viewer can access.

  This is the workspace counterpart to `KanbanWeb.BoardHeader`, which shows
  the same four counts for a single board. It reuses that module's `kv/1`
  stat presentation, its 1px divider, and the same `Avatar.avatar_stack/1`
  placement, so the two headers read as one family.

  It renders only the right-hand cluster — not a full band with its own
  title. The Boards index already owns its `<h1>Boards</h1>` and "N active"
  chip inside a `sm:justify-between` row whose right side is empty; this
  component is the missing right side. Wrapping that title in a bordered,
  `var(--surface)`-backed band the way `BoardHeader` does would double the
  page's padding, float a stray rule mid-page, and duplicate the heading.
  The root element carries `margin-left: auto` so it right-aligns in any
  flex row, not only a `justify-between` one.

  Purely presentational: it performs no queries and holds no state. The
  caller supplies both aggregates, produced by
  `Kanban.Boards.workspace_metrics/2` and
  `Kanban.Boards.list_workspace_members/2`. Deduplication of the roster
  already happened in the context — this component never dedups.

  ## Rendering scope

  This cluster must stay inside a `.stride-screen` (or `.stride-marketing`)
  wrapper, which `Layouts.app` applies for the Boards index. Outside that
  scope three things silently degrade: the `.ucase` label loses its
  uppercase transform, it loses its `var(--ink-3)` color and inherits
  whatever is in scope, and — worst — the divider's `background: var(--line)`
  resolves to `transparent`, because `background` is not inherited, so an
  undefined custom property computes to the initial value. In an isolated
  component test the label renders unstyled for the same reason, which is
  expected.

  ## Contrast

  Every foreground clears WCAG AA against the canvas the Boards index
  actually paints (`bg-base-100` light / `dark:bg-base-200` dark): `--ink`
  17.8:1 / 16.8:1, `--st-doing` 7.2:1 / 10.1:1, `--st-review` 7.5:1 / 8.8:1,
  `--st-done` 6.4:1 / 10.3:1, and the `--ink-3` label 5.2:1 / 8.7:1. Note
  that `mix dark_mode.contrast` does NOT verify these pairings: its status
  specs only check each `--st-*` against its own `-soft` chip, and no spec
  crosses the Stride palette with the daisyUI canvas. The numbers above were
  measured directly and are not protected by the gate, so a future `--st-*`
  retune tuned to the `-soft` pairing could regress this component silently.
  """
  use KanbanWeb, :html

  alias KanbanWeb.Avatar

  @doc """
  Renders the Boards index stat cluster.

  ## Attrs

    * `metrics` — the aggregated counts map returned by
      `Kanban.Boards.workspace_metrics/2` (or `workspace_metrics_from/1`):
      `%{open:, doing:, review:, done:}`. Required. Any key that is missing
      or not an integer renders as `0`.
    * `members` — already-deduplicated `%{kind:, name:, palette:}` maps from
      `Kanban.Boards.list_workspace_members/2`, passed straight through to
      `Avatar.avatar_stack/1`. Every entry must carry `:name`. Defaults to
      `[]`; empty or `nil` hides both the divider and the stack.

      Supply `:palette` too. `Avatar` tolerates its absence but falls back to
      a `var(--ink-3)` chip, and its hardcoded near-black initials measure
      only 3.4:1 against that in light mode — below AA. Every palette
      `KanbanWeb.AvatarPalette` produces is a known key, so the context's own
      output never hits that branch; a hand-built member list can.
  """
  attr :metrics, :map,
    required: true,
    doc: "Aggregated %{open:, doing:, review:, done:} counts. Missing keys render as 0."

  # Typed :any rather than :list because nil is an accepted value — a caller
  # may bind the assign before the roster has loaded — and :list would warn on
  # a literal nil while the runtime handles it.
  attr :members, :any,
    default: [],
    doc: "Deduplicated %{kind:, name:, palette:} maps. Empty or nil hides the stack."

  def boards_header(assigns) do
    metrics = assigns.metrics || %{}

    assigns =
      assigns
      |> assign(:to_do, count(metrics, :open))
      |> assign(:doing, count(metrics, :doing))
      |> assign(:review, count(metrics, :review))
      |> assign(:done, count(metrics, :done))

    ~H"""
    <div
      data-boards-header
      style={[
        "display: flex; align-items: center; gap: 14px;",
        "flex-wrap: wrap; margin-left: auto;"
      ]}
    >
      <.kv marker="to-do" label={gettext("To Do")} value={@to_do} tone="var(--ink)" />
      <.kv marker="doing" label={gettext("Doing")} value={@doing} tone="var(--st-doing)" />
      <.kv marker="review" label={gettext("Review")} value={@review} tone="var(--st-review)" />
      <.kv marker="done" label={gettext("Done")} value={@done} tone="var(--st-done)" />

      <.members_divider :if={members_present?(@members)} />

      <span
        :if={members_present?(@members)}
        data-boards-header-members
        style="display: inline-flex; align-items: center;"
      >
        <Avatar.avatar_stack members={@members} max={8} size={20} />
      </span>
    </div>
    """
  end

  defp members_divider(assigns) do
    ~H"""
    <span
      data-boards-header-divider
      aria-hidden="true"
      style="width: 1px; height: 24px; background: var(--line);"
    ></span>
    """
  end

  defp members_present?(members) do
    case members do
      list when is_list(list) and list != [] -> true
      _ -> false
    end
  end

  # Aggregated counts come from a context map that may predate a key or
  # carry nil for it; a missing count reads as zero, never as a blank cell.
  # The non-map clause is reachable: `attr :metrics, :map` only checks
  # literals at compile time, so a dynamic assign can still arrive as a
  # non-map, and a header should render zeros rather than take the page down.
  defp count(metrics, key) when is_map(metrics) do
    case Map.get(metrics, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp count(_metrics, _key), do: 0

  attr :marker, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :string, required: true

  defp kv(assigns) do
    ~H"""
    <div
      data-boards-header-kv={@marker}
      style="display: flex; flex-direction: column; align-items: flex-start;"
    >
      <span class="ucase" style="font-size: 9.5px;">{@label}</span>
      <span style={[
        "font-size: 14px; font-weight: 600; color: #{@tone};",
        "font-feature-settings: 'tnum'; letter-spacing: -0.02em;"
      ]}>
        {@value}
      </span>
    </div>
    """
  end
end
