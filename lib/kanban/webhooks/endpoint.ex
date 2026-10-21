defmodule Kanban.Webhooks.Endpoint do
  @moduledoc """
  A board's outbound webhook endpoint (W2226): a generic receiver of signed
  JSON, a Slack incoming webhook, or a Discord webhook (W2367).

  The signing secret is stored only as `SecretBox` ciphertext in
  `encrypted_secret`, and the URL is stored encrypted too, through
  `Kanban.Integrations.EncryptedString`, because a Slack incoming-webhook URL
  or a Discord webhook URL (which embeds the webhook's token) is a
  credential: whoever holds it can post to the channel. Both are
  redacted from `inspect/1`. The virtual `secret` field carries the plaintext on the
  struct returned by a create or a rotation, so it can be shown once; a
  struct loaded from the database never has it. `board_id`, `created_by_id`,
  `disabled_reason` and the secret are set by `Kanban.Webhooks`, never cast
  from params.

  `disabled_reason` says why Stride switched an endpoint off by itself
  (`:creator_lost_access`). It is `nil` while the endpoint is enabled and
  when the owner switched it off, and any change to `enabled` clears it.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [join: 5, where: 3]

  alias Kanban.Integrations.EncryptedString
  alias Kanban.Integrations.SecretBox
  alias Kanban.Webhooks.UrlGuard

  @event_types ~w(
    task.created
    task.updated
    task.moved
    task.claimed
    task.unclaimed
    task.completed
    task.moved_to_review
    task.reviewed
    task.deleted
  )

  @kinds [:generic, :slack, :discord]

  @disabled_reasons [:creator_lost_access]

  @slack_url_message "must be a Slack incoming webhook URL starting with https://hooks.slack.com/"

  @discord_url_message "must be a Discord webhook URL, for example https://discord.com/api/webhooks/…"

  # Exact host names Discord serves webhooks from (ptb. and canary. are the
  # URLs its test clients copy). Compared whole, never as a suffix.
  @discord_hosts ~w(discord.com discordapp.com ptb.discord.com canary.discord.com)

  schema "webhook_endpoints" do
    field :kind, Ecto.Enum, values: @kinds, default: :generic
    field :url, EncryptedString, redact: true
    field :encrypted_secret, :binary, redact: true
    field :secret, :string, virtual: true, redact: true
    field :event_types, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :disabled_reason, Ecto.Enum, values: @disabled_reasons
    field :lock_version, :integer, default: 1

    belongs_to :board, Kanban.Boards.Board
    belongs_to :created_by, Kanban.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The event names an endpoint can subscribe to."
  def event_types, do: @event_types

  @doc "The endpoint kinds."
  def kinds, do: @kinds

  @doc """
  Narrows `queryable` to the endpoints that may send now: enabled, and not
  created by a disabled account. An endpoint whose creator was deleted has
  no creator and may send. `Kanban.Webhooks.Events` and
  `Kanban.Webhooks.DeliveryWorker` both read through it, so a disabled
  creator's endpoints send nothing and resume when the account is enabled
  again (decided 2026-10-21).
  """
  @spec sendable(Ecto.Queryable.t()) :: Ecto.Query.t()
  def sendable(queryable \\ __MODULE__) do
    queryable
    |> join(:left, [e], c in assoc(e, :created_by), as: :creator)
    |> where([e, creator: c], e.enabled and is_nil(c.disabled_at))
  end

  @doc """
  Casts the owner-editable fields: `kind`, `url`, `event_types` and
  `enabled`. The URL gets `UrlGuard.validate_syntax/2` (no DNS); `opts` is
  passed through to it. At least one known event type is required, a
  `:slack` endpoint's URL must be a Slack incoming webhook (`slack_url?/1`),
  and a `:discord` endpoint's URL must be a Discord webhook
  (`discord_url?/1`).
  """
  def changeset(endpoint, attrs, opts \\ []) do
    endpoint
    |> cast(attrs, [:kind, :url, :event_types, :enabled])
    |> validate_required([:kind, :url, :enabled])
    |> clear_disabled_reason()
    |> validate_length(:url, max: 2048)
    |> update_change(:event_types, &Enum.uniq/1)
    |> validate_some_event_types()
    |> validate_subset(:event_types, @event_types)
    |> validate_url(opts)
    |> validate_kind_url()
  end

  @doc """
  Whether `url` is a Slack incoming-webhook URL: `https` on the default port
  to `hooks.slack.com`, with no username or password. Any path is allowed.
  """
  def slack_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, port: 443, userinfo: nil}} when is_binary(host) ->
        String.downcase(host) == "hooks.slack.com"

      _other ->
        false
    end
  end

  def slack_url?(_url), do: false

  @doc """
  Whether `url` is a Discord webhook URL: `https` on the default port, with
  no username or password, to `discord.com`, `discordapp.com`,
  `ptb.discord.com` or `canary.discord.com`, and a path of
  `/api/webhooks/{id}/{token}` or `/api/v{n}/webhooks/{id}/{token}` (a
  trailing slash and a query string such as `?wait=true` are allowed). Any
  other Discord API route is refused.
  """
  def discord_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, port: 443, userinfo: nil, path: path}}
      when is_binary(host) and is_binary(path) ->
        String.downcase(host) in @discord_hosts and discord_webhook_path?(path)

      _other ->
        false
    end
  end

  def discord_url?(_url), do: false

  defp discord_webhook_path?(path),
    do: Regex.match?(~r<\A/api(?:/v\d{1,3})?/webhooks/\d{1,20}/[A-Za-z0-9_-]+/?\z>, path)

  # The reason belongs to the switch-off it explains, so turning the endpoint
  # on, or off by hand, drops it.
  defp clear_disabled_reason(changeset) do
    if changed?(changeset, :enabled),
      do: put_change(changeset, :disabled_reason, nil),
      else: changeset
  end

  # Checked on the field, not the change: casting [] onto the default [] is
  # no change at all, so validate_length/3 would never see it.
  defp validate_some_event_types(changeset) do
    case get_field(changeset, :event_types) do
      [_ | _] ->
        changeset

      _none ->
        add_error(changeset, :event_types, "should have at least %{count} item(s)",
          count: 1,
          validation: :length,
          kind: :min,
          type: :list
        )
    end
  end

  # Checked on the fields, not the changes, so switching an endpoint's kind
  # to :slack or :discord while keeping a generic URL is refused too. A URL
  # that already has an error keeps only that one.
  defp validate_kind_url(changeset) do
    url = get_field(changeset, :url)

    case kind_url_rule(get_field(changeset, :kind)) do
      {valid?, message, validation} when is_binary(url) ->
        if is_nil(changeset.errors[:url]) and not valid?.(url),
          do: add_error(changeset, :url, message, validation: validation),
          else: changeset

      _no_rule ->
        changeset
    end
  end

  defp kind_url_rule(:slack), do: {&slack_url?/1, @slack_url_message, :slack_url}
  defp kind_url_rule(:discord), do: {&discord_url?/1, @discord_url_message, :discord_url}
  defp kind_url_rule(_kind), do: nil

  defp validate_url(changeset, opts) do
    validate_change(changeset, :url, fn :url, url ->
      case UrlGuard.validate_syntax(url, opts) do
        :ok -> []
        {:error, :too_long} -> []
        {:error, reason} -> [url: {UrlGuard.error_message(reason), reason: reason}]
      end
    end)
  end

  @doc """
  Generates a new signing secret, puts it on the virtual `secret` field and
  its ciphertext on `encrypted_secret`.
  """
  def put_new_secret(changeset) do
    secret = "whsec_" <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    changeset
    |> put_change(:secret, secret)
    |> put_change(:encrypted_secret, SecretBox.encrypt(secret))
  end
end
