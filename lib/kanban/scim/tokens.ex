defmodule Kanban.SCIM.Tokens do
  @moduledoc """
  An Organization's SCIM tokens (W2247): listing, creating and revoking them
  from the org console, and authenticating the token a SCIM request presents.

  Every write re-reads the acting user from the database and checks that
  they are an enabled org-admin of the Organization, whatever the page
  checked at mount, and is audited with the token's id, never its value.
  Reached through `Kanban.SCIM`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.SCIM.ScimToken

  @max_bigint 9_223_372_036_854_775_807
  # last_used_at is refreshed at most this often, so a busy identity
  # provider does not write the token row on every request.
  @touch_interval_s 60

  @doc "The Organization's tokens, newest first, with who created them."
  @spec list_tokens(integer()) :: [ScimToken.t()]
  def list_tokens(organization_id) when is_integer(organization_id) do
    from(t in ScimToken,
      where: t.organization_id == ^organization_id,
      order_by: [desc: t.inserted_at, desc: t.id],
      preload: :created_by
    )
    |> Repo.all()
  end

  @doc "A changeset for the token form."
  @spec change_token(map()) :: Ecto.Changeset.t()
  def change_token(attrs \\ %{}), do: ScimToken.form_changeset(attrs)

  @doc """
  Creates a token for the Organization with `organization_id`. Returns
  `{:ok, {token, plaintext}}`; the plaintext is never stored and must be
  shown once. Returns `{:error, :unauthorized}` unless `actor` is an enabled
  org-admin of the Organization, or `{:error, changeset}`.
  """
  @spec create_token(User.t(), integer(), map()) ::
          {:ok, {ScimToken.t(), String.t()}} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_token(%User{} = actor, organization_id, attrs) when is_integer(organization_id) do
    with {:ok, actor} <- authorize(actor, organization_id),
         {:ok, token} <-
           organization_id |> ScimToken.create_changeset(actor.id, attrs) |> Repo.insert() do
      AuditLog.event(:scim_token_created,
        user_id: actor.id,
        organization_id: organization_id,
        scim_token_id: token.id
      )

      {:ok, {%{token | token: nil}, token.token}}
    end
  end

  @doc """
  Revokes the Organization's token with `id`. Revoking a revoked token
  returns it unchanged. Returns `{:error, :not_found}` for a token of another
  Organization or an id that names no row, and `{:error, :unauthorized}`
  unless `actor` is an enabled org-admin of the Organization.
  """
  @spec revoke_token(User.t(), integer(), integer() | String.t()) ::
          {:ok, ScimToken.t()} | {:error, :unauthorized | :not_found}
  def revoke_token(%User{} = actor, organization_id, id) when is_integer(organization_id) do
    with {:ok, actor} <- authorize(actor, organization_id),
         {:ok, token} <- fetch_token(organization_id, id) do
      revoke(token, actor)
    end
  end

  defp revoke(%ScimToken{revoked_at: %DateTime{}} = token, _actor), do: {:ok, token}

  defp revoke(%ScimToken{} = token, actor) do
    {:ok, token} =
      token |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update()

    AuditLog.event(:scim_token_revoked,
      user_id: actor.id,
      organization_id: token.organization_id,
      scim_token_id: token.id
    )

    {:ok, token}
  end

  @doc """
  Authenticates a presented token. Returns `{:ok, token}` for an active one,
  else `{:error, :not_found}` or `{:error, :revoked}`, both answered alike by
  the caller. Every rejection runs the same dummy query, so the response
  time does not tell the two apart.
  """
  @spec authenticate(String.t()) :: {:ok, ScimToken.t()} | {:error, :not_found | :revoked}
  def authenticate(presented) when is_binary(presented) do
    case Repo.get_by(ScimToken, token_hash: ScimToken.hash(presented)) do
      %ScimToken{revoked_at: nil} = token -> {:ok, touch(token)}
      %ScimToken{} -> reject(:revoked)
      nil -> reject(:not_found)
    end
  end

  defp reject(reason) do
    query = from(t in ScimToken, where: t.id == -1, select: count())
    Repo.one(query)
    {:error, reason}
  end

  defp touch(%ScimToken{last_used_at: last_used_at} = token) do
    now = DateTime.utc_now(:second)

    if is_nil(last_used_at) or DateTime.diff(now, last_used_at) >= @touch_interval_s do
      from(t in ScimToken, where: t.id == ^token.id) |> Repo.update_all(set: [last_used_at: now])
      %{token | last_used_at: now}
    else
      token
    end
  end

  defp authorize(%User{id: id}, organization_id) do
    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         true <- Organizations.org_admin?(actor, organization_id) do
      {:ok, actor}
    else
      _not_an_enabled_org_admin -> {:error, :unauthorized}
    end
  end

  defp fetch_token(organization_id, id) do
    case parse_id(id) do
      nil ->
        {:error, :not_found}

      token_id ->
        case Repo.get_by(ScimToken, id: token_id, organization_id: organization_id) do
          %ScimToken{} = token -> {:ok, token}
          nil -> {:error, :not_found}
        end
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil
end
