defmodule Kanban.Subscribers do
  @moduledoc """
  The release announcement list: a double opt-in email signup on
  `/changelog` (W2905).

  `subscribe/2` stores an address as `:pending` and emails it a confirmation
  link; the address becomes `:active` only when `confirm/1` is called with
  that link's token. Every email carries an unsubscribe link, and
  `unsubscribe/1` deletes the subscriber at once.

  ## What a response never reveals

  `subscribe/2` returns `:ok` for a new address, a pending one and an active
  one alike, so the form cannot be used to test whether an address is on the
  list. An address already on the list gets no second email, unless it is
  still pending and its confirmation link has expired, when one new
  confirmation is sent. Signups are rate-limited per IP (the
  `:release_signup` surface of `Kanban.RateLimit`), checked before anything
  is validated or looked up.

  Nor does the time a response takes: the request only checks the rate limit
  and validates the address. Storing it and sending the email run together
  in a supervised task for every valid signup when `:async_email_delivery`
  is on (as for account emails, `Kanban.Accounts.UserNotifier`), so a new
  address and one already on the list return equally fast. The test
  environment runs that work inline.

  ## Tokens

  Confirmation and unsubscribe tokens are random, emailed once, and stored
  only as a hash (`Kanban.Subscribers.SubscriberToken`). A confirmation
  token is valid for 7 days, an unsubscribe token for 90 days, longer
  than the 60 days CASL requires an unsubscribe link to keep working.

  ## Unconfirmed signups

  The confirmation email says an address that is not confirmed will not be
  added, so `purge_unconfirmed/2`, run daily by
  `Kanban.Retention.PurgeWorker`, deletes every pending subscriber whose
  confirmation link has expired, with its consent record and tokens.

  The list only collects subscribers. A sender of release announcements
  would follow `Kanban.Notifications.AnnouncementWorker`, email only
  `:active` subscribers in their stored locale, and call
  `issue_unsubscribe_token/1` once per email for that email's link.
  """

  import Ecto.Query

  alias Kanban.Locales
  alias Kanban.RateLimit
  alias Kanban.Repo
  alias Kanban.Subscribers.Notifier
  alias Kanban.Subscribers.Subscriber
  alias Kanban.Subscribers.SubscriberToken

  require Logger

  @confirm_days 7
  @unsubscribe_days 90

  @type subscribe_opts :: [ip: term(), locale: String.t() | nil, consent_text: String.t()]

  @doc """
  Subscribes `email` to the release list as `:pending` and emails it one
  confirmation.

  Options:

    * `:ip` — the client IP, for the per-IP rate limit
    * `:locale` — the visitor's locale; the subscriber's emails use it
    * `:consent_text` — the consent wording the visitor saw, stored with the
      time they agreed

  Returns `:ok` whether or not the address was already on the list,
  `{:error, :rate_limited}` when this IP has signed up too often, and
  `{:error, changeset}` for an empty or malformed address. With
  `:async_email_delivery` on, `:ok` returns before the address is stored.
  """
  @spec subscribe(term(), subscribe_opts()) ::
          :ok | {:error, :rate_limited} | {:error, Ecto.Changeset.t()}
  def subscribe(email, opts) do
    with :ok <- check_rate_limit(Keyword.get(opts, :ip)),
         {:ok, changeset} <- validate(email, opts) do
      in_background(fn -> sign_up(changeset) end)
    end
  end

  @doc "Whether `token` is a live confirmation token. Changes nothing."
  @spec confirm_token_valid?(term()) :: boolean()
  def confirm_token_valid?(token), do: fetch_token(token, "confirm", @confirm_days) != nil

  @doc """
  Activates the subscriber the confirmation `token` belongs to and deletes
  its confirmation tokens, so the link works once.

  It locks the subscriber row before touching its tokens, as `unsubscribe/1`
  does, so a confirm and an unsubscribe of the same subscriber run one after
  the other instead of deadlocking. A confirm that waited on either finds the
  subscriber gone or its link used, and returns `:error`.
  """
  @spec confirm(term()) :: {:ok, Subscriber.t()} | :error
  def confirm(token) do
    case Repo.transact(fn -> activate(token) end) do
      {:ok, subscriber} -> {:ok, subscriber}
      {:error, _reason} -> :error
    end
  end

  @doc "Whether `token` is a live unsubscribe token. Changes nothing."
  @spec unsubscribe_token_valid?(term()) :: boolean()
  def unsubscribe_token_valid?(token),
    do: fetch_token(token, "unsubscribe", @unsubscribe_days) != nil

  @doc """
  Deletes the subscriber the unsubscribe `token` belongs to, pending or
  active, with all its tokens. The subscriber row is locked first, in the
  same order as `confirm/1`.
  """
  @spec unsubscribe(term()) :: :ok | :error
  def unsubscribe(token) do
    case Repo.transact(fn -> remove(token) end) do
      {:ok, :deleted} -> :ok
      {:error, _reason} -> :error
    end
  end

  @doc """
  Stores a new unsubscribe token for `subscriber` and returns the value to
  put in an email's unsubscribe link. Call it once per email, so every email
  keeps its own working link.
  """
  @spec issue_unsubscribe_token(Subscriber.t()) :: String.t()
  def issue_unsubscribe_token(%Subscriber{} = subscriber), do: issue(subscriber, "unsubscribe")

  @doc """
  Deletes every pending subscriber, as of `now`, with no confirmation link
  issued in the last 7 days, together with its tokens, `batch_size` rows per
  statement. Returns how many it deleted. Active subscribers are never
  touched.
  """
  @spec purge_unconfirmed(DateTime.t(), pos_integer()) :: non_neg_integer()
  def purge_unconfirmed(%DateTime{} = now, batch_size)
      when is_integer(batch_size) and batch_size > 0,
      do: purge_unconfirmed(DateTime.add(now, -@confirm_days, :day), batch_size, 0)

  defp purge_unconfirmed(cutoff, batch_size, removed) do
    ids =
      from s in Subscriber,
        as: :subscriber,
        where: s.status == :pending,
        where:
          not exists(
            from t in SubscriberToken,
              where:
                t.subscriber_id == parent_as(:subscriber).id and t.context == "confirm" and
                  t.inserted_at > ^cutoff
          ),
        select: s.id,
        limit: ^batch_size

    case Subscriber |> where([s], s.id in subquery(ids)) |> Repo.delete_all() do
      {count, _rows} when count < batch_size -> removed + count
      {count, _rows} -> purge_unconfirmed(cutoff, batch_size, removed + count)
    end
  end

  @doc "The subscriber with `email`, in any letter case, or `nil`."
  @spec get_subscriber_by_email(String.t()) :: Subscriber.t() | nil
  def get_subscriber_by_email(email) when is_binary(email) do
    trimmed = String.trim(email)

    Subscriber
    |> where([s], s.email == ^trimmed)
    |> Repo.one()
  end

  defp check_rate_limit(ip) do
    case RateLimit.check(:release_signup, ip: ip) do
      :ok -> :ok
      {:error, {:rate_limited, _retry_after_ms}} -> {:error, :rate_limited}
    end
  end

  defp validate(email, opts) do
    attrs = %{
      email: email,
      locale: opts |> Keyword.get(:locale) |> Locales.resolve(),
      consent_text: Keyword.get(opts, :consent_text),
      consented_at: DateTime.utc_now(:second)
    }

    case Subscriber.signup_changeset(%Subscriber{}, attrs) do
      %Ecto.Changeset{valid?: true} = changeset -> {:ok, changeset}
      changeset -> {:error, %{changeset | action: :insert}}
    end
  end

  # Runs a valid signup's store-and-email work off the request, the same way
  # for every address, so the response time cannot tell a new address from
  # one already on the list.
  defp in_background(fun) do
    if Application.get_env(:kanban, :async_email_delivery, true) do
      case Task.Supervisor.start_child(Kanban.TaskSupervisor, fun) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> Logger.error("release list signup dispatch failed")
      end
    else
      fun.()
    end

    :ok
  end

  # A validated changeset can only fail to insert on a database error, which
  # raises and is logged as the task's crash; the email conflict is handled
  # inside store/1.
  defp sign_up(changeset) do
    with {:ok, delivery} <- store(changeset), do: deliver(delivery)
  end

  # One INSERT ... ON CONFLICT DO NOTHING for every address, so a new and an
  # existing address take the same first step. Returns what to email, or
  # :none.
  defp store(changeset) do
    Repo.transact(fn ->
      case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :email) do
        {:ok, %Subscriber{id: nil}} -> {:ok, existing(changeset)}
        {:ok, subscriber} -> {:ok, issue_confirmation(subscriber)}
        {:error, changeset} -> {:error, changeset}
      end
    end)
  end

  defp existing(changeset) do
    email = Ecto.Changeset.get_field(changeset, :email)

    subscriber =
      Subscriber
      |> where([s], s.email == ^email)
      |> lock("FOR UPDATE")
      |> Repo.one()

    if renewable?(subscriber), do: renew(subscriber, changeset), else: :none
  end

  # Only a pending subscriber whose confirmation link has expired is sent a
  # new one; otherwise a stale signup could never be confirmed.
  defp renewable?(%Subscriber{status: :pending} = subscriber) do
    live =
      from t in SubscriberToken.by_subscriber_query(subscriber, "confirm"),
        where: t.inserted_at > ago(@confirm_days, "day")

    not Repo.exists?(live)
  end

  defp renewable?(_subscriber), do: false

  defp renew(subscriber, changeset) do
    subscriber
    |> SubscriberToken.by_subscriber_query("confirm")
    |> Repo.delete_all()

    subscriber
    |> Subscriber.renew_changeset(
      Map.take(changeset.changes, [:locale, :consent_text, :consented_at])
    )
    |> Repo.update!()
    |> issue_confirmation()
  end

  defp issue_confirmation(subscriber) do
    {subscriber, issue(subscriber, "confirm"), issue_unsubscribe_token(subscriber)}
  end

  defp issue(subscriber, context) do
    {token, row} = SubscriberToken.build(subscriber, context)
    Repo.insert!(row)
    token
  end

  defp deliver(:none), do: :ok

  defp deliver({subscriber, confirm_token, unsubscribe_token}),
    do: Notifier.deliver_confirmation(subscriber, confirm_token, unsubscribe_token)

  # The live token's subscriber, locked FOR UPDATE and read again after the
  # lock, or nil once the token is unknown or expired or the subscriber is
  # gone. Both writers take this lock before any other, so they never wait
  # on each other in opposite orders.
  defp lock_subscriber(token, context, days) do
    case fetch_token(token, context, days) do
      %SubscriberToken{subscriber_id: id} ->
        Subscriber
        |> where([s], s.id == ^id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      nil ->
        nil
    end
  end

  defp activate(token) do
    with %Subscriber{} = subscriber <- lock_subscriber(token, "confirm", @confirm_days),
         {used, _} when used > 0 <- delete_confirm_tokens(subscriber) do
      subscriber
      |> Subscriber.confirm_changeset(DateTime.utc_now(:second))
      |> Repo.update()
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp remove(token) do
    case lock_subscriber(token, "unsubscribe", @unsubscribe_days) do
      %Subscriber{id: id} ->
        Subscriber
        |> where([s], s.id == ^id)
        |> Repo.delete_all()

        {:ok, :deleted}

      nil ->
        {:error, :invalid}
    end
  end

  defp delete_confirm_tokens(subscriber) do
    subscriber
    |> SubscriberToken.by_subscriber_query("confirm")
    |> Repo.delete_all()
  end

  defp fetch_token(token, context, days) do
    case SubscriberToken.verify_query(token, context, days) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end
end
