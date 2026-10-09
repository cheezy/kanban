defmodule KanbanWeb.LabelChip do
  @moduledoc """
  Renders a board label as a coloured chip (W2233).

  Each colour in `Kanban.Labels.Label.colors/0` maps to a pair of theme tokens
  defined in both theme blocks of `assets/css/app.css`: a `--label-<color>`
  ink and a `--label-<color>-soft` fill. A soft fill is only ~1.05:1 against
  the surface it sits on, so every chip also carries a `1px solid var(--line)`
  border — the "soft fill plus border" rule from the Chip delineation section
  of `docs/dark-mode-contract.md`. The tokens resolve only inside a
  `.stride-screen` (or `.stride-marketing`) scope, so render chips there.

  Only colour names on the whitelist are ever interpolated into the `style`
  attribute; anything else falls back to gray, so a chip can never carry
  arbitrary CSS. The name is rendered through HEEx and is therefore escaped.
  """
  use KanbanWeb, :html

  alias Kanban.Labels.Label

  @colors Label.colors()
  @color_names Enum.map(@colors, &Atom.to_string/1)

  attr :label, :map, default: nil, doc: "a `%Kanban.Labels.Label{}`; wins over name/color"
  attr :name, :string, default: nil
  attr :color, :any, default: nil, doc: "a colour atom or its string form"
  attr :rest, :global

  def label_chip(assigns) do
    {name, color} = name_and_color(assigns)
    assigns = assign(assigns, name: name, token: color_token(color))

    ~H"""
    <span
      data-label-chip={@token}
      title={@name}
      style={[
        "display: inline-flex; align-items: center; max-width: 16em; min-width: 0;",
        "padding: 2px 8px; border-radius: 999px;",
        "font-size: 11.5px; font-weight: 500; line-height: 1.4;",
        "border: 1px solid var(--line);",
        "background: var(--label-#{@token}-soft); color: var(--label-#{@token});"
      ]}
      {@rest}
    >
      <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
        {@name}
      </span>
    </span>
    """
  end

  @doc """
  Returns the whitelisted token name for a colour: the colour itself when it is
  one of `Kanban.Labels.Label.colors/0` (as an atom or string), else `"gray"`.

  ## Examples

      iex> color_token(:red)
      "red"

      iex> color_token("red;background:url(x)")
      "gray"

  """
  def color_token(color) when color in @colors, do: Atom.to_string(color)
  def color_token(color) when color in @color_names, do: color
  def color_token(_color), do: "gray"

  @doc "The translated display name of a label colour, for colour pickers."
  def color_label(:gray), do: gettext("Gray")
  def color_label(:red), do: gettext("Red")
  def color_label(:orange), do: gettext("Orange")
  def color_label(:yellow), do: gettext("Yellow")
  def color_label(:green), do: gettext("Green")
  def color_label(:teal), do: gettext("Teal")
  def color_label(:blue), do: gettext("Blue")
  def color_label(:purple), do: gettext("Purple")
  def color_label(:pink), do: gettext("Pink")

  defp name_and_color(%{label: %{name: name, color: color}}), do: {name, color}
  defp name_and_color(%{name: name, color: color}), do: {name, color}
end
