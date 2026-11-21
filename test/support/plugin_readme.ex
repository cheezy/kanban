defmodule KanbanWeb.PluginReadme do
  @moduledoc """
  Reads the install section of a Stride plugin README, for the tests that
  check the commands on `/integrations/:runtime` (W2899).

  The plugin repositories are separate checkouts that sit, gitignored, beside
  the app, so they are absent in CI. Each README's install section is
  therefore committed under `test/support/fixtures/plugin_readmes/<repo>.md`,
  and `live_path/1` names the checkout's README for the drift check that runs
  only when the checkout is present.
  """

  @fixtures_dir Path.expand("fixtures/plugin_readmes", __DIR__)

  @sections %{
    "stride" => "Installation",
    "stride-codex" => "Installation",
    "stride-codex-marketplace" => "Adding the marketplace",
    "stride-gemini" => "Installation",
    "stride-copilot" => "Installation",
    "stride-opencode" => "Installation",
    "stride-pi" => "Installation"
  }

  @doc "The repositories that have a committed install section."
  def repos, do: @sections |> Map.keys() |> Enum.sort()

  @doc "The README heading whose section holds a repository's install commands."
  def heading(repo), do: Map.fetch!(@sections, repo)

  @doc "The committed copy of a repository's install section."
  def fixture_path(repo), do: Path.join(@fixtures_dir, repo <> ".md")

  @doc "The README of the plugin checkout beside the app, which may not exist."
  def live_path(repo), do: Path.join([File.cwd!(), repo, "README.md"])

  @doc "The committed install section of `repo`."
  def fixture(repo), do: repo |> fixture_path() |> File.read!()

  @doc """
  The `## <heading>` section of `markdown`, from its heading line up to the
  next level-two heading outside a code fence. A `## ` line inside a fence
  (a `.stride.md` example, say) neither starts nor ends the section.

  A fence opens with three or more backticks or tildes and closes only on a
  line of the same character, at least as long, with nothing after it, so a
  ```` ``` ```` line inside a `~~~` or ```` ```` ```` fence is content.
  """
  def section(markdown, heading) do
    {_phase, _fence, lines} =
      markdown
      |> String.split("\n")
      |> Enum.reduce({:before, nil, []}, &section_line(&1, &2, "## " <> heading))

    lines |> Enum.reverse() |> Enum.join("\n")
  end

  defp section_line(_line, {:done, _fence, _lines} = state, _heading), do: state

  defp section_line(line, {:before, nil, []}, line), do: {:in, nil, [line]}
  defp section_line(line, {:before, fence, []}, _heading), do: {:before, step(fence, line), []}

  defp section_line(line, {:in, fence, lines}, _heading) do
    if fence == nil and String.starts_with?(line, "## "),
      do: {:done, nil, lines},
      else: {:in, step(fence, line), [line | lines]}
  end

  @doc """
  The body of every fenced code block in `markdown`, without the fence lines.
  """
  def code_blocks(markdown) do
    {blocks, _current} =
      markdown
      |> String.split("\n")
      |> Enum.reduce({[], nil}, &collect_line/2)

    Enum.reverse(blocks)
  end

  # `current` is nil outside a fence, else {fence, the fence's lines so far, reversed}.
  defp collect_line(line, {blocks, nil}) do
    case opening(line) do
      nil -> {blocks, nil}
      fence -> {blocks, {fence, []}}
    end
  end

  defp collect_line(line, {blocks, {fence, lines}}) do
    if closes?(fence, line),
      do: {[join_block(lines) | blocks], nil},
      else: {blocks, {fence, [line | lines]}}
  end

  defp join_block(lines), do: lines |> Enum.reverse() |> Enum.join("\n")

  # The fence state after `line`: nil outside a fence, else the open fence.
  defp step(nil, line), do: opening(line)
  defp step(fence, line), do: if(closes?(fence, line), do: nil, else: fence)

  # The {character, length} of the fence `line` opens, or nil.
  defp opening(line) do
    case Regex.run(~r/\A\s*(`{3,}|~{3,})/, line) do
      [_, run] -> {String.first(run), String.length(run)}
      nil -> nil
    end
  end

  defp closes?({char, length}, line) do
    trimmed = String.trim(line)

    String.length(trimmed) >= length and trimmed == String.duplicate(char, String.length(trimmed))
  end
end
