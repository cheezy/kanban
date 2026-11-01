defmodule Kanban.Attachments.ContentType do
  @moduledoc """
  Which file types an attachment may have, and whether a file's bytes agree
  with the type it claims.

  ## The allow-list

  | Type               | Extensions          |
  |--------------------|---------------------|
  | `image/png`        | `.png`              |
  | `image/jpeg`       | `.jpg`, `.jpeg`     |
  | `image/gif`        | `.gif`              |
  | `image/webp`       | `.webp`             |
  | `application/pdf`  | `.pdf`              |
  | `text/plain`       | `.txt`, `.log`      |
  | `text/markdown`    | `.md`, `.markdown`  |
  | `text/csv`         | `.csv`              |
  | `application/json` | `.json`             |

  SVG and HTML are left out because a browser runs scripts inside them, and
  zip is left out because its contents cannot be inspected and an agent that
  unpacks one risks a zip bomb.

  Every type is a fixed string matched against these lists; no atom is ever
  made from a declared type or an extension.

  ## Normalising a declared type

  `normalize/2` drops any parameter (`text/plain; charset=utf-8` becomes
  `text/plain`), lowercases the type, and maps a few common aliases
  (`image/jpg` becomes `image/jpeg`). When the declared type is missing,
  empty or `application/octet-stream`, it infers the type from the file
  name's extension instead.

  ## The sniff

  `matches?/2` checks the first bytes of the file (the "head") against the
  type:

    * A binary type needs its own signature: PNG, JPEG, GIF87a/GIF89a,
      RIFF....WEBP, or `%PDF-`. A head shorter than the signature cannot
      match, so callers pass the first 512 bytes, or the whole file when it is
      smaller.
    * A text type is contradicted only by a NUL byte in the head or by a
      known binary signature (the five above, or a zip). Text is never
      required to be UTF-8, because Latin-1 CSV exports are common. A text
      file that happens to start with the letters `MZ` is accepted: Windows
      executables are caught by the NUL rule instead, since their headers
      contain NUL bytes. UTF-16 text contains NUL bytes too, so it is refused.
      So is a `.txt` file whose content starts with `%PDF-`, an accepted
      trade-off.
    * The head alone cannot see a binary behind a long text prefix, so a
      text type is also checked over its whole body with `text_body?/1`.

  ## The extension

  `extension_matches?/2` refuses a file name whose extension disagrees with
  the type, so excluded content cannot be stored under an allowed type and
  then opened by its name (`report.html` declared `text/plain`).
  """

  @allowed [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "application/pdf",
    "text/plain",
    "text/markdown",
    "text/csv",
    "application/json"
  ]

  @text_types ["text/plain", "text/markdown", "text/csv", "application/json"]

  @aliases %{
    "image/jpg" => "image/jpeg",
    "image/pjpeg" => "image/jpeg",
    "text/x-markdown" => "text/markdown",
    "text/x-csv" => "text/csv"
  }

  @extensions %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".pdf" => "application/pdf",
    ".txt" => "text/plain",
    ".log" => "text/plain",
    ".md" => "text/markdown",
    ".markdown" => "text/markdown",
    ".csv" => "text/csv",
    ".json" => "application/json"
  }

  @inferred ["", "application/octet-stream"]

  @doc "Every content type an attachment may have."
  @spec allowed() :: [String.t()]
  def allowed, do: @allowed

  @doc """
  Every file extension an attachment may have, each with its leading dot and
  in lower case, sorted. Upload forms use it as their accept hint; the type
  itself is still checked by `normalize/2`, `matches?/2` and
  `extension_matches?/2` when the file is stored.
  """
  @spec extensions() :: [String.t()]
  def extensions, do: @extensions |> Map.keys() |> Enum.sort()

  @doc "Whether `type` is on the allow-list. `type` must already be normalised."
  @spec allowed?(term()) :: boolean()
  def allowed?(type), do: type in @allowed

  @doc """
  Normalises a declared content type, inferring it from `filename`'s
  extension when the declared type is missing, empty or
  `application/octet-stream`. Returns the normalised type, which may still be
  outside the allow-list, or `nil` when nothing can be determined.
  """
  @spec normalize(term(), term()) :: String.t() | nil
  def normalize(declared, filename) do
    case clean(declared) do
      type when type in @inferred -> from_extension(filename)
      type -> type
    end
  end

  @doc """
  The allowed type for `filename`'s extension (compared case-insensitively),
  or `nil` for an unknown extension or a value that is not a valid string.
  """
  @spec from_extension(term()) :: String.t() | nil
  def from_extension(filename) when is_binary(filename) do
    if String.valid?(filename) do
      Map.get(@extensions, filename |> Path.extname() |> String.downcase())
    end
  end

  def from_extension(_filename), do: nil

  @doc """
  Whether the file's first bytes, `head`, agree with `type`. Always `false`
  for a type outside the allow-list.
  """
  @spec matches?(String.t() | nil, binary()) :: boolean()
  def matches?(type, head) when type in @text_types and is_binary(head), do: text_head?(head)
  def matches?("image/png", head) when is_binary(head), do: png?(head)
  def matches?("image/jpeg", head) when is_binary(head), do: jpeg?(head)
  def matches?("image/gif", head) when is_binary(head), do: gif?(head)
  def matches?("image/webp", head) when is_binary(head), do: webp?(head)
  def matches?("application/pdf", head) when is_binary(head), do: pdf?(head)
  def matches?(_type, head) when is_binary(head), do: false

  @doc """
  Whether `type` is a text type: `text/plain`, `text/markdown`, `text/csv` or
  `application/json`. A text type has no signature, so only the whole file
  can show it is not text; see `text_body?/1`.
  """
  @spec text?(term()) :: boolean()
  def text?(type), do: type in @text_types

  @doc """
  Whether a text file's whole body, given as an enumerable of binary chunks
  (a `File.stream!/2`, or a list holding the file's bytes), contains no NUL
  byte. `matches?/2` sees only the head, so a zip archive or an executable
  hidden behind a text prefix is caught here, since both carry NUL bytes in
  their headers. A binary format with no NUL byte, such as an ASCII-only PDF,
  behind a text prefix is not caught and is stored as text: the same accepted
  trade-off as a `.txt` file that starts with `%PDF-`.
  """
  @spec text_body?(Enumerable.t()) :: boolean()
  def text_body?(chunks), do: not Enum.any?(chunks, &String.contains?(&1, <<0>>))

  @doc """
  Whether `filename`'s extension agrees with `type`, so a stored file is never
  opened by its name as something other than its type (a `report.html`, a
  `logo.svg` or a `bomb.zip` stored as `text/plain`).

  A name with no extension agrees with every type. A name that starts with a
  dot counts that dot as its extension, so `.html` or `.svg` is refused rather
  than read as extensionless (`Path.extname/1` alone would return `""` for
  it). Otherwise the extension
  must be one of the type's own (compared case-insensitively), except that
  `text/plain` also accepts the extension of any other text type, since
  clients commonly send `text/plain` for Markdown, CSV and JSON files.
  """
  @spec extension_matches?(term(), term()) :: boolean()
  def extension_matches?(type, filename) when is_binary(filename) do
    if String.valid?(filename) do
      filename |> extension() |> String.downcase() |> extension_agrees?(type)
    else
      false
    end
  end

  def extension_matches?(_type, _filename), do: false

  # Path.extname/1 returns "" for ".html"; prefixing the base name keeps a
  # leading dot's suffix as the extension.
  defp extension(filename), do: Path.extname("x" <> Path.basename(filename))

  defp extension_agrees?("", _type), do: true

  defp extension_agrees?(extension, type) do
    case Map.get(@extensions, extension) do
      nil -> false
      ^type -> true
      other -> type == "text/plain" and other in @text_types
    end
  end

  defp clean(nil), do: ""

  defp clean(declared) when is_binary(declared) do
    if String.valid?(declared), do: clean_valid(declared), else: nil
  end

  defp clean(_declared), do: nil

  defp clean_valid(declared) do
    type =
      declared
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    Map.get(@aliases, type, type)
  end

  defp text_head?(head), do: not String.contains?(head, <<0>>) and not binary_signature?(head)

  defp binary_signature?(head),
    do: png?(head) or jpeg?(head) or gif?(head) or webp?(head) or pdf?(head) or zip?(head)

  defp png?(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: true
  defp png?(_head), do: false

  defp jpeg?(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: true
  defp jpeg?(_head), do: false

  defp gif?(<<"GIF87a", _rest::binary>>), do: true
  defp gif?(<<"GIF89a", _rest::binary>>), do: true
  defp gif?(_head), do: false

  defp webp?(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: true
  defp webp?(_head), do: false

  defp pdf?(<<"%PDF-", _rest::binary>>), do: true
  defp pdf?(_head), do: false

  defp zip?(<<"PK", 0x03, 0x04, _rest::binary>>), do: true
  defp zip?(<<"PK", 0x05, 0x06, _rest::binary>>), do: true
  defp zip?(<<"PK", 0x07, 0x08, _rest::binary>>), do: true
  defp zip?(_head), do: false
end
