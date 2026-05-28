defmodule Mix.Tasks.DarkMode.Scan do
  @shortdoc "Scans lib/kanban_web for hardcoded grey/white classes and inline hex/oklch literals"

  @moduledoc """
  Fails when `lib/kanban_web/` contains theme-blind colors:

    * Tailwind grey/white utility classes (`text-gray-*`, `bg-gray-*`,
      `border-gray-*`, `bg-white`, `text-white`, `text-black`, `bg-black`)
    * Inline hex color literals in `style="..."` attributes
    * Inline `oklch(...)` literals in `style="..."` attributes

  The full contract — including the three token vocabularies, scope rules,
  and the allow-list comment syntax — lives in `docs/dark-mode-contract.md`.

  ## Usage

      mix dark_mode.scan

  Exits 0 when no unallow-listed violations are found, 1 otherwise.

  ## Allow-listing

  Place a `dark-mode-ignore: <reason>` marker on the violating line OR on
  the immediately preceding line. Any of these comment shapes is accepted:

      # dark-mode-ignore: <reason>
      <%# dark-mode-ignore: <reason> %>
      <!-- dark-mode-ignore: <reason> -->
  """
  use Mix.Task

  @scan_root "lib/kanban_web"
  @extensions ~w(.ex .heex .eex)
  @ignore_marker "dark-mode-ignore"

  @class_violation_pattern ~r/(?<![\w-])(text-gray-\d+|bg-gray-\d+|border-gray-\d+|bg-white|text-white|text-black|bg-black)(?![\w-])/
  @inline_oklch_pattern ~r/style="[^"]*\boklch\s*\([^"]*"/
  @inline_hex_pattern ~r/style="[^"]*#[0-9a-fA-F]{3,8}\b[^"]*"/

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
    Enum.flat_map(lines, fn entry -> classify(entry, lines_map, path) end)
  end

  defp read_indexed_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
  end

  defp classify({line, lineno}, lines_map, path) do
    cond do
      ignored?(lines_map, lineno) -> []
      match = first_match(line) -> [{path, lineno, line, match}]
      true -> []
    end
  end

  defp first_match(line) do
    cond do
      m = Regex.run(@class_violation_pattern, line, capture: :first) -> hd(m)
      Regex.run(@inline_oklch_pattern, line) -> "inline oklch()"
      Regex.run(@inline_hex_pattern, line) -> "inline hex color"
      true -> nil
    end
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
