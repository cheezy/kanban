defmodule Kanban.SCIM.UserMapping do
  @moduledoc """
  Maps between the SCIM core User resource (RFC 7643 §4.1) and Stride's
  users (W2247).

  `userName` is the account's email address: it must be one, and it is
  compared case-insensitively. The name comes from `name.formatted`, else
  `name.givenName` and `name.familyName`, else `displayName`; the given and
  family name read back as sent while they still make up the name. `active` is
  true when the user is a member of the Organization and the account is
  enabled. `externalId` is the identity provider's own id, kept on
  `Kanban.SCIM.UserLink`.
  """

  alias Kanban.Accounts.User
  alias Kanban.SCIM.Patch
  alias Kanban.SCIM.UserLink
  alias Kanban.SSO.DomainVerification

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @max_name_length 160
  @max_external_id_length 255

  @type attributes :: %{
          email: String.t(),
          name: String.t() | nil,
          given_name: String.t() | nil,
          family_name: String.t() | nil,
          external_id: String.t() | nil,
          active: boolean()
        }

  @doc "The core User schema URN."
  @spec schema() :: String.t()
  def schema, do: @user_schema

  @doc """
  Reads a User resource sent by POST or PUT. Returns `{:error,
  :invalid_value}` when `userName` is missing or not an email address, or an
  attribute has the wrong type.
  """
  @spec from_resource(term()) :: {:ok, attributes()} | {:error, :invalid_value}
  def from_resource(%{"userName" => user_name} = resource) when is_binary(user_name) do
    with {:ok, email} <- email(user_name),
         {:ok, changes} <- resource |> Map.delete("userName") |> Patch.user_attributes(),
         {:ok, external_id} <- external_id(Map.get(changes, :external_id)) do
      {:ok, to_attributes(email, changes, external_id)}
    end
  end

  def from_resource(_resource), do: {:error, :invalid_value}

  defp to_attributes(email, changes, external_id) do
    %{
      email: email,
      name: changes |> Map.take([:formatted, :given, :family, :display]) |> name(),
      given_name: name_part(changes[:given]),
      family_name: name_part(changes[:family]),
      external_id: external_id,
      active: Map.get(changes, :active, true)
    }
  end

  @doc """
  Normalises a `userName` into the email address it names, or returns
  `{:error, :invalid_value}`.
  """
  @spec email(String.t()) :: {:ok, String.t()} | {:error, :invalid_value}
  def email(user_name) when is_binary(user_name) do
    email = DomainVerification.normalize_email(user_name)

    case DomainVerification.email_domain(email) do
      {:ok, _domain} when byte_size(email) <= 160 -> {:ok, email}
      _not_an_email -> {:error, :invalid_value}
    end
  end

  @doc "Whether `user_name` names the same account as `user`'s email."
  @spec same_user_name?(String.t(), User.t()) :: boolean()
  def same_user_name?(user_name, %User{email: email}) when is_binary(user_name),
    do: DomainVerification.normalize_email(user_name) == String.downcase(email)

  @doc "A name sliced to the length Stride stores, or `nil`."
  @spec name(map()) :: String.t() | nil
  def name(parts) do
    case Patch.compose_name(parts) do
      nil -> nil
      name -> String.slice(name, 0, @max_name_length)
    end
  end

  @doc "A given or family name, trimmed and sliced, or `nil` when it has no text."
  @spec name_part(term()) :: String.t() | nil
  def name_part(part), do: name(%{given: part})

  @doc """
  The user's given and family name: the parts the identity provider sent,
  kept on `link`, while they still make up the user's name; otherwise the
  name split at its first space.
  """
  @spec name_parts(User.t(), UserLink.t() | nil) :: %{
          given: String.t() | nil,
          family: String.t() | nil
        }
  def name_parts(%User{name: name}, %UserLink{given_name: given, family_name: family})
      when not is_nil(name) and (not is_nil(given) or not is_nil(family)) do
    if name(%{given: given, family: family}) == name,
      do: %{given: given, family: family},
      else: split_name(name)
  end

  def name_parts(%User{name: name}, _link), do: split_name(name)

  defp external_id(nil), do: {:ok, nil}

  defp external_id(value) when is_binary(value) do
    if String.length(value) <= @max_external_id_length,
      do: {:ok, value},
      else: {:error, :invalid_value}
  end

  @doc """
  Renders `user` as a User resource. `active` is whether the user is an
  active member of the Organization and `link` their SCIM link, if any.
  `location` is the resource's URL.
  """
  @spec to_resource(User.t(), boolean(), UserLink.t() | nil, String.t()) :: map()
  def to_resource(%User{} = user, active, link, location) do
    %{given: given, family: family} = name_parts(user, link)

    %{
      "schemas" => [@user_schema],
      "id" => Integer.to_string(user.id),
      "externalId" => link && link.external_id,
      "userName" => user.email,
      "name" => %{"formatted" => user.name, "givenName" => given, "familyName" => family},
      "displayName" => user.name || user.email,
      "emails" => [%{"value" => user.email, "type" => "work", "primary" => true}],
      "active" => active,
      "meta" => meta(user, link, location)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp meta(user, link, location) do
    %{
      "resourceType" => "User",
      "created" => DateTime.to_iso8601(user.inserted_at),
      "lastModified" => user |> last_modified(link) |> DateTime.to_iso8601(),
      "location" => location
    }
  end

  # A change SCIM makes to a linked account (its active state, externalId or
  # name parts) lands on the link rather than the user, so the later of the
  # two is when the resource last changed.
  defp last_modified(%User{updated_at: user_at}, %UserLink{updated_at: %DateTime{} = link_at}),
    do: Enum.max([user_at, link_at], DateTime)

  defp last_modified(%User{updated_at: user_at}, _link), do: user_at

  defp split_name(nil), do: %{given: nil, family: nil}

  defp split_name(name) do
    case String.split(name, ~r/\s+/u, parts: 2, trim: true) do
      [given, family] -> %{given: given, family: family}
      [given] -> %{given: given, family: nil}
      [] -> %{given: nil, family: nil}
    end
  end
end
