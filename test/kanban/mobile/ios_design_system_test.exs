defmodule Kanban.Mobile.IosDesignSystemTest do
  @moduledoc """
  The iOS app's colour assets and Swift tokens, generated from the design
  tokens (W2787).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kanban.Mobile.IosDesignSystem
  alias Kanban.Mobile.Tokens
  alias Kanban.Mobile.TypeScale

  @task Mix.Tasks.Mobile.Tokens

  @root Path.expand("../../..", __DIR__)
  @refresh_hint "The iOS design-system files are stale. Refresh them with: MIX_ENV=test mix mobile.tokens"

  defp app_tokens do
    @root |> Path.join(Tokens.source_path()) |> File.read!() |> Tokens.build!()
  end

  # The smallest token map `render!/1` takes.
  defp tokens(light_colors, dark_colors, opts \\ []) do
    fonts = %{
      "font-sans" => Keyword.get(opts, :sans, "'Geist', ui-sans-serif, sans-serif"),
      "font-mono" => Keyword.get(opts, :mono, "'Geist Mono', ui-monospace, monospace")
    }

    type = %{
      "font_size_px" => 13,
      "font_size_narrow_px" => 14.5,
      "letter_spacing_em" => -0.005,
      "line_height" => 1.45
    }

    theme = fn colors ->
      %{
        "color" => colors,
        "font" => fonts,
        "radius" => Keyword.get(opts, :radius, %{"r-sm" => 4, "r-lg" => 10}),
        "text_style" => Keyword.get(opts, :text_style, TypeScale.build(type)),
        "type" => type
      }
    end

    %{"themes" => %{"light" => theme.(light_colors), "dark" => theme.(dark_colors)}}
  end

  defp colorset(files, name) do
    files
    |> Map.fetch!(
      Path.join([IosDesignSystem.catalog_dir(), name <> ".colorset", "Contents.json"])
    )
    |> Jason.decode!()
  end

  describe "render!/1" do
    test "gives every colour a light value and a dark-appearance value" do
      files = tokens(%{"ink" => %{"hex" => "#111114"}}, %{"ink" => %{"hex" => "#edeef2"}})

      assert %{"colors" => [light, dark], "info" => %{"author" => "xcode", "version" => 1}} =
               files |> IosDesignSystem.render!() |> colorset("ink")

      assert light == %{
               "color" => %{
                 "color-space" => "srgb",
                 "components" => %{
                   "alpha" => "1.000",
                   "blue" => "0x14",
                   "green" => "0x11",
                   "red" => "0x11"
                 }
               },
               "idiom" => "universal"
             }

      assert dark["appearances"] == [%{"appearance" => "luminosity", "value" => "dark"}]

      assert dark["color"]["components"] == %{
               "alpha" => "1.000",
               "blue" => "0xF2",
               "green" => "0xEE",
               "red" => "0xED"
             }
    end

    test "takes the alpha from an eight-digit hex" do
      files =
        tokens(%{"veil" => %{"hex" => "#ffb6858c"}}, %{"veil" => %{"hex" => "#782e0000"}})
        |> IosDesignSystem.render!()

      assert %{"colors" => [light, dark]} = colorset(files, "veil")
      assert light["color"]["components"]["alpha"] == "0.549"
      assert dark["color"]["components"]["alpha"] == "0.000"
    end

    test "writes the catalog, one colour set per colour, and the Swift tokens" do
      colors = %{"ink" => %{"hex" => "#111114"}, "st-done" => %{"hex" => "#2a7a3a"}}
      files = colors |> tokens(colors) |> IosDesignSystem.render!()

      assert files |> Map.keys() |> Enum.sort() == [
               "mobile/ios/Stride/DesignSystem/Colors.xcassets/Contents.json",
               "mobile/ios/Stride/DesignSystem/Colors.xcassets/ink.colorset/Contents.json",
               "mobile/ios/Stride/DesignSystem/Colors.xcassets/st-done.colorset/Contents.json",
               "mobile/ios/Stride/DesignSystem/DesignTokens.swift"
             ]

      assert Jason.decode!(files["mobile/ios/Stride/DesignSystem/Colors.xcassets/Contents.json"]) ==
               %{"info" => %{"author" => "xcode", "version" => 1}}

      assert Enum.all?(files, fn {_path, content} -> String.ends_with?(content, "\n") end)
    end

    test "writes the families, the text styles and the radii as Swift constants" do
      colors = %{"ink" => %{"hex" => "#111114"}}

      swift =
        colors
        |> tokens(colors)
        |> IosDesignSystem.render!()
        |> Map.fetch!(IosDesignSystem.swift_path())

      assert swift =~ ~s(static let sansFamily = "Geist"\n)
      assert swift =~ ~s(static let monoFamily = "Geist Mono"\n)

      assert swift =~
               "static let largeTitle = TextStyle(family: sansFamily, size: 34, weight: .bold, " <>
                 "letterSpacingEm: -0.03, lineHeight: 1.1, isUppercase: false)\n"

      assert swift =~
               "static let body = TextStyle(family: sansFamily, size: 15, weight: .regular, " <>
                 "letterSpacingEm: -0.005, lineHeight: 1.45, isUppercase: false)\n"

      assert swift =~
               "static let label = TextStyle(family: monoFamily, size: 11, weight: .medium, " <>
                 "letterSpacingEm: 0.04, lineHeight: 1.45, isUppercase: true)\n"

      assert swift =~ "static let sm: CGFloat = 4\n        static let lg: CGFloat = 10\n"
      assert swift =~ "Never edit this file by hand"
    end

    test "writes the text styles largest first" do
      colors = %{"ink" => %{"hex" => "#111114"}}

      names =
        colors
        |> tokens(colors)
        |> IosDesignSystem.render!()
        |> Map.fetch!(IosDesignSystem.swift_path())
        |> then(&Regex.scan(~r/static let (\w+) = TextStyle/, &1, capture: :all_but_first))
        |> List.flatten()

      assert names ==
               ~w(largeTitle title headline callout body subheadline footnote code label)
    end

    test "the output is the same each time" do
      tokens = app_tokens()
      assert IosDesignSystem.render!(tokens) == IosDesignSystem.render!(tokens)
    end
  end

  describe "errors" do
    test "a colour with no dark value" do
      assert_raise ArgumentError, ~r/--ink has no dark value/, fn ->
        %{"ink" => %{"hex" => "#111114"}} |> tokens(%{}) |> IosDesignSystem.render!()
      end
    end

    test "a colour with no light value" do
      assert_raise ArgumentError, ~r/--ink has no light value/, fn ->
        %{} |> tokens(%{"ink" => %{"hex" => "#111114"}}) |> IosDesignSystem.render!()
      end
    end

    test "a colour that is not a hex value" do
      bad = %{"ink" => %{"hex" => "#11111"}}

      assert_raise ArgumentError, ~r/--ink "#11111" is not a hex colour/, fn ->
        bad |> tokens(bad) |> IosDesignSystem.render!()
      end
    end

    for name <- ["../../outside", "a/b", "Ink", "ink--2", ""] do
      test "a colour named #{inspect(name)}" do
        colors = %{unquote(name) => %{"hex" => "#111114"}}

        assert_raise ArgumentError, ~r/is not a token name/, fn ->
          colors |> tokens(colors) |> IosDesignSystem.render!()
        end
      end
    end

    for stack <- ["monospace", "ui-sans-serif, sans-serif", "'Ge\\\"ist', serif", ""] do
      test "a font stack that starts with #{inspect(stack)}" do
        colors = %{"ink" => %{"hex" => "#111114"}}

        assert_raise ArgumentError, ~r/--font-sans .* does not start with a named family/, fn ->
          colors |> tokens(colors, sans: unquote(stack)) |> IosDesignSystem.render!()
        end
      end
    end

    for {label, name, changes, message} <- [
          {"a text style name with no Swift name", "Large_title", [],
           ~s(text style "Large_title" has no Swift name)},
          {"a text style in a family the app lacks", "body", [{"family", "font-pixel"}],
           ~s(text style body is in "font-pixel", not font-sans or font-mono)},
          {"a text style weight the app has no name for", "body", [{"weight", 450}],
           "text style body has weight 450, not 400, 500, 600 or 700"}
        ] do
      test label do
        colors = %{"ink" => %{"hex" => "#111114"}}
        body = TypeScale.build(%{"letter_spacing_em" => -0.005, "line_height" => 1.45})["body"]
        style = Map.merge(body, Map.new(unquote(changes)))

        assert_raise ArgumentError, "mobile.tokens: " <> unquote(message), fn ->
          colors
          |> tokens(colors, text_style: %{unquote(name) => style})
          |> IosDesignSystem.render!()
        end
      end
    end

    test "a radius with no Swift name" do
      colors = %{"ink" => %{"hex" => "#111114"}}

      assert_raise ArgumentError, ~r/--r-2xl has no Swift name/, fn ->
        colors |> tokens(colors, radius: %{"r-2xl" => 20}) |> IosDesignSystem.render!()
      end
    end
  end

  describe "first_family!/2" do
    test "drops the quotes and the rest of the stack" do
      assert IosDesignSystem.first_family!("font-mono", "'Geist Mono', monospace") == "Geist Mono"
      assert IosDesignSystem.first_family!("font-sans", ~s("Geist", sans-serif)) == "Geist"
      assert IosDesignSystem.first_family!("font-sans", "Geist") == "Geist"
    end
  end

  describe "mix mobile.tokens" do
    @tag :tmp_dir
    test "writes tokens.json and the iOS files, and removes a colour that is no longer a token",
         %{tmp_dir: dir} do
      catalog = Path.join(dir, IosDesignSystem.catalog_dir())
      stale = Path.join(catalog, "retired.colorset")
      File.mkdir_p!(stale)
      stale |> Path.join("Contents.json") |> File.write!("{}")
      catalog |> Path.join("notes.txt") |> File.write!("kept")

      output = Path.join(dir, "tokens.json")
      source = Path.join(@root, Tokens.source_path())

      log = capture_io(fn -> @task.generate(source: source, output: output, root: dir) end)

      assert File.read!(output) == source |> File.read!() |> Tokens.render!()
      refute File.exists?(stale)
      assert catalog |> Path.join("notes.txt") |> File.read!() == "kept"

      for {path, content} <- IosDesignSystem.render!(app_tokens()) do
        assert dir |> Path.join(path) |> File.read!() == content
      end

      assert log =~ "with 62 colour sets"
      assert log =~ "Removed #{stale}"
    end

    test "takes no arguments" do
      assert_raise Mix.Error, ~r/takes no arguments/, fn -> @task.run(["--force"]) end
    end
  end

  describe "the committed iOS files" do
    test "are up to date" do
      for {path, content} <- IosDesignSystem.render!(app_tokens()) do
        committed = @root |> Path.join(path) |> File.read!()
        assert committed == content, "#{path}: #{@refresh_hint}"
      end
    end

    test "the catalog holds a colour set for each colour token and nothing else" do
      catalog = Path.join(@root, IosDesignSystem.catalog_dir())

      assert catalog |> File.ls!() |> Enum.sort() ==
               Enum.sort(["Contents.json" | IosDesignSystem.colorset_names(app_tokens())]),
             @refresh_hint

      for name <- IosDesignSystem.colorset_names(app_tokens()) do
        assert catalog |> Path.join(name) |> File.ls!() == ["Contents.json"]
      end
    end

    test "a changed colour token changes the render, so the staleness test catches it" do
      tokens = app_tokens()
      changed = put_in(tokens, ["themes", "dark", "color", "ink", "hex"], "#ffffff")

      refute IosDesignSystem.render!(changed) == IosDesignSystem.render!(tokens)
    end

    test "every contract colour has a colour set" do
      names = IosDesignSystem.colorset_names(app_tokens())

      for token <-
            ~w(bg surface surface-2 surface-sunken ink ink-2 ink-3 ink-4 line-input st-done-soft) do
        assert "#{token}.colorset" in names
      end
    end

    test "the paths are inside the iOS app's design system" do
      assert IosDesignSystem.catalog_dir() == "mobile/ios/Stride/DesignSystem/Colors.xcassets"
      assert IosDesignSystem.swift_path() == "mobile/ios/Stride/DesignSystem/DesignTokens.swift"
    end
  end
end
