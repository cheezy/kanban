defmodule KanbanWeb.DocAnchors do
  @moduledoc """
  Test-only helpers that check the documentation URLs the API emits against
  the markdown files under `docs/` (D361).

  API error responses hand agents a documentation URL so they can self-correct.
  A URL whose fragment names no heading in its target file sends the agent to
  the top of the page instead of the guidance the error promised, and nothing
  else notices when a doc heading and a code link drift apart. These helpers
  are what the contract tests in `KanbanWeb.API.ErrorDocsTest` use to notice.

  An anchor is valid when it equals the GitHub slug of an ATX heading that sits
  outside every fenced code block, or an explicit `<a id="...">` /
  `<a name="...">` anchor outside a fence. Slugs follow GitHub's rule: inline
  links reduced to their text and HTML tags dropped, lowercased, every
  character that is not a letter, mark, number, connector punctuation (`_`),
  hyphen or space removed, each space turned into a hyphen, and a repeated
  slug suffixed `-1`, `-2`, ... in document order.

  Fences follow CommonMark: a fence closes only on a line of the same
  character, at least as long as the opener, carrying no info string. So a
  ```` ```bash ```` line inside a ```` ```markdown ```` block does not close it,
  and the bare ```` ``` ```` after it does.

  `Kanban.DocLinks` (D355) reuses `prose_lines/1` and `anchors/1` to check the
  relative links written inside the docs themselves, so both checks share one
  fence rule and one slug rule.
  """

  @docs_url_prefix "https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/"

  # Only plain relative paths of word-ish segments: no "..", no leading "/",
  # no backslashes — so a URL can never make the check read outside docs/.
  @doc_file ~r|\A[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.md\z|
  @fence_open ~r/\A {0,3}(`{3,}|~{3,})/
  @heading ~r/\A {0,3}[#]{1,6}(?:[ \t]+(.*?))?[ \t]*\z/
  @closing_hashes ~r/(?:\A|[ \t]+)#+\z/
  @html_anchor ~r/<a\s[^>]*?\b(?:id|name)\s*=\s*"([^"]+)"/i
  @source_link ~r|#\{@docs_base_url\}/(?:docs/)?([A-Za-z0-9_/-]+\.md)#([A-Za-z0-9_-]+)|

  @doc "The fixed HTTPS prefix every emitted documentation URL must start with."
  def docs_url_prefix, do: @docs_url_prefix

  @doc "The repository's `docs/` directory, resolved from the project root."
  def docs_dir, do: Path.join(File.cwd!(), "docs")

  @doc """
  Returns the GitHub slug for a heading's text.
  """
  def slug(text) when is_binary(text) do
    text
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/<[^>]*>/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{M}\p{N}\p{Pc} -]/u, "")
    |> String.replace(" ", "-")
  end

  @doc """
  Returns the set of anchors a markdown document exposes: de-duplicated heading
  slugs and explicit HTML anchors, both taken only from outside fenced blocks.
  """
  def anchors(markdown) when is_binary(markdown) do
    {lines, _unclosed} = prose_lines(markdown)

    {_seen, anchors} =
      Enum.reduce(lines, {%{}, MapSet.new()}, fn {_number, line}, {seen, anchors} ->
        scan_text_line(line, seen, anchors)
      end)

    anchors
  end

  @doc """
  Splits a markdown document into the lines that sit outside every fenced code
  block, using the same CommonMark fence rule as `anchors/1` (D355).

  Returns `{lines, unclosed}`. `lines` is a list of `{line_number, text}` with
  1-based line numbers, fence lines themselves excluded. `unclosed` is the line
  number of a fence still open at the end of the document, or `nil` when every
  fence closes — an open fence turns the rest of the file into code on GitHub.
  """
  def prose_lines(markdown) when is_binary(markdown) do
    {fence, lines} =
      markdown
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(1)
      |> Enum.reduce({nil, []}, &track_fence/2)

    {Enum.reverse(lines), unclosed_fence_line(fence)}
  end

  @doc """
  Collects every `https://` string from a `get_docs/2` result, whatever its
  shape: a bare string, a list, or a map whose values are any of the three.
  """
  def flatten_urls(value) when is_binary(value) do
    if String.starts_with?(value, "https://"), do: [value], else: []
  end

  def flatten_urls(value) when is_list(value), do: Enum.flat_map(value, &flatten_urls/1)
  def flatten_urls(value) when is_map(value), do: value |> Map.values() |> flatten_urls()
  def flatten_urls(_value), do: []

  @doc """
  Returns the full documentation URL of every anchored link written in an
  Elixir source file as `"\#{@docs_base_url}/<file>.md#<anchor>"`. A leading
  `docs/` is dropped, because some modules' base URL already ends in `/docs`
  and others put it in the path.
  """
  def source_doc_links(source) when is_binary(source) do
    @source_link
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [file, fragment] -> @docs_url_prefix <> file <> "#" <> fragment end)
  end

  @doc """
  Checks that a documentation URL sits under the fixed docs prefix, that its
  file exists under `docs_dir`, and that its fragment, when it has one, names
  an anchor in that file. Returns `:ok` or `{:error, message}`, where the
  message always names the URL.
  """
  def check_url(url, docs_dir \\ docs_dir()) when is_binary(url) do
    with {:ok, file, fragment} <- parse_url(url),
         {:ok, markdown} <- read_doc(docs_dir, file, url) do
      check_fragment(markdown, fragment, url)
    end
  end

  defp parse_url(url) do
    with {:ok, rest} <- strip_prefix(url) do
      {file, fragment} = split_fragment(rest)

      if Regex.match?(@doc_file, file),
        do: {:ok, file, fragment},
        else: {:error, "#{url} names a file outside the allowed docs/ pattern"}
    end
  end

  defp strip_prefix(url) do
    if String.starts_with?(url, @docs_url_prefix) do
      {:ok, String.replace_prefix(url, @docs_url_prefix, "")}
    else
      {:error, "#{url} is not under #{@docs_url_prefix}"}
    end
  end

  defp split_fragment(rest) do
    case String.split(rest, "#", parts: 2) do
      [file, fragment] -> {file, fragment}
      [file] -> {file, nil}
    end
  end

  defp read_doc(docs_dir, file, url) do
    case docs_dir |> Path.join(file) |> File.read() do
      {:ok, markdown} -> {:ok, markdown}
      {:error, _reason} -> {:error, "#{url} points at docs/#{file}, which does not exist"}
    end
  end

  defp check_fragment(_markdown, nil, _url), do: :ok

  defp check_fragment(markdown, fragment, url) do
    if markdown |> anchors() |> MapSet.member?(fragment),
      do: :ok,
      else: {:error, "#{url} has anchor ##{fragment}, which matches no heading in its file"}
  end

  defp track_fence({line, number}, {nil, lines}) do
    case Regex.run(@fence_open, line) do
      [_, marker] -> {{String.first(marker), String.length(marker), number}, lines}
      nil -> {nil, [{number, line} | lines]}
    end
  end

  defp track_fence({line, _number}, {{char, length, _opened_at} = fence, lines}) do
    if closes_fence?(line, char, length),
      do: {nil, lines},
      else: {fence, lines}
  end

  defp unclosed_fence_line(nil), do: nil
  defp unclosed_fence_line({_char, _length, opened_at}), do: opened_at

  defp closes_fence?(line, char, length) do
    trimmed = String.trim(line)
    marker = String.duplicate(char, String.length(trimmed))

    not String.starts_with?(line, "    ") and trimmed == marker and
      String.length(trimmed) >= length
  end

  defp scan_text_line(line, seen, anchors) do
    anchors = add_html_anchors(line, anchors)

    case Regex.run(@heading, line) do
      nil ->
        {seen, anchors}

      captures ->
        text = captures |> Enum.at(1, "") |> String.replace(@closing_hashes, "")
        {slug, seen} = unique_slug(slug(text), seen)
        {seen, MapSet.put(anchors, slug)}
    end
  end

  defp add_html_anchors(line, anchors) do
    @html_anchor
    |> Regex.scan(line, capture: :all_but_first)
    |> Enum.reduce(anchors, fn [id], acc -> MapSet.put(acc, id) end)
  end

  # GitHub's slugger: the first use of a slug is bare; each later use takes the
  # next free numeric suffix, and the suffixed slug is itself reserved.
  defp unique_slug(base, seen) do
    case Map.fetch(seen, base) do
      :error ->
        {base, Map.put(seen, base, 0)}

      {:ok, count} ->
        {slug, count} = next_free_slug(base, count + 1, seen)
        {slug, seen |> Map.put(base, count) |> Map.put(slug, 0)}
    end
  end

  defp next_free_slug(base, count, seen) do
    slug = "#{base}-#{count}"

    if Map.has_key?(seen, slug),
      do: next_free_slug(base, count + 1, seen),
      else: {slug, count}
  end
end
