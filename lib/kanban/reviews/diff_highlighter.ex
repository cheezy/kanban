defmodule Kanban.Reviews.DiffHighlighter do
  @moduledoc """
  Turns one file's unified diff into display lines with syntax highlighting,
  on the server (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.6,
  decision 11).

  Each line is a map with a `kind` (`:add`, `:del`, `:ctx` or `:hunk`), its
  `old` and `new` line numbers (`nil` where a side has none) and a list of
  spans. A span is `%{class: class, text: text}`, and `class` is one of the
  nine fixed classes in `classes/0`. The highlighter returns text, never
  HTML: a client renders each span's text as text, so diff content cannot
  inject markup.

  The file extension picks the lexer. Elixir (`.ex`, `.exs`), HEEx (`.heex`)
  and Erlang (`.erl`, `.hrl`) use their Makeup lexers. JavaScript and CSS
  stay plain: no Makeup lexer for either is maintained on Hex (the
  candidates have one release each, or one burst of releases years ago), and
  decision 11 prefers plain text to an unmaintained lexer. Every other
  extension, and a file with none, is plain too.

  Each hunk is lexed on its own with the `+`, `-` and space prefixes
  stripped, so a hunk that starts inside a string may be classed oddly but
  never fails: a lexer error or a result that does not rebuild the input text
  falls back to plain spans. At most 500 lines are returned, the same cap the
  diff contract puts on a captured diff, and at most 100,000 bytes of one diff
  are lexed in all: a hunk that would take the total past that is plain.

  `lines/2` is pure. `highlight/4` caches its result in
  `Kanban.Reviews.DiffCache` for an hour, except for a diff over 1 MB, which
  is highlighted on every call rather than held in memory.
  """

  alias Kanban.ChangedFiles.Backfill
  alias Kanban.Reviews.DiffCache

  @classes [:keyword, :string, :atom, :comment, :function, :module, :number, :operator, :plain]

  # Matches the 500-line cap in docs/diff-contract.md (Kanban.ChangedFiles.Backfill).
  @max_lines 500
  # Total bytes of one diff handed to a lexer; the rest is plain.
  @max_lex_bytes 100_000
  # A diff larger than this is highlighted but never cached.
  @max_cached_bytes 1_000_000

  @lexers %{
    ".ex" => {Makeup.Lexers.ElixirLexer, []},
    ".exs" => {Makeup.Lexers.ElixirLexer, []},
    ".heex" => {Makeup.Lexers.HEExLexer, [outer_lexer: Makeup.Lexers.HTMLLexer]},
    ".erl" => {Makeup.Lexers.ErlangLexer, []},
    ".hrl" => {Makeup.Lexers.ErlangLexer, []}
  }

  # Makeup token types with a class of their own; the rest go by prefix.
  @exact_classes %{
    string_symbol: :atom,
    name_attribute: :atom,
    name_constant: :atom,
    name_class: :module,
    name_namespace: :module,
    name_builtin_pseudo: :module,
    name_tag: :keyword,
    operator: :operator,
    operator_word: :keyword
  }

  @prefix_classes [
    {"comment", :comment},
    {"keyword", :keyword},
    {"string", :string},
    {"number", :number},
    {"name_function", :function}
  ]

  @initial_state %{started: false, old: nil, new: nil, old_left: 0, new_left: 0}

  @type kind :: :add | :del | :ctx | :hunk
  @type class ::
          :keyword
          | :string
          | :atom
          | :comment
          | :function
          | :module
          | :number
          | :operator
          | :plain
  @type span :: %{class: class(), text: String.t()}
  @type line :: %{
          kind: kind(),
          old: pos_integer() | nil,
          new: pos_integer() | nil,
          spans: [span()]
        }

  @doc "The nine span classes."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc "The most lines `lines/2` returns: #{@max_lines}."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc """
  The language `path` is highlighted as, chosen by its extension as the
  lexer is: `:elixir`, `:heex`, `:erlang`, or `:plain` for every other
  extension, a file with none, and `nil`.
  """
  @spec language(String.t() | nil) :: :elixir | :heex | :erlang | :plain
  def language(path) do
    case lexer_for(path) do
      {Makeup.Lexers.ElixirLexer, _opts} -> :elixir
      {Makeup.Lexers.HEExLexer, _opts} -> :heex
      {Makeup.Lexers.ErlangLexer, _opts} -> :erlang
      nil -> :plain
    end
  end

  @doc """
  Highlights one file's diff, cached by task id, file index, diff hash and path.

  `file_index` is the file's position in the task's `changed_files`. An empty
  or `nil` diff returns `[]`; neither it nor a diff over 1 MB is cached.
  """
  @spec highlight(term(), non_neg_integer(), String.t() | nil, String.t() | nil) :: [line()]
  def highlight(_task_id, _file_index, diff, _path) when diff in [nil, ""], do: []

  def highlight(_task_id, _file_index, diff, path)
      when is_binary(diff) and byte_size(diff) > @max_cached_bytes,
      do: lines(diff, path)

  def highlight(task_id, file_index, diff, path) when is_binary(diff) do
    task_id
    |> DiffCache.key(file_index, diff, path)
    |> DiffCache.fetch_or_compute(fn -> lines(diff, path) end, weight: weight(diff))
  end

  # The off-heap bytes a cached result can hold alive: span texts are cut from
  # lines/2's own copy of the diff and from each lexed hunk's text, which
  # together are at most the diff plus twice the lexing budget.
  defp weight(diff), do: byte_size(diff) + 2 * @max_lex_bytes

  @doc """
  Turns a unified diff into display lines, without the cache.

  Lines before the first hunk header (`diff --git`, `---`, `+++`, a binary
  file note) are dropped, as is the truncation marker. A `\\ No newline at end
  of file` note is a `:ctx` line with no numbers.
  """
  @spec lines(String.t() | nil, String.t() | nil) :: [line()]
  def lines(nil, _path), do: []

  def lines(diff, path) when is_binary(diff) do
    lexer = lexer_for(path)

    diff
    |> String.replace("\0", "")
    |> String.replace_invalid()
    # Span texts point into this copy, never into whatever larger binary the
    # caller's diff was cut from, so a cached result pins only the diff.
    |> :binary.copy()
    |> parse()
    |> Enum.chunk_by(& &1.lex)
    |> Enum.flat_map_reduce(@max_lex_bytes, &render(&1, lexer, &2))
    |> elem(0)
  end

  ## Parsing

  defp parse(diff) do
    diff
    |> String.splitter("\n")
    |> Enum.reduce_while({[], 0, @initial_state}, &collect/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp collect(raw, {acc, count, state}) do
    case step(raw, state) do
      {nil, state} -> {:cont, {acc, count, state}}
      {entry, state} -> keep(entry, acc, count + 1, state)
    end
  end

  defp keep(entry, acc, count, state) when count >= @max_lines,
    do: {:halt, {[entry | acc], count, state}}

  defp keep(entry, acc, count, state), do: {:cont, {[entry | acc], count, state}}

  defp step("@@" <> _ = raw, state),
    do: {entry(:hunk, nil, nil, raw, false), open_hunk(raw, state)}

  defp step(_raw, %{started: false} = state), do: {nil, state}

  defp step(raw, state) do
    cond do
      raw == Backfill.truncation_marker() -> {nil, state}
      state.old_left > 0 or state.new_left > 0 -> content(raw, state)
      trailing_content?(raw) -> content(raw, state)
      true -> {nil, state}
    end
  end

  # Past a hunk's counts only a diff line can follow; a header for another
  # file or stray text is dropped.
  defp trailing_content?(raw) do
    String.starts_with?(raw, ["+", "-", " ", "\\"]) and
      not String.starts_with?(raw, ["+++ ", "--- "])
  end

  defp content("+" <> code, state),
    do: {entry(:add, nil, state.new, code, true), advance(state, :new)}

  defp content("-" <> code, state),
    do: {entry(:del, state.old, nil, code, true), advance(state, :old)}

  defp content("\\" <> _ = raw, state), do: {entry(:ctx, nil, nil, raw, false), state}
  defp content(" " <> code, state), do: context(code, state)
  defp content(code, state), do: context(code, state)

  defp context(code, state) do
    {entry(:ctx, state.old, state.new, code, true), state |> advance(:old) |> advance(:new)}
  end

  defp advance(state, :old),
    do: %{state | old: bump(state.old), old_left: max(state.old_left - 1, 0)}

  defp advance(state, :new),
    do: %{state | new: bump(state.new), new_left: max(state.new_left - 1, 0)}

  defp bump(nil), do: nil
  defp bump(number), do: number + 1

  defp open_hunk(raw, state) do
    case parse_header(raw) do
      {:ok, {old, old_count}, {new, new_count}} ->
        %{state | started: true, old: old, new: new, old_left: old_count, new_left: new_count}

      :error ->
        %{state | started: true, old: nil, new: nil, old_left: 0, new_left: 0}
    end
  end

  defp parse_header("@@ -" <> rest) do
    with [old_range, "+" <> new_range, "@@" <> _] <- String.split(rest, " ", parts: 3),
         {:ok, old} <- parse_range(old_range),
         {:ok, new} <- parse_range(new_range) do
      {:ok, old, new}
    else
      _ -> :error
    end
  end

  defp parse_header(_raw), do: :error

  defp parse_range(range) do
    case String.split(range, ",") do
      [start] -> parse_numbers(start, "1")
      [start, count] -> parse_numbers(start, count)
      _ -> :error
    end
  end

  defp parse_numbers(start, count) do
    with {start, ""} <- Integer.parse(start),
         {count, ""} <- Integer.parse(count) do
      {:ok, {start, count}}
    else
      _ -> :error
    end
  end

  defp entry(kind, old, new, code, lex),
    do: %{kind: kind, old: old, new: new, code: code, lex: lex}

  ## Rendering

  defp lexer_for(path) when is_binary(path),
    do: Map.get(@lexers, path |> Path.extname() |> String.downcase())

  defp lexer_for(_path), do: nil

  # `budget` is the bytes still allowed to reach a lexer for this diff.
  defp render([%{lex: true} | _] = chunk, {lexer, opts}, budget) do
    codes = Enum.map(chunk, & &1.code)
    {result, spent} = lex_lines(Enum.join(codes, "\n"), codes, lexer, opts, budget)

    {lines_for(chunk, result), budget - spent}
  end

  defp render(chunk, _lexer, budget), do: {plain(chunk), budget}

  defp lines_for(chunk, {:ok, spans}), do: Enum.zip_with(chunk, spans, &finish/2)
  defp lines_for(chunk, _result), do: plain(chunk)

  defp plain(chunk), do: Enum.map(chunk, &finish(&1, plain_spans(&1.code)))

  defp finish(entry, spans), do: %{kind: entry.kind, old: entry.old, new: entry.new, spans: spans}

  defp plain_spans(""), do: []
  defp plain_spans(text), do: [%{class: :plain, text: text}]

  # Returns the result and the bytes it spent from the budget.
  defp lex_lines(text, _codes, _lexer, _opts, budget) when byte_size(text) > budget,
    do: {:skipped, 0}

  defp lex_lines(text, codes, lexer, opts, _budget) do
    result =
      with {:ok, lines} <- safe_lex(lexer, text, opts),
           true <- Enum.map(lines, &join_spans/1) == codes do
        {:ok, lines}
      else
        _ -> :error
      end

    {result, byte_size(text)}
  end

  defp safe_lex(lexer, text, opts) do
    {:ok, text |> lexer.lex(opts) |> to_lines()}
  rescue
    _error -> :error
  end

  defp join_spans(spans), do: Enum.map_join(spans, & &1.text)

  # Tokens can span lines, so split each token's text on newlines.
  defp to_lines(tokens) do
    {done, current} =
      Enum.reduce(tokens, {[], []}, fn {type, _meta, value}, acc ->
        add_token(acc, token_class(type), token_text(value))
      end)

    Enum.reverse([Enum.reverse(current) | done])
  end

  defp add_token({done, current}, class, text) do
    [first | rest] = String.split(text, "\n")

    Enum.reduce(rest, {done, push(current, class, first)}, fn piece, {done, current} ->
      {[Enum.reverse(current) | done], push([], class, piece)}
    end)
  end

  defp push(current, _class, ""), do: current

  defp push([%{class: class, text: previous} | rest], class, text),
    do: [%{class: class, text: previous <> text} | rest]

  defp push(current, class, text), do: [%{class: class, text: text} | current]

  defp token_text(value) when is_binary(value), do: value
  defp token_text(value) when is_integer(value), do: <<value::utf8>>
  defp token_text(value), do: IO.chardata_to_string(value)

  defp token_class(type) when is_atom(type) do
    Map.get_lazy(@exact_classes, type, fn -> prefix_class(Atom.to_string(type)) end)
  end

  defp token_class(_type), do: :plain

  defp prefix_class(name) do
    Enum.find_value(@prefix_classes, :plain, fn {prefix, class} ->
      String.starts_with?(name, prefix) && class
    end)
  end
end
