defmodule Kanban.Mobile.IosDesignSystem do
  @moduledoc """
  Builds the iOS app's design-system files from the token map that
  `Kanban.Mobile.Tokens.build!/1` makes (W2787). `mix mobile.tokens` writes
  them beside `mobile/shared/tokens/tokens.json`, so the app's colours and type
  come from the same tokens as the web's `.stride-screen` palette.

  ## Output

    * `mobile/ios/Stride/DesignSystem/Colors.xcassets`: the catalog's
      `Contents.json` and one `<token>.colorset/Contents.json` for every colour
      token, each with the light value and a dark-appearance value, in sRGB. An
      eight-digit hex gives the colour's alpha. Xcode makes a Swift symbol of
      each, so `ink-2` is `Color(.ink2)`.
    * `mobile/ios/Stride/DesignSystem/DesignTokens.swift`: the tokens that are
      not colours, as Swift constants. Its font families are the first family
      of `font-sans` and `font-mono`, which the app bundles as Geist and Geist
      Mono; `font-pixel` is left out, because the app does not bundle it. Each
      `text_style` token becomes a `DesignTokens.TextStyles` constant, so
      `large-title` is `DesignTokens.TextStyles.largeTitle`, which
      `StrideTextStyle` reads.

  `render!/1` returns every file as a map from its path, relative to the project
  root, to its content. `test/kanban/mobile/ios_design_system_test.exs` fails
  while a committed file is stale or the catalog holds a colour that is no
  longer a token. Refresh them with `MIX_ENV=test mix mobile.tokens`, and never
  edit them by hand.
  """

  @catalog_dir "mobile/ios/Stride/DesignSystem/Colors.xcassets"
  @swift_path "mobile/ios/Stride/DesignSystem/DesignTokens.swift"

  # The first family of a stack must be one the app bundles, not a generic
  # family the system resolves.
  @generic_families ~w(serif sans-serif monospace cursive fantasy system-ui ui-serif ui-sans-serif ui-monospace ui-rounded -apple-system)

  @family_re ~r/^[A-Za-z0-9][A-Za-z0-9 ]*$/
  @swift_name_re ~r/^[a-z][a-z0-9]*$/
  @style_name_re ~r/^[a-z]+(-[a-z]+)*$/

  @style_families %{"font-sans" => "sansFamily", "font-mono" => "monoFamily"}
  @weights %{400 => ".regular", 500 => ".medium", 600 => ".semibold", 700 => ".bold"}

  # A colour's name becomes a folder in the catalog, so it may hold only what a
  # token name holds: lower-case letters and digits joined by single hyphens.
  @color_name_re ~r/^[a-z0-9]+(-[a-z0-9]+)*$/
  @hex_re ~r/^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})?$/

  @info %{"author" => "xcode", "version" => 1}

  @doc "The generated colour asset catalog, relative to the project root."
  @spec catalog_dir() :: String.t()
  def catalog_dir, do: @catalog_dir

  @doc "The generated Swift constants, relative to the project root."
  @spec swift_path() :: String.t()
  def swift_path, do: @swift_path

  @doc """
  Renders every file from the token map. Raises `ArgumentError` when the
  themes do not hold the same colours, a colour's name is not a token name, a
  colour is not a hex value, a font stack does not start with a named family,
  or a text style has a name, family or weight the app cannot use.
  """
  @spec render!(map()) :: %{String.t() => String.t()}
  def render!(%{"themes" => %{"light" => light, "dark" => dark}}) do
    light["color"]
    |> colorsets!(dark["color"])
    |> Map.put(Path.join(@catalog_dir, "Contents.json"), encode(%{"info" => @info}))
    |> Map.put(@swift_path, swift(light))
  end

  defp colorsets!(light_colors, dark_colors) do
    colorsets = Map.new(light_colors, &colorset_file!(&1, dark_colors))
    reject_dark_only!(light_colors, dark_colors)
    colorsets
  end

  defp colorset_file!({name, light_color}, dark_colors) do
    color_name!(name)
    dark_color = dark_color!(dark_colors, name)

    {Path.join([@catalog_dir, name <> ".colorset", "Contents.json"]),
     encode(colorset(name, light_color, dark_color))}
  end

  defp color_name!(name) do
    if !Regex.match?(@color_name_re, name) do
      raise ArgumentError, "mobile.tokens: --#{inspect(name)} is not a token name"
    end
  end

  @doc "The colour set names `render!/1` writes, sorted."
  @spec colorset_names(map()) :: [String.t()]
  def colorset_names(%{"themes" => %{"light" => light}}) do
    light["color"] |> Map.keys() |> Enum.sort() |> Enum.map(&(&1 <> ".colorset"))
  end

  @doc """
  The first family of a CSS font stack, without its quotes. Raises
  `ArgumentError` when the stack starts with a generic family.
  """
  @spec first_family!(String.t(), String.t()) :: String.t()
  def first_family!(token, stack) do
    family =
      stack
      |> String.split(",")
      |> List.first()
      |> String.trim()
      |> String.trim("'")
      |> String.trim("\"")

    if family in @generic_families or not Regex.match?(@family_re, family) do
      raise ArgumentError,
            "mobile.tokens: --#{token} #{inspect(stack)} does not start with a named family"
    end

    family
  end

  defp dark_color!(dark_colors, name) do
    case Map.fetch(dark_colors, name) do
      {:ok, color} -> color
      :error -> raise ArgumentError, "mobile.tokens: --#{name} has no dark value"
    end
  end

  defp reject_dark_only!(light_colors, dark_colors) do
    case Map.keys(dark_colors) -- Map.keys(light_colors) do
      [] -> :ok
      [name | _] -> raise ArgumentError, "mobile.tokens: --#{name} has no light value"
    end
  end

  defp colorset(name, light, dark) do
    %{
      "colors" => [
        %{"color" => color(name, light), "idiom" => "universal"},
        %{
          "appearances" => [%{"appearance" => "luminosity", "value" => "dark"}],
          "color" => color(name, dark),
          "idiom" => "universal"
        }
      ],
      "info" => @info
    }
  end

  defp color(name, %{"hex" => hex}) do
    case Regex.run(@hex_re, hex, capture: :all_but_first) do
      [r, g, b | alpha] ->
        %{
          "color-space" => "srgb",
          "components" => %{
            "alpha" => alpha(alpha),
            "blue" => component(b),
            "green" => component(g),
            "red" => component(r)
          }
        }

      nil ->
        raise ArgumentError, "mobile.tokens: --#{name} #{inspect(hex)} is not a hex colour"
    end
  end

  defp component(pair), do: "0x" <> String.upcase(pair)

  defp alpha([]), do: "1.000"

  defp alpha([pair]) do
    {value, ""} = Integer.parse(pair, 16)
    :erlang.float_to_binary(value / 255, decimals: 3)
  end

  defp swift(theme) do
    font = theme["font"]

    """
    // Generated by `mix mobile.tokens` from mobile/shared/tokens/tokens.json.
    // Never edit this file by hand: change assets/css/app.css or
    // lib/kanban/mobile/type_scale.ex and run the task.

    import SwiftUI

    /// The Stride design tokens that are not colours. The colours are in
    /// `Colors.xcassets`, so `ink-2` is `Color(.ink2)`.
    enum DesignTokens {
        /// The first family of `--font-sans`.
        static let sansFamily = #{inspect(first_family!("font-sans", font["font-sans"]))}

        /// The first family of `--font-mono`.
        static let monoFamily = #{inspect(first_family!("font-mono", font["font-mono"]))}

        /// A text style at the default text size: its family, its size in
        /// points, its weight, its letter spacing as a share of the size, its
        /// line height as a multiple of the size, and whether it is in capitals.
        struct TextStyle: Sendable {
            let family: String
            let size: CGFloat
            let weight: Font.Weight
            let letterSpacingEm: CGFloat
            let lineHeight: CGFloat
            let isUppercase: Bool
        }

        /// The `text_style` tokens.
        enum TextStyles {
    #{text_styles(theme["text_style"])}
        }

        /// The `--r-*` corner radii, in points.
        enum Radius {
    #{radii(theme["radius"])}
        }
    }
    """
  end

  defp text_styles(styles) do
    styles
    |> Enum.sort_by(fn {name, style} -> {-style["size_pt"], name} end)
    |> Enum.map_join("\n", fn {name, style} ->
      "        static let #{style_name!(name)} = TextStyle(" <>
        "family: #{style_family!(name, style["family"])}, " <>
        "size: #{number(style["size_pt"])}, " <>
        "weight: #{style_weight!(name, style["weight"])}, " <>
        "letterSpacingEm: #{number(style["letter_spacing_em"])}, " <>
        "lineHeight: #{number(style["line_height"])}, " <>
        "isUppercase: #{style["uppercase"] == true})"
    end)
  end

  defp style_name!(name) do
    if !Regex.match?(@style_name_re, name) do
      raise ArgumentError, "mobile.tokens: text style #{inspect(name)} has no Swift name"
    end

    [first | rest] = String.split(name, "-")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  defp style_family!(name, family) do
    case Map.fetch(@style_families, family) do
      {:ok, constant} ->
        constant

      :error ->
        raise ArgumentError,
              "mobile.tokens: text style #{name} is in #{inspect(family)}, not font-sans or font-mono"
    end
  end

  defp style_weight!(name, weight) do
    case Map.fetch(@weights, weight) do
      {:ok, swift} ->
        swift

      :error ->
        raise ArgumentError,
              "mobile.tokens: text style #{name} has weight #{inspect(weight)}, not 400, 500, 600 or 700"
    end
  end

  defp radii(radius) do
    radius
    |> Enum.sort_by(fn {name, value} -> {value, name} end)
    |> Enum.map_join("\n", fn {"r-" <> name, value} ->
      "        static let #{swift_name!(name)}: CGFloat = #{number(value)}"
    end)
  end

  defp swift_name!(name) do
    if Regex.match?(@swift_name_re, name),
      do: name,
      else: raise(ArgumentError, "mobile.tokens: --r-#{name} has no Swift name")
  end

  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value) when is_float(value), do: Float.to_string(value)

  defp encode(map) do
    map
    |> ordered()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp ordered(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
