defmodule Kanban.DocLinks do
  @moduledoc """
  Test-only helpers that check the relative links written inside the
  repository's own markdown — every `docs/**/*.md` file plus `README.md` —
  against the files and headings they point at (D355). The rules they enforce
  are written down in `docs/doc-link-contract.md`.

  A relative link is resolved the way GitHub resolves it: against the directory
  of the file that contains it, or against the repository root when it starts
  with `/`. It is broken when that path does not exist, when it climbs out of
  the repository, or when its `#fragment` names no anchor in the target file.
  Anchors, fences and slugs come from `KanbanWeb.DocAnchors`, so this check and
  the error-docs URL check can never disagree about what a heading's anchor is.

  Only inline links (`[text](target)`) outside fenced code blocks and inline
  code spans are checked. Images, links with a scheme (`https:`, `mailto:`)
  and protocol-relative links are skipped, and so is a lone `#`. A same-file
  `#fragment` is checked against the file's own headings.

  A file that ends inside an open fence is reported too: everything after the
  opener renders as code, so its links stop being links and its headings stop
  being anchors, and the link check itself can no longer see them.
  """

  alias KanbanWeb.DocAnchors

  # [text](target) or [text](<target> "title"), not preceded by `!` (an image).
  # Link text may hold one level of nested brackets, e.g. [![badge](x)](y).
  @inline_link ~r/(?<!!)\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(<[^>]*>|[^\s()]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/u
  @code_span ~r/(`+).*?\1/u
  @external ~r/\A(?:[A-Za-z][A-Za-z0-9+.-]*:|\/\/)/

  @doc """
  Returns the markdown files the check covers, relative to `root`: every
  `docs/**/*.md` file plus `README.md`, sorted.
  """
  def markdown_files(root) when is_binary(root) do
    root
    |> Path.join("docs/**/*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> Kernel.++(["README.md"])
    |> Enum.sort()
  end

  @doc """
  Returns the relative link targets in a markdown document as
  `{line_number, target}`, in document order. Links inside fenced blocks and
  inline code spans, images, external links and a lone `#` are left out.
  """
  def links(markdown) when is_binary(markdown) do
    {lines, _unclosed} = DocAnchors.prose_lines(markdown)

    Enum.flat_map(lines, fn {number, line} ->
      line |> line_targets() |> Enum.map(&{number, &1})
    end)
  end

  defp line_targets(line) do
    prose = String.replace(line, @code_span, "")

    @inline_link
    |> Regex.scan(prose, capture: :all_but_first)
    |> Enum.map(fn [target] -> unwrap(target) end)
    |> Enum.filter(&relative?/1)
  end

  @doc """
  Checks every covered file under `root` and returns one message per broken
  link or unclosed fence. An empty list means every link resolves.
  """
  def broken_links(root) when is_binary(root) do
    root = Path.expand(root)
    root |> markdown_files() |> Enum.flat_map(&check_file(&1, root))
  end

  @doc """
  Checks one file, given by its path relative to `root`. Returns a list of
  messages, each naming the file, the line and the link target.
  """
  def check_file(source, root) when is_binary(source) and is_binary(root) do
    root = Path.expand(root)
    check_markdown(source, root |> Path.join(source) |> File.read!(), root)
  end

  @doc """
  Checks `markdown` as though it were the file at `source` (relative to
  `root`). Lets a test check text that is not on disk, resolved from a real
  location in the repository.
  """
  def check_markdown(source, markdown, root) when is_binary(markdown) do
    root = Path.expand(root)

    link_errors =
      for {line, target} <- links(markdown),
          {:error, message} <- [resolve(source, line, target, root, markdown)],
          do: message

    unclosed_fence_errors(source, markdown) ++ link_errors
  end

  @doc """
  Resolves a single link `target` written at `line` of `source`. Returns `:ok`
  or `{:error, message}`, where the message names the file, line and target.
  """
  def check_link(source, line, target, root) when is_binary(target) do
    resolve(source, line, target, Path.expand(root), nil)
  end

  defp resolve(source, line, target, root, own_markdown) do
    location = "#{source}:#{line}: #{target}"
    {path, fragment} = split_target(target)

    with {:ok, file} <- locate(source, path, root, location) do
      check_fragment(file, path, fragment, own_markdown, location)
    end
  end

  defp unwrap("<" <> rest), do: String.trim_trailing(rest, ">")
  defp unwrap(target), do: target

  defp relative?(""), do: false
  defp relative?("#"), do: false
  defp relative?(target), do: not Regex.match?(@external, target)

  defp split_target(target) do
    case String.split(target, "#", parts: 2) do
      [path, fragment] -> {decode(path), fragment}
      [path] -> {decode(path), nil}
    end
  end

  defp decode(path) do
    URI.decode(path)
  rescue
    ArgumentError -> path
  end

  defp locate(source, "", root, _location), do: {:ok, Path.join(root, source)}

  defp locate(source, path, root, location) do
    file = expand(path, source, root)

    cond do
      not inside?(file, root) ->
        {:error, "#{location} resolves outside the repository"}

      File.exists?(file) ->
        {:ok, file}

      true ->
        {:error, "#{location} points at #{Path.relative_to(file, root)}, which does not exist"}
    end
  end

  defp expand("/" <> _ = path, _source, root), do: root |> Path.join(path) |> Path.expand()
  defp expand(path, source, root), do: Path.expand(path, Path.join(root, Path.dirname(source)))

  defp inside?(file, root), do: file == root or String.starts_with?(file, root <> "/")

  defp check_fragment(_file, _path, nil, _own_markdown, _location), do: :ok

  defp check_fragment(file, path, fragment, own_markdown, location) do
    with {:ok, markdown} <- anchor_source(file, path, own_markdown, location) do
      if markdown |> DocAnchors.anchors() |> MapSet.member?(fragment),
        do: :ok,
        else: {:error, "#{location} names anchor ##{fragment}, which matches no heading"}
    end
  end

  defp anchor_source(_file, "", own_markdown, _location) when is_binary(own_markdown),
    do: {:ok, own_markdown}

  defp anchor_source(file, _path, _own_markdown, location) do
    if File.regular?(file) and Path.extname(file) == ".md",
      do: {:ok, File.read!(file)},
      else: {:error, "#{location} has a fragment, but its target is not a markdown file"}
  end

  defp unclosed_fence_errors(source, markdown) do
    case DocAnchors.prose_lines(markdown) do
      {_lines, nil} ->
        []

      {_lines, opened_at} ->
        [
          "#{source}:#{opened_at}: code fence never closes, so the rest of the file renders as code"
        ]
    end
  end
end
