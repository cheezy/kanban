defmodule Kanban.Attachments.ContentType.ImageStructure do
  @moduledoc """
  Checks that an image's first bytes (the "head", up to 512 bytes) hold the
  format's real structure, not only its signature.

  A signature check alone accepts a PNG signature followed by HTML as
  `image/png`. That file is harmless while downloads carry `nosniff` and the
  sandbox CSP, but it is not an image. These checks refuse a head whose
  bytes after the signature are not what the format puts there:

    * **PNG:** the first chunk is `IHDR`, 13 bytes long, with a non-zero
      width and height. Every chunk whose header is in the head has a type of
      four ASCII letters, and every chunk wholly in the head has a CRC that
      matches. Nothing may follow `IEND`.
    * **JPEG:** after the start-of-image marker, the head is a chain of
      marker segments, each `0xFF`, a marker and a length of at least 2,
      until the start of scan (`0xDA`), the end of image or the end of the
      head. The first segment is one a JPEG starts with (`APPn`, `DQT`,
      `DHT`, `SOFn`, `DRI` or `COM`), and nothing may follow the end of image.
    * **GIF:** the logical screen descriptor is followed, after the global
      colour table when the descriptor declares one, by an extension
      (`0x21`), an image descriptor (`0x2C`) or the trailer (`0x3B`).
    * **WebP:** the first chunk is `VP8 `, `VP8L` or `VP8X`; a `VP8 ` frame
      has its start code (`9D 01 2A`) and a `VP8L` stream its signature byte
      (`0x2F`).

  A head that ends before a check can be made passes that check: the head
  is only the first 512 bytes, so a structure that continues past it cannot
  be judged, and a file shorter than its first structure is accepted as
  before. A crafted file can still hide markup inside a well-formed chunk
  (a PNG text chunk, a JPEG comment); `nosniff` and the sandbox CSP remain
  the defence for that.

  Every function takes a head that already carries the format's signature
  (`Kanban.Attachments.ContentType.matches?/2` checks it first).
  """

  import Bitwise

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  @doc "True when a PNG head's chunks are well formed as far as the head goes."
  @spec png?(binary()) :: boolean()
  def png?(<<@png_signature, rest::binary>>), do: png_first_chunk?(rest)
  def png?(_head), do: false

  defp png_first_chunk?(<<13::32, "IHDR", width::32, height::32, _::binary>> = chunks)
       when width > 0 and height > 0,
       do: png_chunks?(chunks)

  # The IHDR header is there, but its width and height are past the head.
  defp png_first_chunk?(<<13::32, "IHDR", data::binary>>) when byte_size(data) < 8, do: true
  defp png_first_chunk?(chunks) when byte_size(chunks) < 8, do: true
  defp png_first_chunk?(_chunks), do: false

  defp png_chunks?(<<>>), do: true

  defp png_chunks?(<<length::32, type::binary-size(4), rest::binary>>)
       when length < 0x80000000 do
    letters?(type) and png_chunk_body?(length, type, rest)
  end

  # Fewer than 8 bytes left: a chunk header that continues past the head.
  defp png_chunks?(rest), do: byte_size(rest) < 8

  defp png_chunk_body?(length, type, rest) do
    case rest do
      <<data::binary-size(^length), crc::32, after_chunk::binary>> ->
        :erlang.crc32(type <> data) == crc and png_after?(type, after_chunk)

      _past_the_head ->
        true
    end
  end

  defp png_after?("IEND", after_chunk), do: after_chunk == <<>>
  defp png_after?(_type, after_chunk), do: png_chunks?(after_chunk)

  defp letters?(type), do: type |> :binary.bin_to_list() |> Enum.all?(&letter?/1)

  defp letter?(byte), do: byte in ?A..?Z or byte in ?a..?z

  # The markers a JPEG's first segment can carry: SOFn and DHT (0xC0-0xCF,
  # except the arithmetic-coding JPG reserve 0xC8), DQT, DRI, APPn and COM.
  @jpeg_first_markers (Enum.to_list(0xC0..0xCF) -- [0xC8]) ++
                        [0xDB, 0xDD, 0xFE] ++ Enum.to_list(0xE0..0xEF)

  @doc "True when a JPEG head is a chain of marker segments as far as the head goes."
  @spec jpeg?(binary()) :: boolean()
  def jpeg?(<<0xFF, 0xD8, rest::binary>>), do: jpeg_first?(rest)
  def jpeg?(_head), do: false

  defp jpeg_first?(<<0xFF, 0xFF, rest::binary>>), do: jpeg_first?(<<0xFF, rest::binary>>)

  defp jpeg_first?(<<0xFF, marker, _::binary>> = segments) when marker in @jpeg_first_markers,
    do: jpeg_segments?(segments)

  defp jpeg_first?(segments), do: byte_size(segments) < 2

  defp jpeg_segments?(<<>>), do: true
  # Fill bytes: any number of 0xFF may come before a marker.
  defp jpeg_segments?(<<0xFF, 0xFF, rest::binary>>), do: jpeg_segments?(<<0xFF, rest::binary>>)
  defp jpeg_segments?(<<0xFF, 0xDA, _scan::binary>>), do: true
  defp jpeg_segments?(<<0xFF, 0xD9, after_image::binary>>), do: after_image == <<>>

  defp jpeg_segments?(<<0xFF, marker, length::16, rest::binary>>)
       when marker not in [0x00, 0xD8] and length >= 2 do
    skip = length - 2

    case rest do
      <<_segment::binary-size(^skip), next::binary>> -> jpeg_segments?(next)
      _past_the_head -> true
    end
  end

  defp jpeg_segments?(<<0xFF, marker, _::binary>> = rest) when marker not in [0x00, 0xD8],
    do: byte_size(rest) < 4

  defp jpeg_segments?(<<0xFF>>), do: true
  defp jpeg_segments?(_not_a_segment), do: false

  @doc "True when a GIF head's screen descriptor is followed by a block, as far as the head goes."
  @spec gif?(binary()) :: boolean()
  def gif?(<<"GIF8", version, "a", _width::16, _height::16, packed, _bg, _aspect, rest::binary>>)
      when version in [?7, ?9] do
    table_bytes = if (packed &&& 0x80) == 0, do: 0, else: 3 * (2 <<< (packed &&& 0x07))

    case rest do
      <<_table::binary-size(^table_bytes), introducer, _::binary>> ->
        introducer in [0x21, 0x2C, 0x3B]

      _past_the_head ->
        true
    end
  end

  def gif?(<<"GIF8", version, "a", _::binary>>) when version in [?7, ?9], do: true
  def gif?(_head), do: false

  @doc "True when a WebP head's first chunk is a VP8, VP8L or VP8X chunk."
  @spec webp?(binary()) :: boolean()
  def webp?(
        <<"RIFF", _size::32, "WEBP", "VP8 ", _chunk::32, _frame::binary-size(3), code::binary>>
      )
      when byte_size(code) >= 3,
      do: binary_part(code, 0, 3) == <<0x9D, 0x01, 0x2A>>

  def webp?(<<"RIFF", _size::32, "WEBP", "VP8L", _chunk::32, signature, _::binary>>),
    do: signature == 0x2F

  def webp?(<<"RIFF", _size::32, "WEBP", fourcc::binary-size(4), _::binary>>),
    do: fourcc in ["VP8 ", "VP8L", "VP8X"]

  def webp?(_head), do: false
end
