defmodule KanbanWeb.UnsubscribeToken do
  @moduledoc """
  Signed tokens for the one-click unsubscribe links in notification emails.

  A token identifies exactly one user and one notification event type, is
  signed with the endpoint secret under a purpose-specific salt, and expires
  after 90 days. It grants nothing beyond turning that one email category off,
  so it can travel in an email link and work without a session.
  """

  alias Kanban.Notifications.Preference

  @salt "notification-unsubscribe"
  @max_age 90 * 24 * 60 * 60

  @doc """
  Signs a token for `user_id` and `event_type`.

  `opts` accepts `:signed_at` (unix seconds), used by tests to mint tokens of
  a given age.
  """
  @spec sign(pos_integer(), atom(), keyword()) :: String.t()
  def sign(user_id, event_type, opts \\ []) when is_integer(user_id) and is_atom(event_type) do
    data = %{"user_id" => user_id, "event_type" => Atom.to_string(event_type)}
    Phoenix.Token.sign(KanbanWeb.Endpoint, @salt, data, Keyword.take(opts, [:signed_at]))
  end

  @doc """
  Verifies a token and returns the user id and event type it was issued for.

  Returns `{:error, :expired}` for a token older than 90 days and
  `{:error, :invalid}` for a tampered token, a token signed for another
  purpose, or one naming an unknown event type.
  """
  @spec verify(term()) ::
          {:ok, %{user_id: pos_integer(), event_type: atom()}}
          | {:error, :invalid | :expired | :missing}
  def verify(token) when is_binary(token) do
    with {:ok, user_id, event_type} <- decode(token),
         {:ok, type} <- cast_event_type(event_type) do
      {:ok, %{user_id: user_id, event_type: type}}
    else
      {:error, reason} when reason in [:expired, :missing] -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  defp decode(token) do
    case Phoenix.Token.verify(KanbanWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{"user_id" => user_id, "event_type" => event_type}} when is_integer(user_id) ->
        {:ok, user_id, event_type}

      {:ok, _other} ->
        {:error, :invalid}

      {:error, _reason} = error ->
        error
    end
  end

  defp cast_event_type(event_type) when is_binary(event_type) do
    case Enum.find(Preference.event_types(), &(Atom.to_string(&1) == event_type)) do
      nil -> {:error, :invalid}
      type -> {:ok, type}
    end
  end

  defp cast_event_type(_event_type), do: {:error, :invalid}
end
