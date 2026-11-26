defmodule Kanban.Mobile.TypeScale do
  @moduledoc """
  The native apps' text styles (W2787), which `Kanban.Mobile.Tokens` writes
  into every theme of `mobile/shared/tokens/tokens.json` as `text_style`.

  `assets/css/app.css` gives the web one body style and no named styles, so
  the scale is kept here, beside the generator that reads the stylesheet. The
  sizes, weights, letter spacing and line heights are those of the Stride
  Mobile 1.0 design. A style marked `:body` takes the stylesheet's body letter
  spacing or line height, so those stay in step with the web. The size does
  not: the design sets the apps' running text at 15 pt, while the web's body
  is 13 px (14.5 px below 768 px wide).

  Each style has:

    * `family`: the font token it is drawn in, `font-sans` or `font-mono`
    * `size_pt`: its size at the default text size, in points
    * `weight`: its CSS weight, from 400 to 700
    * `letter_spacing_em` and `line_height`: as CSS's `letter-spacing` in
      `em` and unitless `line-height`
    * `uppercase`: whether its text is shown in capitals

  How a style grows with the reader's text size is each platform's own: iOS
  follows the Dynamic Type style named in `StrideTextStyle.scalesLike`.
  """

  @styles %{
    "large-title" => {"font-sans", 34, 700, -0.03, 1.1, false},
    "title" => {"font-sans", 22, 600, -0.02, 1.2, false},
    "headline" => {"font-sans", 17, 600, :body, 1.3, false},
    "body" => {"font-sans", 15, 400, :body, :body, false},
    "callout" => {"font-sans", 16, 500, -0.01, 1.3, false},
    "subheadline" => {"font-sans", 14, 400, :body, :body, false},
    "footnote" => {"font-sans", 13, 400, :body, :body, false},
    "label" => {"font-mono", 11, 500, 0.04, :body, true},
    "code" => {"font-mono", 12, 400, -0.01, 20 / 12, false}
  }

  @doc """
  The text styles, keyed by name, with `:body` replaced by the stylesheet's
  body `letter_spacing_em` or `line_height` from `type`.
  """
  @spec build(map()) :: %{String.t() => map()}
  def build(%{"letter_spacing_em" => letter_spacing, "line_height" => line_height}) do
    body = %{letter_spacing: letter_spacing, line_height: line_height}

    for {name, {family, size, weight, spacing, height, uppercase}} <- @styles, into: %{} do
      {name,
       %{
         "family" => family,
         "size_pt" => size,
         "weight" => weight,
         "letter_spacing_em" => from_body(spacing, body.letter_spacing),
         "line_height" => from_body(height, body.line_height),
         "uppercase" => uppercase
       }}
    end
  end

  defp from_body(:body, value), do: value
  defp from_body(value, _body), do: value
end
