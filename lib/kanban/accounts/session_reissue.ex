defmodule Kanban.Accounts.SessionReissue do
  @moduledoc """
  Session-token reissue and the family of tokens it links (D425).

  A reissue mints a successor and records it on the replaced token's
  `replaced_by_id`. The replaced token stays valid for a short grace window so
  a lost response or a parallel request cannot sign the user out, but a replay
  of it during that window is handed the recorded successor rather than a new
  token. So one browser session never has more than one live successor, and
  revoking the successor deletes the token it replaced through the
  `ON DELETE CASCADE` on `replaced_by_id`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.UserToken
  alias Kanban.Repo

  @doc """
  Reissues the session `token` for `user`, whose own lookup has just verified
  it, and returns `{:ok, successor_token, replaced_id}`.

  The replaced token's row is locked, so of two requests reissuing the same
  token only one mints a successor and the other is handed it. A token that
  already has a valid successor is handed that successor. Otherwise a new one
  is minted, linked, and the replaced token is left valid for at most
  `grace_seconds` more; the third element is then the replaced token's id, for
  scheduling its revocation, and `nil` when an existing successor was handed
  back. Returns `{:error, :not_found}` when the token is gone.
  """
  def reissue(user, token, grace_seconds) do
    fn ->
      case lock_session_row(token) do
        nil -> {:error, :not_found}
        row -> {:ok, successor(row) || mint_successor(user, row, grace_seconds)}
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, {successor_token, replaced_id}} -> {:ok, successor_token, replaced_id}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Deletes `token`, every token it replaced, and every token that replaced it,
  and returns the raw tokens it deleted so their LiveView pages can be
  disconnected. Returns `[]` for an unknown token.
  """
  def revoke_family(token) do
    case token |> session_row_query() |> Repo.one() do
      nil ->
        []

      row ->
        family = collect_family([row], MapSet.new([row.id]))
        ids = Enum.map(family, & &1.id)
        UserToken |> where([t], t.id in ^ids) |> Repo.delete_all()
        Enum.map(family, &%{token: &1.token, user_id: &1.user_id})
    end
  end

  defp lock_session_row(token) do
    token |> session_row_query() |> lock("FOR UPDATE") |> Repo.one()
  end

  defp session_row_query(token) do
    from t in UserToken, where: t.token == ^token and t.context == "session"
  end

  defp successor(%UserToken{replaced_by_id: nil}), do: nil

  defp successor(%UserToken{replaced_by_id: id}) do
    with %UserToken{token: successor_token} <- Repo.get(UserToken, id),
         {:ok, query} = UserToken.verify_session_token_query(successor_token),
         {_user, _inserted_at} <- Repo.one(query) do
      {successor_token, nil}
    else
      _gone_or_expired -> nil
    end
  end

  defp mint_successor(user, row, grace_seconds) do
    {successor_token, user_token} = UserToken.build_session_token(user)
    successor = Repo.insert!(user_token)

    from(t in UserToken, where: t.id == ^row.id)
    |> Repo.update_all(set: [replaced_by_id: successor.id])

    :ok = Kanban.Accounts.expire_user_session_token_within(row.token, grace_seconds)

    {successor_token, row.id}
  end

  @doc """
  Deletes the replaced session token with id `token_id` when its grace window
  ends, and returns its raw token so its LiveView pages can be disconnected,
  or `nil` when it was already revoked. A token never replaced is left alone.
  """
  def revoke_replaced(token_id) do
    query = from t in UserToken, where: t.id == ^token_id and not is_nil(t.replaced_by_id)

    case Repo.one(query) do
      nil ->
        nil

      row ->
        UserToken |> where([t], t.id == ^row.id) |> Repo.delete_all()
        row.token
    end
  end

  # Walks the replaced_by links both ways from the rows already found. A
  # family is a short chain, one link per reissue, so this stays a few queries.
  defp collect_family(frontier, seen) do
    next = frontier |> family_neighbours() |> Enum.reject(&MapSet.member?(seen, &1.id))

    case next do
      [] -> frontier
      _ -> frontier ++ collect_family(next, MapSet.union(seen, MapSet.new(next, & &1.id)))
    end
  end

  defp family_neighbours(rows) do
    ids = Enum.map(rows, & &1.id)
    forward = rows |> Enum.map(& &1.replaced_by_id) |> Enum.reject(&is_nil/1)

    UserToken
    |> where([t], t.context == "session" and (t.replaced_by_id in ^ids or t.id in ^forward))
    |> Repo.all()
  end
end
