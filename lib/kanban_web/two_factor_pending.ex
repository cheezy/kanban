defmodule KanbanWeb.TwoFactorPending do
  @moduledoc """
  The pending-login marker kept in the session between the password step and
  the second-factor challenge (W2242).

  After a correct password for a user with two-factor turned on, the session
  holds only this marker — the user id, when it was issued and the
  remember-me choice — never a session token. `POST /users/two-factor` reads
  it back, and it is accepted for five minutes after it was issued. It is
  deleted when the challenge succeeds or is refused, and a log out clears it
  with the rest of the session.

  Single sign-on stores one too (`put_sso_link/3`), when it would link an
  existing account with two-factor turned on to a new identity: the marker
  then also carries the link it waits to make (`Kanban.SSO.TwoFactorLink`),
  and an accepted code makes that link and signs the person in through single
  sign-on instead.

  The session cookie is signed, so the marker cannot be forged or altered, but
  it is not encrypted: it carries nothing beyond the user id and, for single
  sign-on, the connection id and the identity provider's subject.
  """

  import Plug.Conn, only: [get_session: 2, put_session: 3, delete_session: 2]

  alias Kanban.Accounts.User
  alias Kanban.SSO.TwoFactorLink

  @session_key :two_factor_pending
  @ttl_seconds 300

  @type t :: %{
          required(:user_id) => pos_integer(),
          required(:remember_me) => boolean(),
          optional(:sso_link) => TwoFactorLink.link()
        }

  @doc "How long a marker is accepted for, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Builds the marker stored in the session.

      iex> KanbanWeb.TwoFactorPending.new(7, true, 1_000)
      %{"user_id" => 7, "issued_at" => 1_000, "remember_me" => true}
  """
  @spec new(pos_integer(), boolean(), integer()) :: map()
  def new(user_id, remember_me, now \\ System.os_time(:second))
      when is_integer(user_id) and is_boolean(remember_me) do
    %{"user_id" => user_id, "issued_at" => now, "remember_me" => remember_me}
  end

  @doc """
  Reads a stored marker, refusing one that is missing, malformed or older
  than `ttl_seconds/0`.

      iex> KanbanWeb.TwoFactorPending.fetch(%{"user_id" => 7, "issued_at" => 1_000, "remember_me" => false}, 1_300)
      {:ok, %{user_id: 7, remember_me: false}}

      iex> KanbanWeb.TwoFactorPending.fetch(%{"user_id" => 7, "issued_at" => 1_000, "remember_me" => false}, 1_301)
      {:error, :expired}

      iex> KanbanWeb.TwoFactorPending.fetch(%{"user_id" => 7, "issued_at" => 1_000, "remember_me" => false, "sso" => %{"connection_id" => 3, "subject" => "abc"}}, 1_300)
      {:ok, %{user_id: 7, remember_me: false, sso_link: %{connection_id: 3, subject: "abc"}}}
  """
  @spec fetch(term(), integer()) :: {:ok, t()} | {:error, :expired}
  def fetch(marker, now \\ System.os_time(:second))

  def fetch(
        %{"user_id" => id, "issued_at" => issued_at, "remember_me" => remember_me} = marker,
        now
      )
      when is_integer(id) and is_integer(issued_at) and is_boolean(remember_me) and
             now - issued_at <= @ttl_seconds and issued_at <= now do
    marker
    |> Map.get("sso")
    |> with_sso_link(%{user_id: id, remember_me: remember_me})
  end

  def fetch(_marker, _now), do: {:error, :expired}

  defp with_sso_link(nil, pending), do: {:ok, pending}

  defp with_sso_link(%{"connection_id" => id, "subject" => subject}, pending)
       when is_integer(id) and is_binary(subject) and subject != "" do
    {:ok, Map.put(pending, :sso_link, %{connection_id: id, subject: subject})}
  end

  defp with_sso_link(_malformed, _pending), do: {:error, :expired}

  @doc "Reads the marker from a LiveView session map (string keys)."
  @spec from_session(map(), integer()) :: {:ok, t()} | {:error, :expired}
  def from_session(session, now \\ System.os_time(:second)) when is_map(session) do
    session
    |> Map.get(Atom.to_string(@session_key))
    |> fetch(now)
  end

  @doc """
  Stores a marker for `user`. The session is not renewed here, so a
  `:user_return_to` set before the password step survives to the challenge.
  """
  @spec put(Plug.Conn.t(), User.t(), boolean()) :: Plug.Conn.t()
  def put(conn, %User{id: id}, remember_me) do
    put_session(conn, @session_key, new(id, remember_me))
  end

  @doc """
  Stores a marker for `user` that waits to make the single sign-on `link`
  once the challenge is passed. It never asks to remember the device: a
  single sign-on session is not a remember-me one.
  """
  @spec put_sso_link(Plug.Conn.t(), User.t(), TwoFactorLink.link()) :: Plug.Conn.t()
  def put_sso_link(conn, %User{id: id}, %{connection_id: connection_id, subject: subject}) do
    marker =
      id
      |> new(false)
      |> Map.put("sso", %{"connection_id" => connection_id, "subject" => subject})

    put_session(conn, @session_key, marker)
  end

  @doc "Reads the marker from the conn's session."
  @spec get(Plug.Conn.t(), integer()) :: {:ok, t()} | {:error, :expired}
  def get(conn, now \\ System.os_time(:second)) do
    conn
    |> get_session(@session_key)
    |> fetch(now)
  end

  @doc "Removes the marker."
  @spec delete(Plug.Conn.t()) :: Plug.Conn.t()
  def delete(conn), do: delete_session(conn, @session_key)
end
