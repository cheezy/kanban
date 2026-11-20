defmodule Kanban.Devices.Nonces do
  @moduledoc """
  The device nonce store (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md
  §7.5, §8): the first result of an app review decision sent with an
  `Idempotency-Key` header, kept for 24 hours so a retried request replays
  it instead of answering 409.

  ## How a key is stored

  `idempotency_key/6` hashes the key together with the action, the task it
  was sent for and the request it was sent with, and the row is scoped to
  the device, so:

    * the key itself is never stored, logged or compared in plain text;
    * the same key from another device is a different row;
    * the same key sent for another task, or for the other decision, is a
      different row, so it acts anew and never replays another task's result;
    * the same key sent with another request (other notes, or another
      `review_requested_at`) is a different row too, so it is never answered
      with the first request's result.

  A result is kept for at least 24 hours: the expiry is rounded up to the
  next whole second.

  ## Running the action once

  A decision calls `claim/2` as the first statement of its own commit
  transaction, and `record/2` with the decided task as the last, so a claim
  is only ever committed together with its result and a failed decision
  stores nothing. Two parallel requests with one key both insert into the
  unique index on `(device_id, kind, key_hash)`: the second waits until the
  first transaction ends, then finds the committed row and is told to replay
  it (`{:error, {:replay, nonce}}`), or, if the first rolled back, claims the
  key itself. A row whose 24 hours ran out is taken over by the next claim, so
  the same key after expiry acts anew.

  ## Socket tokens

  `use_socket_token/3` records the id of a socket token the app connected
  `/api/socket` with (§7.7), as a `:socket_token` row, so the same token can
  never connect twice. Only a hash of the id is stored, and the row expires
  just after the token itself would.

  `sweep_expired/2`, run hourly by `Kanban.Devices.NonceSweepWorker`, deletes
  expired rows of both kinds.
  """

  import Ecto.Query, warn: false

  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.IdempotencyKey
  alias Kanban.Devices.Nonce
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @ttl_seconds 86_400
  # A socket token is valid for 60 seconds (KanbanWeb.SocketToken); its used
  # id is kept one second longer, so it outlives the token.
  @socket_token_ttl_seconds 61
  @sweep_batch_size 1000
  @actions [:approve, :request_changes]
  @key_format ~r/\A[\x21-\x7E]{1,255}\z/

  @type action :: :approve | :request_changes

  @doc "How long a stored result is replayed, in seconds: #{@ttl_seconds}."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Whether `key` is an acceptable `Idempotency-Key`: 1 to 255 visible ASCII
  characters, such as a UUID.
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key), do: Regex.match?(@key_format, key)
  def valid_key?(_key), do: false

  @doc """
  The idempotency key `key` sent by `device` for `action` on task `task_id`,
  with `request`, the request fields the key is bound to, encoded. `render`
  turns the decided task into the JSON body the device is sent. Only a hash
  of the key, the action, the task and the request is kept.
  """
  @spec idempotency_key(
          Device.t(),
          action(),
          integer(),
          String.t(),
          (Task.t() -> map()),
          String.t()
        ) :: IdempotencyKey.t()
  def idempotency_key(%Device{id: device_id}, action, task_id, key, render, request \\ "")
      when action in @actions and is_integer(task_id) and is_binary(key) and
             is_function(render, 1) and is_binary(request) do
    request_hash = DeviceToken.hash_token(request)

    %IdempotencyKey{
      device_id: device_id,
      key_hash:
        DeviceToken.hash_token("idempotency:v1:#{action}:#{task_id}:#{request_hash}:#{key}"),
      render: render
    }
  end

  @doc """
  The stored result for `key`, unexpired at `now`: `{:ok, nonce}` with its
  `response_status` and `response_body`, or `:none`. `nil` (no key sent) is
  always `:none`.
  """
  @spec find_replay(IdempotencyKey.t() | nil, DateTime.t()) :: {:ok, Nonce.t()} | :none
  def find_replay(key, now \\ DateTime.utc_now())

  def find_replay(nil, _now), do: :none

  def find_replay(%IdempotencyKey{} = key, %DateTime{} = now) do
    at = DateTime.truncate(now, :second)

    key
    |> key_query()
    |> where([n], n.expires_at > ^at and not is_nil(n.response_status))
    |> Repo.one()
    |> case do
      %Nonce{} = nonce -> {:ok, nonce}
      nil -> :none
    end
  end

  @doc """
  Claims `key` at `now`, inside the decision's transaction, before anything
  else it does. Returns `:ok` for a new key or one whose 24 hours ran out, or
  `{:error, {:replay, nonce}}` when an unexpired result is stored for it. A
  parallel claim of the same key waits for this transaction to end. `nil`
  (no key sent) is always `:ok`.
  """
  @spec claim(IdempotencyKey.t() | nil, DateTime.t()) :: :ok | {:error, {:replay, Nonce.t()}}
  def claim(nil, _now), do: :ok

  def claim(%IdempotencyKey{} = key, %DateTime{} = now) do
    at = DateTime.truncate(now, :second)
    expires_at = now |> DateTime.add(@ttl_seconds, :second) |> ceil_second()

    row = %{
      device_id: key.device_id,
      kind: :idempotency,
      key_hash: key.key_hash,
      expires_at: expires_at,
      inserted_at: at
    }

    take_over_expired =
      from(n in Nonce,
        where: n.expires_at <= ^at,
        update: [
          set: [
            response_status: nil,
            response_body: nil,
            expires_at: ^expires_at,
            inserted_at: ^at
          ]
        ]
      )

    case Repo.insert_all(Nonce, [row],
           on_conflict: take_over_expired,
           conflict_target: [:device_id, :kind, :key_hash]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, {:replay, key |> key_query() |> Repo.one!()}}
    end
  end

  @doc """
  Stores `task`, the decided task, as the result of the claimed `key`: status
  200 and the body `key.render` makes of it, as JSON would send it. `nil` (no
  key sent) stores nothing. Call it in the transaction that claimed the key.
  """
  @spec record(IdempotencyKey.t() | nil, Task.t()) :: :ok
  def record(nil, _task), do: :ok

  def record(%IdempotencyKey{render: render} = key, %Task{} = task) do
    body = task |> render.() |> Jason.encode!() |> Jason.decode!()

    {1, _rows} =
      key
      |> key_query()
      |> Repo.update_all(set: [response_status: 200, response_body: body])

    :ok
  end

  @doc """
  Records that `device` connected its socket with the socket token whose id
  is `token_id`, at `now` (`KanbanWeb.SocketToken`, design §7.7). Returns
  `:ok` the first time and `{:error, :used}` for every later use of the same
  id by the same device.

  Only a hash of the id is stored. The row expires #{@socket_token_ttl_seconds}
  seconds after `now`, rounded up to the next whole second: at least as long
  as the token itself is valid, so the hourly sweep never deletes the record
  of a token that could still connect.

  It is one `INSERT … ON CONFLICT DO NOTHING` on the unique index of
  `(device_id, kind, key_hash)`, so two connects racing with one token both
  insert and exactly one of them wins: the second waits for the first to
  commit and then inserts nothing.
  """
  @spec use_socket_token(Device.t(), String.t(), DateTime.t()) :: :ok | {:error, :used}
  def use_socket_token(%Device{id: device_id}, token_id, %DateTime{} = now)
      when is_integer(device_id) and is_binary(token_id) do
    row = %{
      device_id: device_id,
      kind: :socket_token,
      key_hash: socket_token_hash(token_id),
      expires_at: now |> DateTime.add(@socket_token_ttl_seconds, :second) |> ceil_second(),
      inserted_at: DateTime.truncate(now, :second)
    }

    case Repo.insert_all(Nonce, [row],
           on_conflict: :nothing,
           conflict_target: [:device_id, :kind, :key_hash]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :used}
    end
  end

  @doc """
  The hash a socket token id is stored as by `use_socket_token/3`.
  """
  @spec socket_token_hash(String.t()) :: String.t()
  def socket_token_hash(token_id) when is_binary(token_id),
    do: DeviceToken.hash_token("socket_token:v1:" <> token_id)

  @doc """
  Deletes the nonces whose time ran out by `now`, `batch_size` rows per
  statement. Returns the number deleted.
  """
  @spec sweep_expired(DateTime.t(), pos_integer()) :: non_neg_integer()
  def sweep_expired(%DateTime{} = now, batch_size \\ @sweep_batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    sweep(DateTime.truncate(now, :second), batch_size, 0)
  end

  defp sweep(now, batch_size, removed) do
    ids = from(n in Nonce, where: n.expires_at <= ^now, select: n.id, limit: ^batch_size)

    # The outer expiry check is re-read on a row a parallel claim has just
    # taken over, so that row's fresh result is never deleted.
    case from(n in Nonce, where: n.id in subquery(ids) and n.expires_at <= ^now)
         |> Repo.delete_all() do
      {count, _rows} when count < batch_size -> removed + count
      {count, _rows} -> sweep(now, batch_size, removed + count)
    end
  end

  defp ceil_second(%DateTime{microsecond: {0, _precision}} = at),
    do: DateTime.truncate(at, :second)

  defp ceil_second(%DateTime{} = at),
    do: at |> DateTime.truncate(:second) |> DateTime.add(1, :second)

  defp key_query(%IdempotencyKey{device_id: device_id, key_hash: key_hash}) do
    from(n in Nonce,
      where: n.device_id == ^device_id and n.kind == :idempotency and n.key_hash == ^key_hash
    )
  end
end
