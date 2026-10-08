defmodule Kanban.Tasks.Mentions do
  @moduledoc """
  Pure helpers for `@mentions` in task comments.

  Users have names and emails but no unique handle, so free-text `@name`
  matching would be ambiguous. The only thing that counts as a mention is the
  canonical token the autocomplete inserts:

      @[Display Name](user:ID)

  `ID` is a positive integer with no leading zero. The display name is a hint
  for whoever reads the raw text only — it is never trusted: rendering shows
  the member's *current* name from the database, looked up by id.

  The three stages are deliberately separate so each can be tested on its own
  and so nothing here touches the database:

    * `parse/1` extracts the unique ids a comment's content names.
    * `resolve/2` keeps only ids of current board members and caps the
      result at `max_mentions/0`, so one comment cannot fan out to an entire
      large board. `Kanban.Tasks.Comments` supplies the member ids,
      server-side, from the comment's own board.
    * `segments/2` splits content into text and mention segments for the
      comment renderer. Segments carry raw text — HEEx does all escaping, so
      no segment is ever marked safe.
  """

  @max_mentions 20

  # A name is 1-640 code points on one line. `User.name` allows 160 graphemes,
  # and a grapheme can span several code points (combining marks, emoji
  # sequences), so the bound is four times that: every valid name fits while one
  # token stays bounded. The name in the token is never displayed. It may
  # contain `]`, `)` and `[`, but neither `@[` (which would let one token
  # swallow the next) nor `](user:` (which would let a malformed token swallow
  # the text up to a later valid one). The id is bounded to 18 digits so it
  # always fits a bigint.
  @token ~r/@\[((?:(?!\]\(user:)[^\n@]|@(?!\[)){1,640}?)\]\(user:([1-9][0-9]{0,17})\)/u

  @typedoc "A rendered piece of comment content."
  @type segment :: {:text, String.t()} | {:mention, pos_integer(), String.t()}

  @doc """
  The maximum number of distinct users one comment may mention.
  """
  @spec max_mentions() :: pos_integer()
  def max_mentions, do: @max_mentions

  @doc """
  Extracts the unique user ids named by mention tokens in `content`, in the
  order they first appear. Malformed tokens are ignored, and anything that is
  not a valid UTF-8 string yields `[]`.

  No cap is applied here; `resolve/2` caps after filtering to members, so
  tokens naming non-members cannot crowd out real mentions.

  ## Examples

      iex> Kanban.Tasks.Mentions.parse("hi @[Ada](user:7) and @[Bo](user:3), @[Ada](user:7)")
      [7, 3]

      iex> Kanban.Tasks.Mentions.parse("@[Ada](user:abc) @Ada")
      []
  """
  @spec parse(term()) :: [pos_integer()]
  def parse(content) when is_binary(content) do
    if String.valid?(content) do
      @token
      |> Regex.scan(content, capture: :all_but_first)
      |> Enum.map(fn [_name, id] -> String.to_integer(id) end)
      |> Enum.uniq()
    else
      []
    end
  end

  def parse(_content), do: []

  @doc """
  Makes `name` safe to place in a mention token, so that
  `"@[" <> token_name(name) <> "](user:ID)"` always parses as one mention.

  Line breaks become a space, `@[` becomes `@ [`, `](user:` becomes
  `] (user:`, surrounding whitespace is trimmed and the result is cut to the
  token's 640 code points. A name that leaves nothing yields `""`, which the
  caller must not put in a token. The name in a token is only a hint for raw
  text (rendering looks the member up by id), so these changes lose nothing.

  ## Examples

      iex> Kanban.Tasks.Mentions.token_name("Ada Lovelace")
      "Ada Lovelace"

      iex> Kanban.Tasks.Mentions.token_name("x@[y](user:1)\\nz")
      "x@ [y] (user:1) z"
  """
  @spec token_name(String.t()) :: String.t()
  def token_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace("@[", "@ [")
    |> String.replace("](user:", "] (user:")
    |> String.trim()
    |> String.codepoints()
    |> Enum.take(640)
    |> Enum.join()
    |> String.trim_trailing()
  end

  @doc """
  Keeps the ids in `ids` that are in `member_ids` (a list or `MapSet`),
  preserving order, and caps the result at `max_mentions/0`.

  ## Examples

      iex> Kanban.Tasks.Mentions.resolve([7, 99, 3], [3, 7])
      [7, 3]
  """
  @spec resolve([integer()], Enumerable.t()) :: [integer()]
  def resolve(ids, %MapSet{} = member_ids) when is_list(ids) do
    ids
    |> Enum.filter(&MapSet.member?(member_ids, &1))
    |> Enum.take(@max_mentions)
  end

  def resolve(ids, member_ids) when is_list(ids), do: resolve(ids, MapSet.new(member_ids))

  @doc """
  The ids in `current` that were not in `previous`, in `current`'s order —
  the users an edit newly mentions.

  ## Examples

      iex> Kanban.Tasks.Mentions.added([1, 2], [2, 3, 1, 4])
      [3, 4]
  """
  @spec added([integer()], [integer()]) :: [integer()]
  def added(previous, current) when is_list(previous) and is_list(current) do
    previous = MapSet.new(previous)
    Enum.reject(current, &MapSet.member?(previous, &1))
  end

  @doc """
  Splits `content` into text and mention segments for rendering.

  `mentions` maps user id to the display name to show. A token becomes a
  `{:mention, id, name}` segment only when its id is a key of `mentions`, and
  the name is always the one from the map, never the one in the token; every
  other token stays text. Adjacent text is merged and empty text dropped.

  Nothing is escaped: the caller must render every segment through HEEx.

  ## Examples

      iex> Kanban.Tasks.Mentions.segments("hi @[x](user:7)!", %{7 => "Ada"})
      [{:text, "hi "}, {:mention, 7, "Ada"}, {:text, "!"}]

      iex> Kanban.Tasks.Mentions.segments("hi @[x](user:8)", %{7 => "Ada"})
      [{:text, "hi @[x](user:8)"}]
  """
  @spec segments(term(), %{optional(integer()) => String.t()}) :: [segment()]
  def segments(content, mentions) when is_binary(content) and is_map(mentions) do
    if String.valid?(content) do
      content
      |> split_tokens()
      |> Enum.map(&to_segment(&1, mentions))
      |> merge_text()
    else
      []
    end
  end

  def segments(_content, _mentions), do: []

  # Returns the content as a list of {:text, binary} and {:token, id, binary}
  # pieces, in order, using match offsets so no text is re-scanned.
  defp split_tokens(content) do
    {pieces, rest_at} =
      @token
      |> Regex.scan(content, return: :index)
      |> Enum.reduce({[], 0}, &add_token_pieces(content, &1, &2))

    Enum.reverse([text_between(content, rest_at, byte_size(content)) | pieces])
  end

  # Prepends the text before one match, then the match itself, and moves the
  # cursor past the match.
  defp add_token_pieces(content, [{start, len}, _name, {id_at, id_len}], {acc, at}) do
    id = content |> binary_part(id_at, id_len) |> String.to_integer()
    token = {:token, id, binary_part(content, start, len)}
    {[token, text_between(content, at, start) | acc], start + len}
  end

  defp text_between(content, from, to), do: {:text, binary_part(content, from, to - from)}

  defp to_segment({:text, _text} = text, _mentions), do: text

  defp to_segment({:token, id, raw}, mentions) do
    case Map.fetch(mentions, id) do
      {:ok, name} -> {:mention, id, name}
      :error -> {:text, raw}
    end
  end

  defp merge_text(segments) do
    segments
    |> Enum.reduce([], fn
      {:text, ""}, acc -> acc
      {:text, text}, [{:text, previous} | acc] -> [{:text, previous <> text} | acc]
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
  end
end
