defmodule KanbanWeb.Blog.FrontMatter do
  @moduledoc """
  A strict parser for the small subset of Hugo front matter the blog posts
  use (W2950).

  The block sits between two `---` lines at the top of the file. Each line is
  `key: value`, where the value is a single- or double-quoted string, a list
  of double-quoted strings (`["a", "b"]`), the bare booleans `true` and
  `false`, or a bare token such as `cheezy`. Only the known keys are accepted:
  `title`, `date`, `draft`, `tags`, `author`, `slug` and `description`.

  `title`, `slug` and `description` must not be blank, and `slug` must be
  lower-case letters and digits joined by single hyphens, so it is safe in a
  URL.

  Anything else raises `ArgumentError` naming the file and the key or line,
  so a malformed post fails the build instead of publishing. No YAML or TOML
  library is used: the subset is small and parsing it loudly is the point.
  """

  @keys %{
    "title" => :title,
    "date" => :date,
    "draft" => :draft,
    "tags" => :tags,
    "author" => :author,
    "slug" => :slug,
    "description" => :description
  }

  @required [:title, :date, :author, :slug, :description]

  # Quoted strings that must say something: a blank one fails the build.
  @non_blank [:title, :slug, :description]

  # A slug is the last part of `/blog/<slug>`, so it stays URL-safe.
  @slug_format ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @type t :: %{
          title: String.t(),
          date: DateTime.t(),
          draft: boolean(),
          tags: [String.t()],
          author: String.t(),
          slug: String.t(),
          description: String.t()
        }

  @doc """
  The names of every front matter key a post may use, sorted.

  `test/kanban/blog_docs_test.exs` compares them with the key table in
  `docs/blog.md`, so the guide cannot drift from the parser.
  """
  @spec keys() :: [String.t()]
  def keys, do: @keys |> Map.keys() |> Enum.sort()

  @doc """
  The names of the front matter keys a post must set, sorted.
  """
  @spec required_keys() :: [String.t()]
  def required_keys, do: @required |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  @doc """
  Splits `contents`, the file at `path`, into its parsed front matter and the
  markdown body that follows it. Raises `ArgumentError` naming `path` on any
  problem.
  """
  @spec parse!(String.t(), String.t()) :: {t(), String.t()}
  def parse!(contents, path) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s, contents, capture: :all_but_first) do
      [block, body] -> {parse_block!(block, path), body}
      nil -> raise ArgumentError, "#{path}: no front matter block between --- lines"
    end
  end

  defp parse_block!(block, path) do
    fields =
      block
      |> String.split(~r/\r?\n/)
      |> Enum.with_index(2)
      |> Enum.reject(fn {line, _number} -> String.trim(line) == "" end)
      |> Enum.reduce(%{}, &put_line!(&1, &2, path))

    check_fields!(fields, path)

    Map.merge(%{draft: false, tags: []}, fields)
  end

  defp check_fields!(fields, path) do
    Enum.each(@required, &require_key!(fields, &1, path))
    Enum.each(@non_blank, &require_text!(fields, &1, path))
    check_slug!(fields.slug, path)
  end

  defp require_text!(fields, key, path) do
    if fields |> Map.fetch!(key) |> String.trim() == "" do
      raise ArgumentError, "#{path}: empty front matter key \"#{key}\""
    end
  end

  defp check_slug!(slug, path) do
    unless Regex.match?(@slug_format, slug) do
      raise ArgumentError,
            "#{path}: front matter key \"slug\" must be lower-case letters, digits and single hyphens"
    end
  end

  defp put_line!({line, number}, fields, path) do
    {key, raw} = split_line!(line, number, path)

    if Map.has_key?(fields, key) do
      raise ArgumentError, "#{path}: duplicate front matter key \"#{key}\""
    end

    Map.put(fields, key, cast!(key, value!(raw, key, path), path))
  end

  defp split_line!(line, number, path) do
    case Regex.run(~r/\A([a-z_]+):[ \t]+(.+?)\s*\z/, line, capture: :all_but_first) do
      [name, raw] -> {key!(name, path), raw}
      nil -> raise ArgumentError, "#{path}: malformed front matter line #{number}"
    end
  end

  defp key!(name, path) do
    case Map.fetch(@keys, name) do
      {:ok, key} -> key
      :error -> raise ArgumentError, "#{path}: unknown front matter key \"#{name}\""
    end
  end

  defp require_key!(fields, key, path) do
    unless Map.has_key?(fields, key) do
      raise ArgumentError, "#{path}: missing front matter key \"#{key}\""
    end
  end

  defp value!(raw, key, path) do
    case scalar(raw) || list(raw) do
      nil -> raise ArgumentError, "#{path}: malformed value for front matter key \"#{key}\""
      value -> value
    end
  end

  defp scalar("'" <> _ = raw) do
    case Regex.run(~r/\A'((?:[^']|'')*)'\z/, raw, capture: :all_but_first) do
      [inner] -> {:string, String.replace(inner, "''", "'")}
      nil -> nil
    end
  end

  defp scalar("\"" <> _ = raw) do
    case Regex.run(~r/\A"([^"\\]*)"\z/, raw, capture: :all_but_first) do
      [inner] -> {:string, inner}
      nil -> nil
    end
  end

  defp scalar(raw) do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, raw), do: {:bare, raw}
  end

  defp list(raw) do
    case Regex.run(~r/\A\[(.*)\]\z/, raw, capture: :all_but_first) do
      [inner] -> list_items(String.trim(inner))
      nil -> nil
    end
  end

  defp list_items(""), do: {:list, []}

  defp list_items(inner) do
    items = inner |> String.split(",") |> Enum.map(&scalar(String.trim(&1)))

    if Enum.all?(items, &match?({:string, _}, &1)) do
      {:list, Enum.map(items, fn {:string, item} -> item end)}
    end
  end

  defp cast!(:draft, {:bare, "true"}, _path), do: true
  defp cast!(:draft, {:bare, "false"}, _path), do: false
  defp cast!(:tags, {:list, tags}, _path), do: tags
  defp cast!(:date, {:string, value}, path), do: date!(value, path)
  defp cast!(:author, {:bare, value}, _path), do: value
  defp cast!(:author, {:string, value}, _path), do: value

  defp cast!(key, {:string, value}, _path) when key in [:title, :slug, :description],
    do: value

  defp cast!(key, _value, path) do
    raise ArgumentError, "#{path}: wrong type of value for front matter key \"#{key}\""
  end

  defp date!(value, path) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _offset} -> date
      {:error, _reason} -> raise ArgumentError, "#{path}: invalid front matter key \"date\""
    end
  end
end
