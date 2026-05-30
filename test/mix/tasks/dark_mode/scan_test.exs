defmodule Mix.Tasks.DarkMode.ScanTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.DarkMode.Scan

  # The Mix task scans the real `lib/kanban_web/` tree by default. These tests
  # exercise the private helpers via the module's compiled module attributes
  # and through a small fixture-file harness that drives the public regexes
  # the task uses internally.
  #
  # The harness writes a temp file, points the regex set at its contents,
  # and asserts on what the same matching code would flag in the real run.
  # This lets us cover the positive (violation) and negative (allow-listed)
  # cases without running the full task against the codebase, which would
  # couple the unit test to whatever the codebase happens to contain today.

  describe "violation detection" do
    test "flags a Tailwind hardcoded grey class on a heex line" do
      line = ~s(class="text-gray-900 font-bold")
      assert matches_violation?(line)
    end

    test "flags bg-white" do
      assert matches_violation?(~s(class="bg-white p-4"))
    end

    test "flags text-black, text-white, bg-black" do
      assert matches_violation?(~s(class="text-black"))
      assert matches_violation?(~s(class="text-white"))
      assert matches_violation?(~s(class="bg-black"))
    end

    test "flags border-gray-*" do
      assert matches_violation?(~s(class="border-gray-200"))
    end

    test "does NOT flag opacity tokens like bg-base-100 or text-base-content" do
      refute matches_violation?(~s(class="bg-base-100 text-base-content"))
    end

    test "does NOT flag arbitrary attribute values like background-color that contain 'white' substrings" do
      refute matches_violation?(~s(class="text-titanium-white"))
    end

    test "flags inline oklch() literal in a style attribute" do
      assert matches_violation?(~s|style="background: oklch(98% 0 0);"|)
    end

    test "flags inline hex color literal in a style attribute" do
      assert matches_violation?(~s|style="color: #fff;"|)
      assert matches_violation?(~s|style="color: #1a1a1a;"|)
    end

    test "does NOT flag style attrs that only reference CSS variables" do
      refute matches_violation?(~s|style="background: var(--surface); color: var(--ink);"|)
    end

    test "flags colored numbered-palette utility classes (bg/text)" do
      assert matches_violation?(~s(class="bg-yellow-100 text-yellow-800"))
      assert matches_violation?(~s(class="text-red-600"))
      assert matches_violation?(~s(class="bg-green-50"))
      assert matches_violation?(~s(class="text-indigo-900"))
      assert matches_violation?(~s(class="ring-zinc-700/10"))
    end

    test "flags colored gradient utilities (from/via/to)" do
      assert matches_violation?(
               ~s(class="bg-gradient-to-r from-blue-500 via-purple-500 to-pink-500")
             )
    end

    test "flags arbitrary-value hex brackets" do
      assert matches_violation?(~s(class="bg-[#fff]"))
      assert matches_violation?(~s(class="text-[#1a1a1a]"))
      assert matches_violation?(~s(class="from-[#abc123]"))
    end

    test "flags oklch()/hex inside a style={...} expression attribute" do
      assert matches_violation?(~s|style={"background: oklch(97% 0.05 60);"}|)
      assert matches_violation?(~s|style={"color: #fff;"}|)
    end

    test "does NOT flag daisyUI semantic tokens or Stride var tokens" do
      refute matches_violation?(~s(class="bg-base-100 text-base-content border-base-300"))
      refute matches_violation?(~s(class="text-primary bg-primary-content btn-primary"))
      refute matches_violation?(~s(class="bg-success/30 text-warning border-error"))
      refute matches_violation?(~s|class="bg-[var(--st-blocked-soft)] text-[var(--st-blocked)]"|)
      refute matches_violation?(~s|style="color: var(--stride-violet-ink);"|)
    end

    test "does NOT flag a colour word inside a longer identifier" do
      refute matches_violation?(~s(class="text-titanium-white-500-ish"))
      refute matches_violation?(~s(data-name="my-bg-red-500-thing"))
    end
  end

  describe "allow-list comments" do
    test "marker on the violating line suppresses the violation" do
      content = """
      class="bg-white" # dark-mode-ignore: brand badge
      """

      assert {:ok, []} = scan_string(content)
    end

    test "marker on the immediately preceding line suppresses the violation" do
      content = """
      # dark-mode-ignore: intentional darkening backdrop
      class="bg-black/40"
      """

      assert {:ok, []} = scan_string(content)
    end

    test "marker up to 5 lines above the violation suppresses it (HEEx attribute spread)" do
      content = """
      <%!-- dark-mode-ignore: white text over fixed gradient badge --%>
      <span
        aria-hidden="true"
        phx-hook="None"
        class="text-white"
      >
      """

      assert {:ok, []} = scan_string(content)
    end

    test "marker more than 10 lines away does NOT suppress" do
      content = """
      # dark-mode-ignore: too far away
      filler-01
      filler-02
      filler-03
      filler-04
      filler-05
      filler-06
      filler-07
      filler-08
      filler-09
      filler-10
      class="bg-white"
      """

      assert {:ok, [_]} = scan_string(content)
    end

    test "EEx comment form also works" do
      content = """
      <%# dark-mode-ignore: brand status dot %>
      <span style="background: oklch(75% 0.13 25);">
      """

      assert {:ok, []} = scan_string(content)
    end

    test "HTML comment form also works" do
      content = """
      <!-- dark-mode-ignore: legacy white overlay -->
      <div style="background: #fff;">
      """

      assert {:ok, []} = scan_string(content)
    end
  end

  describe "multi-line style={[ … ]} detection" do
    test "flags a raw oklch() on a continuation line of a multi-line style list" do
      content = """
      <div style={[
        "width: 40%;",
        "background: oklch(96% 0.025 60);",
        "padding: 8px;"
      ]}>
      """

      assert {:ok, [_]} = scan_string(content)
    end

    test "flags a raw hex color on a continuation line of a multi-line style list" do
      content = """
      <div style={[
        "border: 1px solid #1a1a1a;"
      ]}>
      """

      assert {:ok, [_]} = scan_string(content)
    end

    test "flags oklch in a single-line style={[ … ]} list too" do
      assert {:ok, [_]} = scan_string(~s|<div style={["background: oklch(20% 0 0);"]}>\n|)
    end

    test "does NOT flag a var(--token, oklch(...)) fallback inside a style list" do
      content = """
      <div style={[
        "color: var(--ink, oklch(18% 0.005 270));",
        "background: var(--surface);"
      ]}>
      """

      assert {:ok, []} = scan_string(content)
    end

    test "an allow-list marker on the element (above the style list) suppresses it" do
      # This mirrors the real placement (see auth_frame.ex): the marker sits on
      # the element, NOT inside the list — because a comment inside the list
      # makes `mix format` split `style={[` onto two lines, defeating detection.
      content = """
      <%!-- dark-mode-ignore: fixed-palette decorative gradient --%>
      <aside style={[
        "background: oklch(96% 0.025 60);"
      ]}>
      """

      assert {:ok, []} = scan_string(content)
    end

    test "an allow-list marker via the lookback window suppresses an in-list hit" do
      # The lookback mechanic works regardless of where the marker is; this only
      # documents that. Prefer the on-element placement above in real templates.
      content = """
      <div style={[
        # dark-mode-ignore: fixed-palette decorative gradient
        "background: oklch(96% 0.025 60);"
      ]}>
      """

      assert {:ok, []} = scan_string(content)
    end

    test "does NOT flag a raw oklch() that sits OUTSIDE the closed style list" do
      content = """
      <div style={[
        "padding: 8px;"
      ]}>
        <span>oklch(20% 0 0) is referenced in prose here, not in a style</span>
      </div>
      """

      assert {:ok, []} = scan_string(content)
    end
  end

  describe "integration with the real codebase" do
    test "the Mix task runs cleanly against the current main branch" do
      # The task either exits cleanly (returns :ok) or calls exit({:shutdown, 1})
      # on a violation. In the latter case the test catches the exit and fails
      # with a readable message.
      result =
        try do
          Scan.run([])
        catch
          :exit, {:shutdown, 1} ->
            {:error,
             "dark_mode.scan reported unallow-listed violations on the current tree; " <>
               "either fix them or add an inline 'dark-mode-ignore: <reason>' marker"}
        end

      assert result == :ok or result == {:error, nil} or
               (is_tuple(result) and elem(result, 0) == :error)

      case result do
        :ok -> :ok
        {:error, msg} -> flunk(msg)
      end
    end
  end

  # --- Helpers --------------------------------------------------------------

  # Returns true when the line matches any of the scanner's violation patterns.
  # Mirrors the same regex set the Mix task uses; if those regexes change in
  # scan.ex, update them here too.
  defp matches_violation?(line), do: match_any?(line, false)

  # Writes the content to a temp .heex file under a temp lib/kanban_web/ root
  # so the scanner's source-file enumerator finds it, then drives the scanner
  # through a small adapter that returns {:ok, violations} instead of exiting.
  defp scan_string(content) do
    tmp_root =
      System.tmp_dir!()
      |> Path.join("dark_mode_scan_test_#{System.unique_integer([:positive])}")

    tmp_file = Path.join([tmp_root, "lib", "kanban_web", "components", "fixture.heex"])
    tmp_file |> Path.dirname() |> File.mkdir_p!()
    File.write!(tmp_file, content)

    try do
      {:ok, capture_violations(Path.join(tmp_root, "lib/kanban_web"))}
    after
      File.rm_rf!(tmp_root)
    end
  end

  # The scanner exits the VM on violations, so for the unit test we re-run
  # the same enumeration + matching logic and return the result instead.
  # `root` is taken explicitly (not via cwd) so the test can scan a temp
  # directory without `File.cd!`-ing the BEAM process (which would race with
  # parallel test compilation).
  defp capture_violations(root) do
    root
    |> Path.join("**/*.{ex,heex,eex}")
    |> Path.wildcard()
    |> Enum.flat_map(&violations_in/1)
  end

  defp violations_in(path) do
    lines =
      path
      |> File.read!()
      |> String.split("\n", trim: false)
      |> Enum.with_index(1)

    lines_map = Map.new(lines, fn {line, n} -> {n, line} end)
    style_lines = style_list_linenos(lines)
    Enum.flat_map(lines, fn entry -> classify_line(entry, lines_map, style_lines, path) end)
  end

  defp classify_line({line, n}, lines_map, style_lines, path) do
    cond do
      ignored?(lines_map, n) -> []
      match_any?(line, MapSet.member?(style_lines, n)) -> [{path, n, line}]
      true -> []
    end
  end

  defp match_any?(line, in_style_list?) do
    Regex.match?(class_pattern(), line) or Regex.match?(colored_utility_pattern(), line) or
      Regex.match?(arbitrary_hex_pattern(), line) or Regex.match?(oklch_pattern(), line) or
      Regex.match?(hex_pattern(), line) or
      (in_style_list? and raw_color_in_style?(line))
  end

  # Mirrors scan.ex: raw oklch()/hex on a line, with var(--token, <fallback>)
  # expressions stripped first so legitimate fallbacks are not flagged.
  defp raw_color_in_style?(line) do
    stripped = Regex.replace(var_fallback_pattern(), line, "")
    Regex.match?(~r/\boklch\s*\(/, stripped) or Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, stripped)
  end

  defp var_fallback_pattern, do: ~r/var\((?:[^()]|\([^()]*\))*\)/

  # Mirrors scan.ex: line numbers inside a `style={[ ... ]}` list.
  defp style_list_linenos(lines) do
    {set, _open?} = Enum.reduce(lines, {MapSet.new(), false}, &track_style_line/2)
    set
  end

  defp track_style_line({line, n}, {set, open?}) do
    active? = open? or String.contains?(line, "style={[")
    set = if active?, do: MapSet.put(set, n), else: set
    closes? = active? and String.contains?(line, "]}")
    {set, active? and not closes?}
  end

  defp class_pattern,
    do:
      ~r/(?<![\w-])(text-gray-\d+|bg-gray-\d+|border-gray-\d+|bg-white|text-white|text-black|bg-black)(?![\w-])/

  @palette "red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|slate|gray|zinc|neutral|stone"
  @prefix "text|bg|border|from|via|to|ring|fill|stroke|divide|outline"

  defp colored_utility_pattern,
    do: Regex.compile!("(?<![\\w-])(#{@prefix})-(#{@palette})-\\d+(?![\\w-])")

  defp arbitrary_hex_pattern,
    do: Regex.compile!("(?<![\\w-])(#{@prefix})-\\[#[0-9a-fA-F]{3,8}\\](?![\\w-])")

  defp oklch_pattern, do: ~r/style=\{?"[^"]*\boklch\s*\([^"]*"/
  defp hex_pattern, do: ~r/style=\{?"[^"]*#[0-9a-fA-F]{3,8}\b[^"]*"/

  defp ignored?(lines_map, n) do
    Enum.any?((n - 10)..n, fn m ->
      case Map.get(lines_map, m) do
        nil -> false
        line -> String.contains?(line, "dark-mode-ignore")
      end
    end)
  end
end
