defmodule Kanban.SCIM.Filter do
  @moduledoc """
  The one SCIM filter form Stride supports (W2247): equality on one named
  attribute, `<attribute> eq "<value>"`, which is what identity providers
  send to look a user or group up before creating it.

  The attribute and the operator match case-insensitively, and the core
  schema's URN prefix may be written in front of the attribute. Every other
  form — another operator, `and`/`or`, `not`, an unquoted value, or an
  attribute the caller does not allow — is refused with `:invalid_filter`.
  """

  @filter ~r/\A\s*([A-Za-z][A-Za-z0-9:._-]*)\s+eq\s+"((?:[^"\\]|\\.)*)"\s*\z/iu
  @member_path ~r/\Amembers\s*\[\s*value\s+eq\s+"((?:[^"\\]|\\.)*)"\s*\]\z/iu
  @core_prefixes [
    "urn:ietf:params:scim:schemas:core:2.0:user:",
    "urn:ietf:params:scim:schemas:core:2.0:group:"
  ]
  @max_value_length 320

  @doc """
  Parses `filter` against the `allowed` attribute names (as the SCIM schema
  spells them, such as `"userName"`). Returns `:none` for an absent or blank
  filter, `{:ok, {attribute, value}}` with the attribute in its allowed
  spelling, or `{:error, :invalid_filter}`.

  ## Examples

      iex> Kanban.SCIM.Filter.parse(~s(userName eq "ada@example.com"), ["userName"])
      {:ok, {"userName", "ada@example.com"}}

      iex> Kanban.SCIM.Filter.parse(~s(userName co "ada"), ["userName"])
      {:error, :invalid_filter}

  """
  @spec parse(term(), [String.t()]) ::
          :none | {:ok, {String.t(), String.t()}} | {:error, :invalid_filter}
  def parse(nil, _allowed), do: :none

  def parse(filter, allowed) when is_binary(filter) do
    if String.trim(filter) == "", do: :none, else: parse_equality(filter, allowed)
  end

  def parse(_filter, _allowed), do: {:error, :invalid_filter}

  defp parse_equality(filter, allowed) do
    with [_match, attribute, raw] <- Regex.run(@filter, filter),
         {:ok, name} <- allowed_name(attribute, allowed),
         value = unescape(raw),
         true <- String.length(value) <= @max_value_length do
      {:ok, {name, value}}
    else
      _invalid -> {:error, :invalid_filter}
    end
  end

  @doc """
  Reads the member id from a Group PATCH path such as
  `members[value eq "12"]`. Returns `{:ok, id}` or `:error`.
  """
  @spec member_path(String.t()) :: {:ok, String.t()} | :error
  def member_path(path) when is_binary(path) do
    case Regex.run(@member_path, String.trim(path)) do
      [_match, raw] -> {:ok, unescape(raw)}
      nil -> :error
    end
  end

  @doc """
  Lowercases an attribute name or path and strips the core schema's URN
  prefix, so `"urn:ietf:params:scim:schemas:core:2.0:User:userName"` and
  `"USERNAME"` both read as `"username"`.
  """
  @spec normalize_attribute(String.t()) :: String.t()
  def normalize_attribute(name) when is_binary(name) do
    down = name |> String.trim() |> String.downcase()

    Enum.find_value(@core_prefixes, down, fn prefix ->
      if String.starts_with?(down, prefix), do: String.replace_prefix(down, prefix, "")
    end)
  end

  defp allowed_name(attribute, allowed) do
    normalized = normalize_attribute(attribute)

    case Enum.find(allowed, &(String.downcase(&1) == normalized)) do
      nil -> :error
      name -> {:ok, name}
    end
  end

  defp unescape(raw), do: Regex.replace(~r/\\(.)/su, raw, "\\1")
end
