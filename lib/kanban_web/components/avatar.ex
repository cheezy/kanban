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
      class="inline-flex items-center justify-center text-primary-content font-semibold"
      style={[
        "width: #{@size}px; height: #{@size}px; font-size: #{font_size_for(@size)}px; letter-spacing: -0.02em;",
        "background: #{avatar_color(@kind, @palette)};",
        "border-radius: #{if @kind == :agent, do: "4px", else: "50%"};",
        if(@ring, do: "box-shadow: 0 0 0 2px var(--surface);", else: "")
      ]}
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
        class="inline-flex items-center justify-center font-semibold text-primary-content"
        style={[
          "margin-left: -5px;",
          "width: #{@size}px; height: #{@size}px; font-size: #{font_size_for(@size)}px;",
          "background: var(--ink-3); border-radius: 50%;",
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
      _ -> "var(--ink-3)"
    end
  end

  defp avatar_color(:human, palette) when is_binary(palette) do
    case palette do
      "human-blue" -> "oklch(60% 0.10 240)"
      "human-amber" -> "oklch(60% 0.10 60)"
      "human-green" -> "oklch(60% 0.10 155)"
      "human-pink" -> "oklch(60% 0.10 320)"
      _ -> "var(--ink-3)"
    end
  end

  defp avatar_color(_kind, _palette), do: "var(--ink-3)"

  defp avatar_initials(name) when is_binary(name) and byte_size(name) > 0 do
    name
    |> String.split(" ", trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp avatar_initials(_), do: "?"
end
