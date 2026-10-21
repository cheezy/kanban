defmodule Kanban.SSO.SAML.XML do
  @moduledoc """
  Hardened XML reading for SAML (W2246), on top of `SimpleXml` (a `Saxy`
  DOM of binaries, so no atoms are created from input).

  `SimpleXml` has three sharp edges this module closes before anything is
  trusted:

    * It keeps comments and CDATA out of the DOM but splits the text around
      them, and `SimpleXml.XmlNode.text/1` returns only the first piece, so
      `alice@corp.example<!---->.attacker.example` would read as
      `alice@corp.example` while the signature still covers the whole value.
      `parse_response/1` therefore refuses any `<!` (DOCTYPE, ENTITY, comment,
      CDATA) and any processing instruction but a leading XML declaration,
      which also rules out XML external entities.
    * Its canonicalization does not escape text or attribute values again, so
      escaped markup could be turned into real markup (or the reverse) without
      changing the digest. Every text node holding `<`, `>` or `&`, and every
      attribute value holding those or `"`, is refused. A genuine document
      with such a value could not pass signature verification anyway.
    * It finds elements with unanchored name patterns (`~r/.*:?Assertion$/i`)
      and leaves any child whose name ends in `Signature` out of the digest.
      The response is refused unless it holds exactly one element whose name
      ends in `Assertion` (an `Assertion` directly under the `Response`), no
      element whose name ends in `Signature` other than `Signature`, and no
      `Signature` anywhere but directly under the `Response` or the
      `Assertion`, at most one each.

  Documents nested deeper than 64 elements are refused too.

  Every `Signature` must use exclusive canonicalization, RSA-SHA256, SHA-256
  digests and only the enveloped-signature and exclusive canonicalization
  transforms (`check_signature_algorithms/1`).

  IdP metadata is admin input read only for its entity id, sign-on URL and
  certificates, so `parse_metadata/1` refuses only a DOCTYPE or ENTITY.
  """

  @type xml_node :: {String.t(), [{String.t(), String.t()}], list()}

  @max_response_bytes 256 * 1024
  @max_metadata_bytes 512 * 1024
  @max_depth 64

  @exc_c14n "http://www.w3.org/2001/10/xml-exc-c14n#"
  @enveloped "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
  @sha256 "http://www.w3.org/2001/04/xmlenc#sha256"

  @doc "The largest decoded SAML response accepted, in bytes."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @doc "The largest IdP metadata document accepted, in bytes."
  @spec max_metadata_bytes() :: pos_integer()
  def max_metadata_bytes, do: @max_metadata_bytes

  @doc """
  Parses a decoded SAML response under the rules in the moduledoc. Returns
  `{:ok, root}`, `{:error, :response_too_large}` or `{:error, :unsafe_xml}`
  (anything refused or unparsable).
  """
  @spec parse_response(binary()) ::
          {:ok, xml_node()} | {:error, :response_too_large | :unsafe_xml}
  def parse_response(xml) when is_binary(xml) and byte_size(xml) > @max_response_bytes,
    do: {:error, :response_too_large}

  def parse_response(xml) when is_binary(xml) do
    with :ok <- check_markup(xml),
         {:ok, root} <- parse(xml),
         :ok <- check_structure(root) do
      {:ok, root}
    else
      _refused -> {:error, :unsafe_xml}
    end
  end

  def parse_response(_xml), do: {:error, :unsafe_xml}

  defp check_structure(root) do
    with :ok <- check_values(root),
         :ok <- check_assertions(root),
         :ok <- check_signature_names(root),
         :ok <- check_signature_placement(root) do
      check_depth(root, 1)
    end
  end

  @doc """
  Parses IdP metadata. Returns `{:ok, root}`, `{:error, :too_large}` or
  `{:error, :invalid}` (a DOCTYPE, an ENTITY or unparsable XML).
  """
  @spec parse_metadata(binary()) :: {:ok, xml_node()} | {:error, :too_large | :invalid}
  def parse_metadata(xml) when is_binary(xml) and byte_size(xml) > @max_metadata_bytes,
    do: {:error, :too_large}

  def parse_metadata(xml) when is_binary(xml) do
    if Regex.match?(~r/<!(DOCTYPE|ENTITY)/i, xml) do
      {:error, :invalid}
    else
      case parse(xml) do
        {:ok, root} -> {:ok, root}
        :error -> {:error, :invalid}
      end
    end
  end

  defp parse(xml) do
    case SimpleXml.parse(xml) do
      {:ok, {name, attrs, children} = root}
      when is_binary(name) and is_list(attrs) and is_list(children) ->
        {:ok, root}

      _invalid ->
        :error
    end
  rescue
    _error -> :error
  end

  # --- response guards ---------------------------------------------------------

  defp check_markup(xml) do
    body = strip_declaration(xml)

    if String.contains?(body, ["<!", "<?"]), do: :error, else: :ok
  end

  defp strip_declaration(xml) do
    trimmed = xml |> String.trim_leading("﻿") |> String.trim_leading()

    case Regex.run(~r/\A<\?xml\s[^<>?]*\?>/, trimmed) do
      [declaration] ->
        binary_part(trimmed, byte_size(declaration), byte_size(trimmed) - byte_size(declaration))

      nil ->
        trimmed
    end
  end

  defp check_values({_name, attrs, children}) do
    if Enum.all?(attrs, &safe_attribute?/1) and Enum.all?(children, &safe_child?/1),
      do: :ok,
      else: :error
  end

  defp safe_attribute?({name, value}) when is_binary(name) and is_binary(value),
    do: not String.contains?(value, ["<", ">", "&", "\""])

  defp safe_attribute?(_attribute), do: false

  defp safe_child?(text) when is_binary(text), do: not String.contains?(text, ["<", ">", "&"])
  defp safe_child?({_name, _attrs, _children} = node), do: check_values(node) == :ok
  defp safe_child?(_other), do: false

  defp check_assertions(root) do
    assertion_like = descendants(root, &name_ends_with?(&1, "assertion"))

    case {assertion_like, children(root, "Assertion"), local_name(root)} do
      {[only], [only], "Response"} -> :ok
      _other -> :error
    end
  end

  defp check_signature_names(root) do
    root
    |> descendants(&name_ends_with?(&1, "signature"))
    |> Enum.all?(&(local_name(&1) == "Signature"))
    |> if(do: :ok, else: :error)
  end

  defp name_ends_with?(name, suffix), do: name |> String.downcase() |> String.ends_with?(suffix)

  # Signatures may only envelop the Response or the Assertion, one each.
  defp check_signature_placement(root) do
    [assertion] = children(root, "Assertion")
    on_response = children(root, "Signature")
    on_assertion = children(assertion, "Signature")
    all = descendants(root, &(&1 == "Signature"))

    if length(on_response) <= 1 and length(on_assertion) <= 1 and
         length(all) == length(on_response) + length(on_assertion),
       do: :ok,
       else: :error
  end

  defp check_depth(_node, depth) when depth > @max_depth, do: :error

  defp check_depth({_name, _attrs, nodes}, depth) do
    nodes
    |> Enum.filter(&element?/1)
    |> Enum.reduce_while(:ok, fn node, :ok ->
      case check_depth(node, depth + 1) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  @doc """
  Checks the algorithms of every `Signature` in the document (see the
  moduledoc). Returns `:ok` or `{:error, :unsupported_algorithms}`; a
  document with no signature passes here and fails verification.
  """
  @spec check_signature_algorithms(xml_node()) :: :ok | {:error, :unsupported_algorithms}
  def check_signature_algorithms(root) do
    if root |> descendants(&(&1 == "Signature")) |> Enum.all?(&supported_signature?/1),
      do: :ok,
      else: {:error, :unsupported_algorithms}
  end

  defp supported_signature?(signature) do
    with {:ok, signed_info} <- child(signature, "SignedInfo"),
         true <- algorithm?(signed_info, "CanonicalizationMethod", @exc_c14n),
         true <- algorithm?(signed_info, "SignatureMethod", @rsa_sha256),
         {:ok, reference} <- child(signed_info, "Reference") do
      supported_reference?(reference)
    else
      _other -> false
    end
  end

  defp supported_reference?(reference) do
    with true <- algorithm?(reference, "DigestMethod", @sha256),
         {:ok, transforms} <- child(reference, "Transforms") do
      supported_transforms?(transforms)
    else
      _other -> false
    end
  end

  # The node has exactly one child `local` whose Algorithm is `algorithm`.
  defp algorithm?(node, local, algorithm) do
    case child(node, local) do
      {:ok, method} -> attribute(method, "Algorithm") == algorithm
      :error -> false
    end
  end

  defp supported_transforms?(transforms) do
    case children(transforms, "Transform") do
      [] -> false
      list -> Enum.all?(list, &(attribute(&1, "Algorithm") in [@enveloped, @exc_c14n]))
    end
  end

  # --- DOM helpers -------------------------------------------------------------

  @doc "The element name without its namespace prefix."
  @spec local_name(xml_node() | String.t()) :: String.t()
  def local_name({name, _attrs, _children}), do: local_name(name)

  def local_name(name) when is_binary(name) do
    case String.split(name, ":", parts: 2) do
      [_prefix, local] -> local
      [local] -> local
    end
  end

  @doc "The direct child elements whose local name is `local`."
  @spec children(xml_node(), String.t()) :: [xml_node()]
  def children({_name, _attrs, nodes}, local) when is_binary(local),
    do: Enum.filter(nodes, &(element?(&1) and local_name(&1) == local))

  @doc "The direct child element whose local name is `local`, when there is exactly one."
  @spec child(xml_node(), String.t()) :: {:ok, xml_node()} | :error
  def child(node, local) do
    case children(node, local) do
      [one] -> {:ok, one}
      _none_or_many -> :error
    end
  end

  @doc """
  Every descendant element (the node itself included) whose local name passes
  `match?`, in document order.
  """
  @spec descendants(xml_node(), (String.t() -> boolean())) :: [xml_node()]
  def descendants({_name, _attrs, nodes} = node, match?) when is_function(match?, 1) do
    own = if node |> local_name() |> match?.(), do: [node], else: []
    own ++ (nodes |> Enum.filter(&element?/1) |> Enum.flat_map(&descendants(&1, match?)))
  end

  @doc "The value of the attribute `name`, or `nil`."
  @spec attribute(xml_node(), String.t()) :: String.t() | nil
  def attribute({_name, attrs, _children}, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  @doc """
  The trimmed text of an element that holds only text, or `:error` for an
  element with child elements or no text.
  """
  @spec text(xml_node()) :: {:ok, String.t()} | :error
  def text({_name, _attrs, nodes}) do
    if Enum.all?(nodes, &is_binary/1) do
      case nodes |> Enum.join() |> String.trim() do
        "" -> :error
        text -> {:ok, text}
      end
    else
      :error
    end
  end

  @doc "All text inside an element, child elements' text included, trimmed."
  @spec all_text(xml_node()) :: String.t()
  def all_text({_name, _attrs, nodes}) do
    nodes
    |> Enum.map_join(fn
      text when is_binary(text) -> text
      {_n, _a, _c} = node -> all_text(node)
      _other -> ""
    end)
    |> String.trim()
  end

  defp element?({name, attrs, children})
       when is_binary(name) and is_list(attrs) and is_list(children),
       do: true

  defp element?(_other), do: false
end
