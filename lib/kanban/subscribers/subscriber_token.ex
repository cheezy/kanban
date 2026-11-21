defmodule Kanban.Subscribers.SubscriberToken do
  @moduledoc """
  A token emailed to a release-list subscriber, stored only as its SHA-256
  hash, following `Kanban.Accounts.UserToken`.

  The raw token is 32 random bytes, URL-safe base64 without padding, and only
  ever appears in the emailed link. The context is `"confirm"` (the
  double opt-in link) or `"unsubscribe"`. Expiry is measured from
  `inserted_at`, so a token has no stored lifetime to tamper with.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Kanban.Subscribers.Subscriber

  @hash_algorithm :sha256
  @rand_size 32
  @contexts ["confirm", "unsubscribe"]

  @type t :: %__MODULE__{}
  @type context :: String.t()

  schema "subscriber_tokens" do
    field :context, :string
    field :token_hash, :binary
    belongs_to :subscriber, Subscriber

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a token for `subscriber` in `context`: the encoded value to email,
  and the struct holding only its hash, ready to insert.
  """
  @spec build(Subscriber.t(), context()) :: {String.t(), t()}
  def build(%Subscriber{id: id}, context) when context in @contexts do
    raw = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(raw, padding: false),
     %__MODULE__{subscriber_id: id, context: context, token_hash: hash(raw)}}
  end

  @doc """
  Returns a query for the token row matching the emailed `token` in
  `context`, inserted within the last `days`, with its subscriber preloaded.
  Anything that is not a well-formed token is `:error`.
  """
  @spec verify_query(term(), context(), pos_integer()) :: {:ok, Ecto.Query.t()} | :error
  def verify_query(token, context, days)
      when is_binary(token) and context in @contexts and is_integer(days) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} when byte_size(raw) == @rand_size ->
        query =
          from t in __MODULE__,
            join: s in assoc(t, :subscriber),
            where: t.context == ^context and t.token_hash == ^hash(raw),
            where: t.inserted_at > ago(^days, "day"),
            preload: [subscriber: s]

        {:ok, query}

      _invalid ->
        :error
    end
  end

  def verify_query(_token, _context, _days), do: :error

  @doc "Every token of `subscriber` in `context`."
  @spec by_subscriber_query(Subscriber.t(), context()) :: Ecto.Query.t()
  def by_subscriber_query(%Subscriber{id: id}, context) do
    from t in __MODULE__, where: t.subscriber_id == ^id and t.context == ^context
  end

  defp hash(raw), do: :crypto.hash(@hash_algorithm, raw)
end
