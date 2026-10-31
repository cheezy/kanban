defmodule KanbanWeb.HitMeComponents do
  @moduledoc """
  Components for the public `/HitMe` page, the page the printed handout points
  to. They live in their own module so `KanbanWeb.MarketingComponents`, already
  past the module-size guideline, does not grow further.

  Render inside the `.stride-marketing` CSS scope so the `--hitme-*` tokens and
  the `.hitme-*` classes resolve.
  """
  use KanbanWeb, :html

  @placeholder ~r/\{([a-z_]+)\}/
  @whole_placeholder ~r/\A\{([a-z_]+)\}\z/

  @doc """
  Renders a translated sentence whose highlighted words are named placeholders,
  each filled with its translated value inside a styled span.

  Placeholders are written `{name}`, not `%{name}`, so Gettext leaves them for
  this component to fill. Translators get the whole sentence and can move a
  placeholder wherever their language needs it. Every part is rendered as an
  escaped HEEx node, so HTML in the sentence or in a value shows as text. A
  placeholder with no value in `values` renders as its literal text.

  ## Examples

      <.hitme_highlight
        text={gettext("Start with {desire}, leave with {knowledge}")}
        values={%{"desire" => gettext("desire"), "knowledge" => gettext("knowledge")}}
        highlight_class="hitme-accent"
      />
  """
  attr :text, :string, required: true, doc: "The translated sentence, with `{name}` placeholders."

  attr :values, :map,
    default: %{},
    doc: "Translated text for each placeholder, keyed by its name as a string."

  attr :highlight_class, :string,
    default: "hitme-accent",
    doc: "The class of the span around each placeholder value."

  def hitme_highlight(assigns) do
    parts =
      assigns.text
      |> highlight_parts(assigns.values)
      |> Enum.map(fn
        {:highlight, value} -> {assigns.highlight_class, value}
        {:text, value} -> {nil, value}
      end)

    assigns = assign(assigns, :parts, parts)

    # One element on one line, so the formatter adds no whitespace between parts.
    ~H"""
    <span :for={{class, value} <- @parts} class={class}>{value}</span>
    """
  end

  @doc """
  Splits `text` into `{:text, string}` and `{:highlight, string}` parts,
  replacing each `{name}` placeholder that has a value in `values` with a
  highlight. Unknown placeholders stay as literal text.
  """
  def highlight_parts(text, values) when is_binary(text) and is_map(values) do
    @placeholder
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&to_part(&1, values))
  end

  defp to_part(segment, values) do
    with [name] <- Regex.run(@whole_placeholder, segment, capture: :all_but_first),
         {:ok, value} <- Map.fetch(values, name) do
      {:highlight, value}
    else
      _ -> {:text, segment}
    end
  end
end
