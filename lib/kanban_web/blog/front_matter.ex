defmodule KanbanWeb.Blog.FrontMatter do
  @moduledoc """
  A strict parser for the small subset of Hugo front matter the blog posts
  use (W2950).

  The block sits between two `---` lines at the top of the file. Each line is
  `key: value`, where the value is a single- or double-quoted string, a list
  of double-quoted strings (`["a", "b"]`), the bare booleans `true` and
  `false`, or a bare token such as `cheezy`. Only the known keys are accepted:
  `title`, `date`, `draft`, `tags`, `author`, `slug` and `description`.

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

    Enum.each(@required, &require_key!(fields, &1, path))

    Map.merge(%{draft: false, tags: []}, fields)
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
