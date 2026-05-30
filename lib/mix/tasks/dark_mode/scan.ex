defmodule Mix.Tasks.DarkMode.Scan do
  @shortdoc "Scans lib/kanban_web for theme-blind colors (grey/white + numbered palette classes, bracket-hex, inline + style-list hex/oklch)"

  @moduledoc """
  Fails when `lib/kanban_web/` contains theme-blind colors:

    * Tailwind grey/white utility classes (`text-gray-*`, `bg-gray-*`,
      `border-gray-*`, `bg-white`, `text-white`, `text-black`, `bg-black`)
    * Colored Tailwind numbered-palette utilities — any of
      `text-/bg-/border-/from-/via-/to-/ring-/fill-/stroke-/divide-/outline-`
      paired with a numbered palette colour (`red-500`, `yellow-100`,
      `blue-600`, `violet-300`, …). These (and gradient utilities like
      `from-blue-500`) are theme-blind: they render the same shade in both
      light and dark mode. Use the daisyUI semantic tokens (`bg-base-200`,
      `text-primary`) or the Stride `--st-*` / `--stride-*` tokens instead.
    * Arbitrary-value colour brackets — `bg-[#fff]`, `text-[#000]`,
      `from-[#abc123]`, … (hardcoded hex smuggled past the palette check).
    * Inline hex color literals in `style="..."` / `style={"..."}` attributes
    * Inline `oklch(...)` literals in `style="..."` / `style={"..."}` attributes
    * Raw hex / `oklch(...)` literals on the continuation lines of a multi-line
      `style={[ ... ]}` list — `var(--token, oklch(...))` fallbacks are exempt

  The full contract — including the token vocabularies, scope rules, the
  allow-list comment syntax, and the documented detection limitations — lives
  in `docs/dark-mode-contract.md`.

  ## Usage

      mix dark_mode.scan

  Exits 0 when no unallow-listed violations are found, 1 otherwise.

  ## Allow-listing

  Place a `dark-mode-ignore: <reason>` marker on the violating line OR on
  one of the 10 immediately preceding lines. Any of these comment shapes is
  accepted:

      # dark-mode-ignore: <reason>
      <%# dark-mode-ignore: <reason> %>
      <!-- dark-mode-ignore: <reason> -->

  ## Known limitations

  Multi-line `style={[ ... ]}` list continuation lines ARE now scanned (W938):
  raw `oklch(...)`/hex on them is flagged, with `var(--token, oklch(...))`
  fallbacks exempt. Two limitations remain by design:

    * Bare `oklch()`/hex that sits OUTSIDE any `style=` attribute is not
      flagged — doing so false-positives on legitimate `var(--token,
      oklch(...))` fallbacks and on intentional fixed-palette components
      (avatars, the light-locked auth frame).
    * `assets/css/app.css` itself is not scanned — it legitimately *defines*
      the oklch tokens, so a literal scan there is meaningless; legibility of
      those values is measured by `mix dark_mode.contrast` instead.
    * Two narrow line-based edge cases (both allow-listable, effectively absent
      in practice): a `var()` fallback whose colour argument itself wraps a
      nested function (e.g. `var(--ink, oklch(calc(…) …))`) is only partially
      stripped and can false-positive, and a CSS value literally containing
      `]}` ends the style-list scan one line early.

  See `docs/dark-mode-contract.md`.
  """
  use Mix.Task

  @scan_root "lib/kanban_web"
  @extensions ~w(.ex .heex .eex)
  @ignore_marker "dark-mode-ignore"

  # Numbered Tailwind palette colours (the theme-blind families). daisyUI
  # semantic names (base, primary, secondary, accent, neutral, info, success,
  # warning, error) are deliberately absent — they ARE theme-aware.
  @palette "red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|slate|gray|zinc|neutral|stone"
  # Utility prefixes that take a colour.
  @prefix "text|bg|border|from|via|to|ring|fill|stroke|divide|outline"

  @class_violation_pattern ~r/(?<![\w-])(text-gray-\d+|bg-gray-\d+|border-gray-\d+|bg-white|text-white|text-black|bg-black)(?![\w-])/
  @colored_utility_pattern Regex.compile!("(?<![\\w-])(#{@prefix})-(#{@palette})-\\d+(?![\\w-])")
  @arbitrary_hex_pattern Regex.compile!(
                           "(?<![\\w-])(#{@prefix})-\\[#[0-9a-fA-F]{3,8}\\](?![\\w-])"
                         )
  # Match oklch()/hex inside either a string-literal `style="..."` or an
  # expression `style={"..."}` (single-line form).
  @inline_oklch_pattern ~r/style=\{?"[^"]*\boklch\s*\([^"]*"/
  @inline_hex_pattern ~r/style=\{?"[^"]*#[0-9a-fA-F]{3,8}\b[^"]*"/

  # Raw color literals used to close the multi-line `style={[ ... ]}` blind spot
  # (see `style_list_linenos/1`). A `var(--token, oklch(...))` fallback is
  # legitimate, so var(...) — including one level of nested parens, which covers
  # the oklch/hex fallback inside it — is stripped before these are applied.
  @bare_oklch_pattern ~r/\boklch\s*\(/
  @bare_hex_pattern ~r/#[0-9a-fA-F]{3,8}\b/
  @var_fallback_pattern ~r/var\((?:[^()]|\([^()]*\))*\)/

  @impl Mix.Task
  def run(_args) do
    violations =
      @scan_root
      |> list_source_files()
      |> Enum.flat_map(&scan_file/1)

    if violations == [] do
      # Silent on success — Unix CLI convention. Violations still print to
      # stderr below. This keeps the scanner quiet when invoked from inside
      # mix test (the scan_test.exs integration test calls Scan.run/1 and
      # used to flush a clean-status line into the test progress output).
      :ok
    else
      print_violations(violations)
      Mix.shell().error("dark_mode.scan: #{length(violations)} violation(s) found.")

      Mix.shell().error(
        "Allow-list with a 'dark-mode-ignore: <reason>' comment on the same or previous line."
      )

      exit({:shutdown, 1})
    end
  end

  defp list_source_files(root) do
    root
    |> wildcard_under()
    |> Enum.filter(&(Path.extname(&1) in @extensions))
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end

  defp wildcard_under(root) do
    case File.stat(root) do
      {:ok, _} -> root |> Path.join("**/*.{ex,heex,eex}") |> Path.wildcard()
      _ -> []
    end
  end

  # Look back this many lines for an `dark-mode-ignore:` marker. HEEx commonly
  # splits an element's open tag, attributes, and class/style value across many
  # lines (10+ in some cases), so a marker placed above the opening tag may sit
  # well before the actual flagged string. 10 covers every spread in the
  # current tree while still keeping the marker visually associated with the
  # violation.
  @ignore_lookback 10

  defp scan_file(path) do
    lines = read_indexed_lines(path)
    lines_map = Map.new(lines, fn {line, lineno} -> {lineno, line} end)
    style_lines = style_list_linenos(lines)
    Enum.flat_map(lines, fn entry -> classify(entry, lines_map, style_lines, path) end)
  end

  # Line numbers that fall inside a `style={[ ... ]}` list — from the line that
  # opens it (`style={[`) through the line that closes it (`]}`). Raw oklch()/hex
  # on these continuation lines are flagged the same way the single-line
  # `style="..."` form is, closing the documented multi-line blind spot.
  defp style_list_linenos(lines) do
    {set, _open?} = Enum.reduce(lines, {MapSet.new(), false}, &track_style_line/2)
    set
  end

  defp track_style_line({line, lineno}, {set, open?}) do
    active? = open? or String.contains?(line, "style={[")
    set = if active?, do: MapSet.put(set, lineno), else: set
    closes? = active? and String.contains?(line, "]}")
    {set, active? and not closes?}
  end

  defp read_indexed_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
  end

  defp classify({line, lineno}, lines_map, style_lines, path) do
    cond do
      ignored?(lines_map, lineno) ->
        []

      match = first_match(line, MapSet.member?(style_lines, lineno)) ->
        [{path, lineno, line, match}]

      true ->
        []
    end
  end

  defp first_match(line, in_style_list?) do
    class_or_inline_match(line) || style_list_match(line, in_style_list?)
  end

  defp class_or_inline_match(line) do
    cond do
      m = Regex.run(@class_violation_pattern, line, capture: :first) -> hd(m)
      m = Regex.run(@colored_utility_pattern, line, capture: :first) -> hd(m)
      m = Regex.run(@arbitrary_hex_pattern, line, capture: :first) -> hd(m)
      Regex.run(@inline_oklch_pattern, line) -> "inline oklch()"
      Regex.run(@inline_hex_pattern, line) -> "inline hex color"
      true -> nil
    end
  end

  defp style_list_match(_line, false), do: nil

  defp style_list_match(line, true) do
    cond do
      raw_color_in_style?(line, @bare_oklch_pattern) -> "oklch() in style={[ … ]} list"
      raw_color_in_style?(line, @bare_hex_pattern) -> "hex color in style={[ … ]} list"
      true -> nil
    end
  end

  # True when `line` carries a raw color literal that is NOT inside a
  # `var(--token, <fallback>)` expression (those fallbacks are legitimate).
  defp raw_color_in_style?(line, pattern) do
    stripped = Regex.replace(@var_fallback_pattern, line, "")
    Regex.match?(pattern, stripped)
  end

  defp ignored?(lines_map, lineno) do
    Enum.any?((lineno - @ignore_lookback)..lineno, fn n ->
      has_marker?(Map.get(lines_map, n))
    end)
  end

  defp has_marker?(nil), do: false
  defp has_marker?(line), do: String.contains?(line, @ignore_marker)

  defp print_violations(violations) do
    Enum.each(violations, fn {path, lineno, line, match} ->
      Mix.shell().info("#{path}:#{lineno}: #{match}")
      Mix.shell().info("  #{String.trim(line)}")
    end)
  end
end
