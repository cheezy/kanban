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
      percent-encoded. Neither can carry a quote, a CR or an LF.
    * `security_headers/0` adds `nosniff`, a `default-src 'none'; sandbox`
      policy that replaces the page CSP for this response, `private,
      no-store` caching and a `same-origin` resource policy.
  """

  alias Kanban.Attachments.ContentType
  alias Kanban.Attachments.TaskAttachment

  @inline_types ~w(image/png image/jpeg image/gif image/webp)
  @fallback "attachment"
  @octet_stream "application/octet-stream"

  # The ASCII fallback is capped in characters (all ASCII, so also bytes);
  # the filename* value is capped in characters before percent-encoding.
  @max_ascii_length 150
  @max_encoded_length 255

  # An "extension" longer than this is part of the name, not an extension.
  @max_extension_length 20

  @security_headers [
    {"x-content-type-options", "nosniff"},
    {"content-security-policy", "default-src 'none'; sandbox"},
    {"cache-control", "private, no-store"},
    {"cross-origin-resource-policy", "same-origin"}
  ]

  @doc """
  The ASCII `filename` value for `Content-Disposition`.

  Every character other than `A-Z`, `a-z`, `0-9`, `.`, `_`, `-` and a space
  becomes `_`, leading dots and spaces are dropped, and the name is cut to
  #{@max_ascii_length} characters, keeping its extension. A name that is
  empty afterwards, is not valid UTF-8 or is not a string becomes
  `"#{@fallback}"`.

  ## Examples

      iex> KanbanWeb.AttachmentResponse.safe_filename("résumé.pdf")
      "r_sum_.pdf"

      iex> KanbanWeb.AttachmentResponse.safe_filename("....")
      "attachment"

  """
  @spec safe_filename(term()) :: String.t()
  def safe_filename(name) when is_binary(name) do
    if String.valid?(name) do
      ~r/[^A-Za-z0-9._ -]/u
      |> Regex.replace(name, "_")
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
  U+202E) characters are removed, `/` and `\\` become `_`, leading dots and
  spaces are dropped, and the name is cut to #{@max_encoded_length}
  characters, keeping its extension, before every byte outside the URI
  unreserved set is percent-encoded. A name that is empty afterwards, is not
  valid UTF-8 or is not a string becomes `"#{@fallback}"`.

  ## Examples

      iex> KanbanWeb.AttachmentResponse.filename_star("résumé.pdf")
      "r%C3%A9sum%C3%A9.pdf"

  """
  @spec filename_star(term()) :: String.t()
  def filename_star(name) when is_binary(name) do
    if String.valid?(name) do
      ~r/[\p{Cc}\p{Cf}]/u
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
  # trailing spaces.
  defp trim_name(name), do: Regex.replace(~r/\A[ .]+|[ ]+\z/, name, "")

  defp truncate(name, max) do
    if String.length(name) <= max, do: name, else: cut(name, max, Path.extname(name))
  end

  defp cut(name, max, extension) do
    ext_length = String.length(extension)

    if ext_length in 1..@max_extension_length,
      do: String.slice(name, 0, max - ext_length) <> extension,
      else: String.slice(name, 0, max)
  end

  defp or_fallback(""), do: @fallback
  defp or_fallback(name), do: name
end
