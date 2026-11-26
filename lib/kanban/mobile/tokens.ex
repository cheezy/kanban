defmodule Kanban.Mobile.Tokens do
  @moduledoc """
  Builds the design tokens the native apps read (W2776) from the web's
  `.stride-screen` custom properties in `assets/css/app.css`.

  `mix mobile.tokens` writes `render!/1`'s output to
  `mobile/shared/tokens/tokens.json`. The design doc names a single
  `mobile/shared/tokens.json`; `mobile/shared/README.md` moves the generated
  tokens into the `tokens/` folder, and `test/kanban/repository_layout_test.exs`
  pins that path. `test/kanban/mobile/tokens_test.exs` fails when the committed
  file is stale. Refresh it with `MIX_ENV=test mix mobile.tokens`, and never
  edit it by hand.

  ## Sources

    * the light block, `.stride-marketing, .stride-screen { … }`
    * the dark override, `:where([data-theme="dark"]) .stride-marketing,
      :where([data-theme="dark"]) .stride-screen { … }`. A token it does not
      define keeps its light value, so fonts and radii appear in both themes.
      A token only the dark block defines is an error.
    * the type scale: `font-size`, `line-height` and `letter-spacing` in the
      light block, and the narrow `font-size` under `@media (max-width: 767px)`.

  Each of the three blocks must appear exactly once: a missing or a repeated
  block is an error, so no declaration is silently ignored.

  The dark-only `--stride-diff-*` block lower in `app.css` is not read: its
  light values exist only as `var()` fallbacks, so it has no light token.

  ## Output

  Every theme has the same groups, with token names lacking the leading `--`:

    * `color`: `%{"hex" => "#rrggbb", "oklch" => source}`. A colour with an
      alpha has an eight-digit `#rrggbbaa` hex, alpha last as in CSS. A colour
      written as hex in `app.css` has only `"hex"`. Colours outside sRGB are
      clipped per channel, as `mix dark_mode.contrast` does, so the oklch source
      is kept for a wider-gamut conversion.
    * `composite`: gradients and shadows as CSS strings, with `var()`
      references replaced by the same theme's value.
    * `font`: font stacks as CSS strings.
    * `radius`: the `--r-*` radii in px.
    * `type`: `font_size_px`, `font_size_narrow_px`, `letter_spacing_em` and
      `line_height`.
    * `text_style`: the apps' named text styles, which `Kanban.Mobile.TypeScale`
      holds because the stylesheet has none. Their body letter spacing and line
      height come from `type`.

  There is no spacing group, because `app.css` defines no spacing tokens.
  Keys are sorted at every level so the file diffs cleanly.
  """

  alias Kanban.Mobile.TypeScale
  alias Mix.Tasks.DarkMode.Contrast

  @source_path "assets/css/app.css"
  @output_path "mobile/shared/tokens/tokens.json"

  @comment_re ~r{/\*.*?\*/}s
  @light_re ~r/^\.stride-marketing,\s*\.stride-screen\s*\{([^}]*)\}/m
  @dark_re ~r/^:where\(\[data-theme="dark"\]\)\s*\.stride-marketing,\s*:where\(\[data-theme="dark"\]\)\s*\.stride-screen\s*\{([^}]*)\}/m
  @narrow_re ~r/@media\s*\(max-width:\s*767px\)\s*\{\s*\.stride-marketing,\s*\.stride-screen\s*\{([^}]*)\}/
  @oklch_re ~r/^oklch\(\s*(\d+(?:\.\d+)?)%\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*(?:\/\s*(\d+(?:\.\d+)?)\s*)?\)$/
  @hex_re ~r/^#[0-9a-fA-F]{6}$/
  @var_re ~r/var\(\s*--([a-z0-9-]+)\s*\)/

  @type props :: %{String.t() => String.t()}
  @type parsed :: %{light: props(), dark: props(), type: props()}

  @doc "The stylesheet the tokens come from, relative to the project root."
  @spec source_path() :: String.t()
  def source_path, do: @source_path

  @doc "The generated file, relative to the project root."
  @spec output_path() :: String.t()
  def output_path, do: @output_path

  @doc """
  Reads the light and dark custom properties and the type declarations from
  the stylesheet. Dark holds every light token, overridden where the dark block
  sets one. Raises `ArgumentError` naming the block or token that is missing
  or malformed.
  """
  @spec parse!(String.t()) :: parsed()
  def parse!(css) do
    css = Regex.replace(@comment_re, css, "")
    light = block!(css, @light_re, "light")
    dark_overrides = css |> block!(@dark_re, "dark") |> custom_properties()
    light_props = custom_properties(light)
    reject_dark_only!(dark_overrides, light_props)

    %{
      light: light_props,
      dark: Map.merge(light_props, dark_overrides),
      type: type_declarations(light, block!(css, @narrow_re, "narrow"))
    }
  end

  @doc "Builds the token map written to the output file."
  @spec build!(String.t()) :: map()
  def build!(css) do
    %{light: light, dark: dark, type: type} = parse!(css)

    %{
      "generator" => "mix mobile.tokens",
      "source" => @source_path,
      "themes" => %{"light" => theme(light, type), "dark" => theme(dark, type)}
    }
  end

  @doc "Renders the token file: pretty JSON, keys sorted, ending in a newline."
  @spec render!(String.t()) :: String.t()
  def render!(css) do
    css
    |> build!()
    |> ordered()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp reject_dark_only!(dark_overrides, light_props) do
    case Map.keys(dark_overrides) -- Map.keys(light_props) do
      [] -> :ok
      [name | _] -> invalid!(name, Map.fetch!(dark_overrides, name), "is set only in dark")
    end
  end

  defp block!(css, regex, label) do
    case Regex.scan(regex, css, capture: :all_but_first) do
      [[body]] ->
        declarations(body)

      [] ->
        raise ArgumentError, "mobile.tokens: no #{label} .stride-screen block in app.css"

      [_ | _] ->
        raise ArgumentError,
              "mobile.tokens: more than one #{label} .stride-screen block in app.css"
    end
  end

  defp declarations(body) do
    body
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(&declaration/1)
  end

  defp declaration(text) do
    case String.split(text, ":", parts: 2) do
      [name, value] -> {String.trim(name), String.trim(value)}
      [_] -> raise ArgumentError, "mobile.tokens: #{inspect(text)} is not a declaration"
    end
  end

  defp custom_properties(declarations) do
    for {"--" <> name, value} <- declarations, into: %{}, do: {name, value}
  end

  defp type_declarations(light, narrow) do
    %{
      "font-size" => required!(light, "font-size"),
      "line-height" => required!(light, "line-height"),
      "letter-spacing" => required!(light, "letter-spacing"),
      "font-size-narrow" => required!(narrow, "font-size")
    }
  end

  defp required!(declarations, name) do
    case Map.fetch(declarations, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "mobile.tokens: no #{name} in the .stride-screen block"
    end
  end

  defp theme(props, type) do
    groups = %{"color" => %{}, "composite" => %{}, "font" => %{}, "radius" => %{}}

    props
    |> Enum.reduce(groups, fn {name, value}, acc ->
      resolved = resolve(name, value, props)
      {group, token} = classify!(name, resolved)
      put_in(acc, [group, name], token)
    end)
    |> put_type(type_tokens(type))
  end

  defp put_type(groups, type) do
    groups
    |> Map.put("type", type)
    |> Map.put("text_style", TypeScale.build(type))
  end

  defp resolve(name, value, props) do
    resolved =
      Regex.replace(@var_re, value, fn _match, ref ->
        Map.get(props, ref) || invalid!(name, value, "refers to undefined --#{ref}")
      end)

    if String.contains?(resolved, "var("),
      do: invalid!(name, value, "has a var() this generator cannot resolve")

    resolved
  end

  defp classify!("font-" <> _ = _name, value), do: {"font", value}
  defp classify!("r-" <> _ = name, value), do: {"radius", measure!("--" <> name, value, "px")}
  defp classify!("shadow-" <> _ = _name, value), do: {"composite", value}
  defp classify!(_name, "linear-gradient(" <> _ = value), do: {"composite", value}
  defp classify!(name, "oklch(" <> _ = value), do: {"color", oklch!(name, value)}
  defp classify!(name, "#" <> _ = value), do: {"color", hex!(name, value)}

  defp classify!(name, value),
    do: invalid!(name, value, "is not a colour, gradient, shadow, font or radius")

  defp oklch!(name, value) do
    case Regex.run(@oklch_re, value, capture: :all_but_first) do
      [l, c, h | alpha] -> %{"hex" => oklch_hex(l, c, h) <> alpha_hex(alpha), "oklch" => value}
      nil -> invalid!(name, value, "is not oklch(L% C H) or oklch(L% C H / A)")
    end
  end

  defp oklch_hex(l, c, h) do
    {r, g, b} = Contrast.to_linear_rgb("oklch(#{l}% #{c} #{h})")
    bytes = <<byte(r), byte(g), byte(b)>>
    "#" <> Base.encode16(bytes, case: :lower)
  end

  defp alpha_hex([]), do: ""

  defp alpha_hex([alpha]) do
    {value, ""} = Float.parse(alpha)
    bytes = <<round(min(value, 1.0) * 255)>>
    Base.encode16(bytes, case: :lower)
  end

  defp byte(linear) do
    encoded = gamma_encode(linear)
    round(encoded * 255)
  end

  defp gamma_encode(c) when c <= 0.0031308, do: 12.92 * c
  defp gamma_encode(c), do: 1.055 * :math.pow(c, 1 / 2.4) - 0.055

  defp hex!(name, value) do
    if Regex.match?(@hex_re, value),
      do: %{"hex" => String.downcase(value)},
      else: invalid!(name, value, "is not a six-digit hex colour")
  end

  defp type_tokens(type) do
    %{
      "font_size_px" => measure!("font-size", type["font-size"], "px"),
      "font_size_narrow_px" => measure!("font-size", type["font-size-narrow"], "px"),
      "letter_spacing_em" => measure!("letter-spacing", type["letter-spacing"], "em"),
      "line_height" => measure!("line-height", type["line-height"], "")
    }
  end

  # `label` is what the error names: `--r-sm` for a token, `font-size` for a
  # plain declaration.
  defp measure!(label, value, unit) do
    regex = Regex.compile!("^(-?\\d+(?:\\.\\d+)?)" <> unit <> "$")

    case Regex.run(regex, value, capture: :all_but_first) do
      [number] ->
        number(number)

      nil ->
        raise ArgumentError,
              "mobile.tokens: #{label} #{inspect(value)} is not a number in #{unit_label(unit)}"
    end
  end

  defp number(text) do
    if String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text)
  end

  defp unit_label(""), do: "plain units"
  defp unit_label(unit), do: unit

  defp ordered(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(value), do: value

  @spec invalid!(String.t(), String.t(), String.t()) :: no_return()
  defp invalid!(name, value, reason) do
    raise ArgumentError, "mobile.tokens: --#{name} #{inspect(value)} #{reason}"
  end
end
