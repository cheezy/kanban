defmodule KanbanWeb.AttachmentResponse do
  @moduledoc """
  Pure helpers that decide how an attachment's bytes are presented to a
  browser (W2510): the file name in `Content-Disposition`, whether a type may
  be shown inline, the `Content-Type` sent, and the security headers every
  served attachment carries. `KanbanWeb.AttachmentController` is the only
  caller.

  The rules exist because an attachment is a file a board member uploaded,
  served from the Stride origin:

    * Only `image/png`, `image/jpeg`, `image/gif` and `image/webp` are ever
      shown inline (`inline_image?/1`), judged by the type the server stored.
      SVG, HTML and PDF can carry script, so they always download.
    * A stored type outside the attachments allow-list
      (`Kanban.Attachments.ContentType.allowed?/1`) is sent as
      `application/octet-stream` (`served_content_type/1`).
    * The file name is user input and goes into a header. `safe_filename/1`
      builds an ASCII fallback with nothing but letters, digits, `.`, `_`,
      `-` and spaces, and `filename_star/1` builds the RFC 5987 `filename*`
      value with control and bidi format characters removed, then
      percent-encoded. Neither can carry a quote, a CR or an LF. Like
      `Kanban.Attachments.Filename`, `filename*` keeps U+200C and U+200D, so
      an emoji sequence or a Persian name is saved under the name it was
      stored with. A name that is only an extension (`.txt`) keeps it after
      the base name `attachment`.
    * `security_headers/0` adds `nosniff`, a `default-src 'none';
      frame-ancestors 'none'; sandbox` policy that replaces the page CSP for
      this response (no page frames an attachment: thumbnails and the
      lightbox use `<img>`, which `frame-ancestors` does not govern),
      `private, no-store` caching and a `same-origin` resource policy.
  """

  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.TaskAttachment

  @inline_types ~w(image/png image/jpeg image/gif image/webp)
  @fallback "attachment"
  @octet_stream "application/octet-stream"

  # Both values are capped in code points (the ASCII fallback is all ASCII,
  # so also in bytes); filename* is capped before percent-encoding. Code
  # points, not graphemes, so one grapheme with thousands of combining marks
  # cannot grow the header.
  @max_ascii_length 150
  @max_encoded_length 255

  # An "extension" longer than this is part of the name, not an extension.
  @max_extension_length 20

  # Control and format characters, which the served names never carry. The
  # zero-width non-joiner and joiner are kept in filename*, exactly as
  # Kanban.Attachments.Filename keeps them; the ASCII fallback would turn
  # them into "_" anyway, so it drops every format character.
  @invisible ~r/[\p{Cc}\p{Cf}]/u
  @invisible_but_joiners ~r/(?![\x{200C}\x{200D}])[\p{Cc}\p{Cf}]/u

  @security_headers [
    {"x-content-type-options", "nosniff"},
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'; sandbox"},
    {"cache-control", "private, no-store"},
    {"cross-origin-resource-policy", "same-origin"}
  ]

  @doc """
  The ASCII `filename` value for `Content-Disposition`.

  Control and format characters are removed, every other character than
  `A-Z`, `a-z`, `0-9`, `.`, `_`, `-` and a space becomes `_`, leading dots
  and spaces are dropped (a name that was only an extension gets the base
  `"#{@fallback}"`), and the name is cut to #{@max_ascii_length} characters,
  keeping its extension. A name that is empty afterwards, is not valid UTF-8
  or is not a string becomes `"#{@fallback}"`.

  ## Examples

      iex> KanbanWeb.AttachmentResponse.safe_filename("résumé.pdf")
      "r_sum_.pdf"

      iex> KanbanWeb.AttachmentResponse.safe_filename("....")
      "attachment"

  """
  @spec safe_filename(term()) :: String.t()
  def safe_filename(name) when is_binary(name) do
    if String.valid?(name) do
      ascii = Regex.replace(~r/[^A-Za-z0-9._ -]/u, Regex.replace(@invisible, name, ""), "_")

      ascii
      |> trim_name()
      |> truncate(@max_ascii_length)
      |> or_fallback()
    else
      @fallback
    end
  end

  def safe_filename(_name), do: @fallback

  @doc """
  The percent-encoded RFC 5987 `filename*` value (without its `UTF-8''`
  prefix).

  Control (`Cc`) and format (`Cf`, which includes the bidi overrides such as
  U+202E) characters are removed except the zero-width non-joiner and joiner
  (U+200C, U+200D), which `Kanban.Attachments.Filename` keeps too. `/` and
  `\\` become `_`, leading dots and spaces are dropped (a name that was only
  an extension gets the base `"#{@fallback}"`), and the name is cut to
  #{@max_encoded_length} code points, keeping its extension, before every
  byte outside the URI unreserved set is percent-encoded. A name that is empty afterwards, is not
  valid UTF-8 or is not a string becomes `"#{@fallback}"`.

  ## Examples

      iex> KanbanWeb.AttachmentResponse.filename_star("résumé.pdf")
      "r%C3%A9sum%C3%A9.pdf"

  """
  @spec filename_star(term()) :: String.t()
  def filename_star(name) when is_binary(name) do
    if String.valid?(name) do
      @invisible_but_joiners
      |> Regex.replace(name, "")
      |> String.replace(["/", "\\"], "_")
      |> trim_name()
      |> truncate(@max_encoded_length)
      |> or_fallback()
      |> URI.encode(&URI.char_unreserved?/1)
    else
      @fallback
    end
  end

  def filename_star(_name), do: @fallback

  @doc """
  The full `Content-Disposition` value: `attachment` or `inline`, the ASCII
  `filename` and the `filename*` value.

  ## Examples

      iex> KanbanWeb.AttachmentResponse.content_disposition(:attachment, "résumé.pdf")
      "attachment; filename=\\"r_sum_.pdf\\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"

  """
  @spec content_disposition(:attachment | :inline, term()) :: String.t()
  def content_disposition(disposition, filename) when disposition in [:attachment, :inline] do
    ~s(#{disposition}; filename="#{safe_filename(filename)}"; filename*=UTF-8''#{filename_star(filename)})
  end

  @doc """
  True only for the raster image types a browser may show inline:
  #{Enum.join(@inline_types, ", ")}. The match is exact, so a type with
  parameters or in another case is not inline.
  """
  @spec inline_image?(term()) :: boolean()
  def inline_image?(content_type), do: content_type in @inline_types

  @doc """
  The `Content-Type` to send: the stored type when it is on the attachments
  allow-list, else `#{@octet_stream}`.
  """
  @spec served_content_type(term()) :: String.t()
  def served_content_type(content_type) do
    if ContentType.allowed?(content_type), do: content_type, else: @octet_stream
  end

  @doc "The security headers every served attachment carries."
  @spec security_headers() :: [{String.t(), String.t()}]
  def security_headers, do: @security_headers

  @doc """
  Every response header for serving `attachment` with `disposition`: the
  content type, the content disposition and `security_headers/0`.
  """
  @spec response_headers(TaskAttachment.t(), :attachment | :inline) :: [{String.t(), String.t()}]
  def response_headers(%TaskAttachment{} = attachment, disposition) do
    [
      {"content-type", served_content_type(attachment.content_type)},
      {"content-disposition", content_disposition(disposition, attachment.filename)}
      | @security_headers
    ]
  end

  # Drops leading dots and spaces (a hidden or blank-looking name) and
  # trailing spaces. A name that was only an extension (".txt", "...png")
  # would lose the type hint it consists of, so it gets a base name instead.
  defp trim_name(name) do
    rest = Regex.replace(~r/\A[ .]+/, name, "")
    leading = binary_part(name, 0, byte_size(name) - byte_size(rest))
    rest = String.trim_trailing(rest, " ")

    if rest != "" and String.contains?(leading, ".") and not String.contains?(rest, "."),
      do: @fallback <> "." <> rest,
      else: rest
  end

  defp truncate(name, max) do
    if codepoint_length(name) <= max, do: name, else: cut(name, max, Path.extname(name))
  end

  defp cut(name, max, extension) do
    ext_length = codepoint_length(extension)

    if ext_length in 1..@max_extension_length,
      do: take_codepoints(name, max - ext_length) <> extension,
      else: take_codepoints(name, max)
  end

  defp codepoint_length(name), do: name |> String.codepoints() |> length()

  defp take_codepoints(name, count),
    do: name |> String.codepoints() |> Enum.take(count) |> Enum.join()

  defp or_fallback(""), do: @fallback
  defp or_fallback(name), do: name
end
