defmodule Kanban.Accounts.OIDC do
  @moduledoc """
  Provisions and links Stride users from verified OIDC claims.
  """

  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserIdentity
  alias Kanban.Repo

  @provider "oidc"

  @doc """
  Finds or creates a local user from OIDC claims, links the provider identity,
  records the login, and applies authoritative admin group sync when configured.
  """
  def authenticate(attrs) when is_map(attrs) do
    with {:ok, oidc} <- normalize_attrs(attrs) do
      Repo.transaction(fn ->
        with {:ok, user} <- find_or_create_user(oidc),
             {:ok, user} <- sync_admin_role(user, oidc),
             {:ok, _identity} <- upsert_identity(user, oidc) do
          user
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp normalize_attrs(attrs) do
    claims = stringify_claims(Map.get(attrs, :claims, %{}))

    oidc = %{
      issuer: string_claim(attrs, :issuer),
      subject: claim(claims, "sub"),
      email: normalize_email(claim(claims, "email")),
      name: normalize_name(claim(claims, "name")),
      admin_group_claim: Map.get(attrs, :admin_group_claim, "groups"),
      admin_groups: Map.get(attrs, :admin_groups, []),
      claims: claims
    }

    validate_oidc_attrs(oidc)
  end

  defp validate_oidc_attrs(%{issuer: issuer}) when issuer in [nil, ""],
    do: {:error, :missing_issuer}

  defp validate_oidc_attrs(%{subject: subject}) when subject in [nil, ""],
    do: {:error, :missing_subject}

  defp validate_oidc_attrs(%{email: email}) when email in [nil, ""],
    do: {:error, :missing_email}

  defp validate_oidc_attrs(oidc), do: {:ok, oidc}

  defp find_or_create_user(oidc) do
    case get_identity(oidc) do
      %UserIdentity{} = identity ->
        identity = Repo.preload(identity, :user)
        ensure_confirmed(identity.user)

      nil ->
        link_or_create_user(oidc)
    end
  end

  defp get_identity(%{issuer: issuer, subject: subject}) do
    Repo.get_by(UserIdentity, issuer: issuer, subject: subject)
  end

  defp link_or_create_user(%{email: email} = oidc) do
    case Repo.get_by(User, email: email) do
      %User{} = user -> ensure_confirmed(user)
      nil -> create_user(oidc)
    end
  end

  defp ensure_confirmed(%User{confirmed_at: nil} = user) do
    user
    |> User.confirm_changeset()
    |> Repo.update()
  end

  defp ensure_confirmed(%User{} = user), do: {:ok, user}

  defp create_user(oidc) do
    %User{}
    |> User.oidc_registration_changeset(%{email: oidc.email, name: oidc.name})
    |> Repo.insert()
  end

  defp sync_admin_role(user, %{admin_groups: []}), do: {:ok, user}

  defp sync_admin_role(user, oidc) do
    target_type = if admin_claim_matches?(oidc), do: :admin, else: :user

    if user.type == target_type do
      {:ok, user}
    else
      user
      |> User.type_changeset(target_type)
      |> Repo.update()
    end
  end

  defp admin_claim_matches?(oidc) do
    oidc.claims
    |> claim(oidc.admin_group_claim)
    |> normalize_groups()
    |> Enum.any?(&(&1 in oidc.admin_groups))
  end

  defp upsert_identity(user, oidc) do
    now = DateTime.utc_now(:second)

    attrs = %{
      provider: @provider,
      issuer: oidc.issuer,
      subject: oidc.subject,
      email: oidc.email,
      claims: oidc.claims,
      last_login_at: now
    }

    case get_identity(oidc) do
      %UserIdentity{} = identity ->
        identity
        |> UserIdentity.changeset(attrs)
        |> Repo.update()

      nil ->
        %UserIdentity{user_id: user.id}
        |> UserIdentity.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp stringify_claims(claims) when is_map(claims) do
    Map.new(claims, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_claims(value)
  defp stringify_value(value), do: value

  defp string_claim(attrs, key) do
    attrs
    |> Map.get(key)
    |> case do
      value when is_binary(value) -> String.trim(value)
      value -> value
    end
  end

  defp claim(claims, key), do: Map.get(claims, to_string(key))

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp normalize_email(_email), do: nil

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_name(_name), do: nil

  defp normalize_groups(groups) when is_list(groups) do
    groups
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_groups(groups) when is_binary(groups) do
    groups
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_groups(_groups), do: []
end
