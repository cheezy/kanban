defmodule KanbanWeb.Avatar do
  @moduledoc """
  Shared avatar components for agent/human identity squares.

  Two public function components:

    * `avatar/1` — a single avatar. Agents render as a 4px-radius square;
      humans as a circle. Palette is resolved from a named string
      (`"agent-claude"`, `"human-blue"`, …) — see `avatar_color/2`.
    * `avatar_stack/1` — a horizontally overlapping row of avatars with
      an optional `+N` overflow chip.

  Originally lived as private helpers inside `KanbanWeb.MarketingMiniBoard`;
  extracted so the Boards index can reuse the same identity surface.

  Palette and initials algorithm are preserved verbatim from the source
  module so the existing marketing-mini-board HTML stays byte-identical
  when called with `size={14}` — the prior hardcoded value.
  """
  use KanbanWeb, :html

  # Background for an avatar with no palette (an unknown agent's "?", or a
  # palette key not listed below). Like the palette colours it is fixed rather
  # than a theme token, because the initials are always near-black: a neutral
  # grey at 70% lightness keeps them about 7:1 in both themes, where
  # var(--ink-3) gave 3.4:1 in light mode.
  @neutral_background "oklch(70% 0.005 270)"

  @doc """
  Renders one avatar.

  ## Attrs

    * `kind` — `:agent` or `:human`. Required. Drives the border-radius
      (4px for agent, 50% for human).
    * `name` — display name. Required. Initials are derived from this
      string (single-word → 1 letter, multi-word → first letter of the
      first two words, uppercased).
    * `palette` — named palette key (e.g. `"agent-claude"`,
      `"human-blue"`). Optional; missing or unknown keys fall back to
      `var(--ink-3)`.
    * `size` — pixel size for both width and height. Default 18.
    * `ring` — when true, adds a 2px surface-colored ring around the
      avatar (used in dense lists like the Boards index member stack).
      Default false.
  """
  attr :kind, :atom, required: true, values: [:agent, :human]
  attr :name, :string, required: true
  attr :palette, :string, default: nil
  attr :size, :integer, default: 18
  attr :ring, :boolean, default: false

  def avatar(assigns) do
    ~H"""
    <span
      class="inline-flex items-center justify-center font-semibold"
      style={
        [
          "width: #{@size}px; height: #{@size}px; font-size: #{font_size_for(@size)}px; letter-spacing: -0.02em;",
          "background: #{avatar_color(@kind, @palette)};",
          # dark-mode-ignore: avatar text is always near-black because the
          # avatar background is a fixed medium-saturation color that does
          # NOT flip with the theme — using a theme-aware ink would produce
          # white-on-color in dark mode and fail WCAG AA on tiny initials.
          "color: oklch(18% 0.005 270);",
          "border-radius: #{if @kind == :agent, do: "4px", else: "50%"};",
          if(@ring, do: "box-shadow: 0 0 0 2px var(--surface);", else: "")
        ]
      }
    >
      {avatar_initials(@name)}
    </span>
    """
  end

  @doc """
  Renders a horizontal row of overlapping avatars. Each avatar after the
  first sits 5px to the left of the previous, giving the classic stacked
  look. When `members` has more than `max` entries, a `+N` overflow chip
  is appended.

  ## Attrs

    * `members` — list of maps with `:kind`, `:name`, and (optionally)
      `:palette` keys. Required.
    * `max` — the maximum number of avatars to render before the overflow
      chip kicks in. Default 5.
    * `size` — pixel size passed through to each `avatar/1`. Default 18.
  """
  attr :members, :list, required: true
  attr :max, :integer, default: 5
  attr :size, :integer, default: 18

  def avatar_stack(assigns) do
    visible = Enum.take(assigns.members, assigns.max)
    overflow = max(length(assigns.members) - assigns.max, 0)

    assigns =
      assigns
      |> assign(visible: visible, overflow: overflow)
      |> assign(:roster_title, roster_title(assigns.members))

    ~H"""
    <span class="inline-flex items-center" title={@roster_title}>
      <span
        :for={{member, index} <- Enum.with_index(@visible)}
        style={if index == 0, do: "", else: "margin-left: -5px;"}
        title={member.name}
      >
        <.avatar
          kind={member.kind}
          name={member.name}
          palette={Map.get(member, :palette)}
          size={@size}
          ring
        />
      </span>
      <span
        :if={@overflow > 0}
        class="inline-flex items-center justify-center font-semibold"
        style={[
          "margin-left: -5px;",
          "width: #{@size}px; height: #{@size}px; font-size: #{font_size_for(@size)}px;",
          "background: var(--ink-3); color: var(--surface); border-radius: 50%;",
          "box-shadow: 0 0 0 2px var(--surface);"
        ]}
        title={overflow_title(@members, @max)}
      >
        +{@overflow}
      </span>
    </span>
    """
  end

  defp roster_title(members) when is_list(members) do
    members
    |> Enum.map(& &1.name)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(", ")
  end

  defp overflow_title(members, max) when is_list(members) and is_integer(max) do
    members
    |> Enum.drop(max)
    |> Enum.map(& &1.name)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(", ")
  end

  # Tuned so size 14 → 6 (legacy marketing-mini-board size) and size 18 → 8.
  defp font_size_for(size) when is_integer(size) do
    max(div(size * 4, 9), 6)
  end

  defp avatar_color(:agent, palette) when is_binary(palette) do
    case palette do
      "agent-claude" -> "oklch(70% 0.16 47)"
      "agent-cursor" -> "oklch(60% 0.16 240)"
      "agent-aider" -> "oklch(60% 0.14 155)"
      "agent-codex" -> "oklch(60% 0.18 277)"
      _ -> @neutral_background
    end
  end

  defp avatar_color(:human, palette) when is_binary(palette) do
    case palette do
      "human-blue" -> "oklch(60% 0.10 240)"
      "human-amber" -> "oklch(60% 0.10 60)"
      "human-green" -> "oklch(60% 0.10 155)"
      "human-pink" -> "oklch(60% 0.10 320)"
      _ -> @neutral_background
    end
  end

  defp avatar_color(_kind, _palette), do: @neutral_background

  defp avatar_initials(name), do: initials(name)

  @doc """
  Up to two uppercase initials for `name`: the first letter or digit of each
  of its first two words, where `separator` (a string or regex, default a
  space) splits words.

  Punctuation is skipped, so `"Bob [Bracket] (QA)"` gives `"BB"`, not `"B["`,
  and a word with no letter or digit is ignored. Returns `"?"` when nothing
  usable is left.

      iex> KanbanWeb.Avatar.initials("Jamie K")
      "JK"

      iex> KanbanWeb.Avatar.initials("Bob [Bracket] (QA)")
      "BB"

      iex> KanbanWeb.Avatar.initials("-- !!")
      "?"
  """
  @spec initials(term(), String.t() | Regex.t()) :: String.t()
  def initials(name, separator \\ " ")

  def initials(name, separator) when is_binary(name) do
    name
    |> String.split(separator, trim: true)
    |> Enum.flat_map(&(Regex.run(~r/[\p{L}\p{N}]/u, &1) || []))
    |> Enum.take(2)
    |> case do
      [] -> "?"
      letters -> letters |> Enum.join() |> String.upcase()
    end
  end

  def initials(_name, _separator), do: "?"
end
