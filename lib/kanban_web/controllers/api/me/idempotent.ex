defmodule KanbanWeb.API.Me.Idempotent do
  @moduledoc """
  The `Idempotency-Key` header of the app's review decisions (W2755,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.5):
  `POST /api/me/reviews/:task_id/approve` and `.../request_changes`.

  A request may send one `Idempotency-Key` of 1 to 255 visible ASCII
  characters, such as a UUID. A retry with the same key from the same device,
  for the same decision on the same task, within 24 hours, is answered with
  the first request's status and body instead of being run again, so a
  response lost on the way back never turns into a 409. Only a successful
  result is stored: a refused request stores nothing, and its retry runs
  again. A request without the header runs as it always did.

  The key is bound to the request it was sent with: the `review_requested_at`
  and a hash of the `signature` of an approval, and the `review_requested_at`
  and `notes` of a request for changes. The same key sent with others is a
  new request, so new notes are never answered with the first request's 200
  while being dropped, and an approval resent with other signature bytes (a
  bad signature, a high-s twin of the first, or none) runs as a new request
  and is refused, never answered with the first request's 200 unchecked
  (W2923, design doc §24 decision 18). Only the signature's SHA-256 enters the
  binding, and the binding itself is hashed again before it is stored. A
  replay answers the first result as it was: it does not check that the
  review is still current. Before a stored result is replayed, the person's access to the task and their plan
  are checked again (`Kanban.Reviews.DecisionChecks.replayable/2`), so a
  person removed from the board or downgraded since is refused rather than
  answered from the store.

  An empty, malformed or repeated header is `400 Bad Request`. The key is
  read here and handed to `Kanban.Devices.Nonces`, which keeps only its hash;
  it is never logged, stored or put in telemetry metadata.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.IdempotencyKey
  alias Kanban.Devices.Nonce
  alias Kanban.Devices.Nonces

  @header "idempotency-key"
  @typep render :: (term() -> map())
  @typep decide :: (IdempotencyKey.t() | nil -> {:ok, term()} | {:error, term()})
  @typep replayable :: (-> :ok | {:error, term()})

  # The body fields each decision's key is bound to. A `{:hashed, field}`
  # field is bound by the SHA-256 of its string value, so the approval
  # signature never enters the binding as sent.
  @bound_fields %{
    approve: ["review_requested_at", {:hashed, "signature"}],
    request_changes: ["review_requested_at", "notes"]
  }

  @bad_key_message "Idempotency-Key must be sent at most once, as 1 to 255 visible ASCII characters, such as a UUID."

  @doc "The 400 message for an unacceptable `Idempotency-Key`."
  @spec bad_key_message() :: String.t()
  def bad_key_message, do: @bad_key_message

  @doc """
  The request's idempotency key for `action` on task `task_id`:
  `{:ok, nil}` when the header is absent, `{:ok, key}` for one acceptable
  header, or `{:error, {:bad_request, message}}`. `render` turns the decided
  task into the response body.
  """
  @spec key(Plug.Conn.t(), Device.t(), Nonces.action(), integer(), render()) ::
          {:ok, IdempotencyKey.t() | nil} | {:error, {:bad_request, String.t()}}
  def key(%Plug.Conn{} = conn, %Device{} = device, action, task_id, render) do
    case get_req_header(conn, @header) do
      [] ->
        {:ok, nil}

      [value] ->
        if Nonces.valid_key?(value),
          do:
            {:ok,
             Nonces.idempotency_key(device, action, task_id, value, render, bound(conn, action))},
          else: bad_key()

      _repeated ->
        bad_key()
    end
  end

  @doc """
  Runs `decide`, given the key, and answers its result: `{:ok, task}` is 200
  with the body `key.render` makes of it (or `render` when no key was sent),
  and a stored result is replayed once `replayable` returns `:ok` (its error
  is returned instead). With a key, a stored result is looked up before
  `decide` runs, and again when `decide` fails, since a parallel request with
  the same key may have succeeded meanwhile; every other refusal is returned
  for the fallback controller.
  """
  @spec run(Plug.Conn.t(), IdempotencyKey.t() | nil, render(), decide(), replayable()) ::
          Plug.Conn.t() | {:error, term()}
  def run(%Plug.Conn{} = conn, nil, render, decide, _replayable) do
    with {:ok, task} <- decide.(nil), do: json(conn, render.(task))
  end

  def run(%Plug.Conn{} = conn, %IdempotencyKey{} = key, _render, decide, replayable) do
    case Nonces.find_replay(key) do
      {:ok, nonce} -> replay(conn, nonce, replayable)
      :none -> decide_once(conn, key, decide, replayable)
    end
  end

  defp decide_once(conn, key, decide, replayable) do
    case decide.(key) do
      {:ok, task} -> json(conn, key.render.(task))
      {:error, {:replay, %Nonce{} = nonce}} -> replay(conn, nonce, replayable)
      {:error, :revoked} = revoked -> revoked
      {:error, _reason} = refused -> replay_or(conn, key, refused, replayable)
    end
  end

  defp replay_or(conn, key, refused, replayable) do
    case Nonces.find_replay(key) do
      {:ok, nonce} -> replay(conn, nonce, replayable)
      :none -> refused
    end
  end

  defp replay(conn, %Nonce{response_status: status, response_body: body}, replayable) do
    with :ok <- replayable.() do
      conn
      |> put_status(status)
      |> json(body)
    end
  end

  defp bound(%Plug.Conn{body_params: params}, action) do
    @bound_fields
    |> Map.fetch!(action)
    |> Enum.map(&bound_field(params, &1))
    |> Jason.encode!()
  end

  defp bound_field(params, {:hashed, field}), do: params |> Map.get(field) |> hashed_value()
  defp bound_field(params, field), do: params |> Map.get(field) |> bound_value()

  # A string is bound by its hash alone, so its bytes decide the binding
  # without being kept in it. Any other value (nil when the field is missing,
  # or a value the decision refuses anyway) is bound as `bound_value/1` binds
  # it, under another name, so no value sent can bind as a hash does.
  defp hashed_value(value) when is_binary(value),
    do: %{"sha256" => DeviceToken.hash_token(value)}

  defp hashed_value(value), do: %{"as_sent" => bound_value(value)}

  # What a bound field contributes to the key's hash. A value a JSON or form
  # body can carry (a string, number, boolean, nil, or a map or list of them)
  # is bound as sent. A struct, such as the `%Plug.Upload{}` of a multipart
  # file part, cannot be encoded, so it is bound by its kind alone: neither
  # decision accepts anything but a string there, so the request is refused
  # with the same 422 as without a key, and nothing is ever stored under it.
  defp bound_value(%module{}), do: %{"unencodable" => inspect(module)}

  defp bound_value(map) when is_map(map),
    do: Map.new(map, fn {field, value} -> {field, bound_value(value)} end)

  defp bound_value(list) when is_list(list), do: Enum.map(list, &bound_value/1)
  defp bound_value(value), do: value

  defp bad_key, do: {:error, {:bad_request, @bad_key_message}}
end
