defmodule Kanban.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias Kanban.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  @change_email_validity_in_days 7
  @session_validity_in_days 14
  # D105: password-reset tokens are a full account-takeover primitive, so they
  # get a dedicated, much shorter window than the 7-day change-email/confirm one.
  # D136: shortened to the 15 minutes the forgot-password page has always
  # promised — enforcement must match the user-facing copy.
  @reset_password_validity_in_minutes 15

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    belongs_to :user, Kanban.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix' default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)
    {token, %UserToken{token: token, context: "session", user_id: user.id, authenticated_at: dt}}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the token's creation time.

  The token is valid if it matches the value in the database, it has not expired
  (after @session_validity_in_days), and the user is not disabled.

  Excluding disabled users here is what makes a disable take effect on an
  existing browser session: the `fetch_current_scope_for_user` plug, every
  `on_mount` hook, and the remember-me cookie — which `ensure_user_token/1`
  funnels into this same lookup — all resolve the user through this query, and
  each already treats no result as signed out.

  API Bearer tokens do not pass through here; they are guarded separately in
  `Kanban.ApiTokens.get_api_token_by_token/1`.
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        where: is_nil(user.disabled_at),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used to validate requests to change the user
  email.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user_token found by the token, if any.

  This is used for email confirmation and other email-based tokens.
  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  """
  def verify_email_token_query(token, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Like `verify_email_token_query/2` but scoped to the `"reset_password"` context
  with the dedicated, shorter `@reset_password_validity_in_minutes` window
  (D105, tightened to match the promised 15 minutes in D136).

  A password-reset link is an account-takeover primitive; validating it against
  the 7-day change-email window left an intercepted link usable for a full week.
  """
  def verify_reset_password_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "reset_password"),
            where: token.inserted_at > ago(@reset_password_validity_in_minutes, "minute")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  The enforced password-reset link lifetime, in minutes.

  Exposed so tests (and any UI that states the lifetime) can assert against the
  single enforced value instead of hardcoding a copy of it (D136).
  """
  def reset_password_validity_in_minutes, do: @reset_password_validity_in_minutes

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  @doc """
  Returns the query to find all tokens for the given user and contexts.
  """
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, contexts) do
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
