defmodule KanbanWeb.MeChannel do
  @moduledoc """
  What the app's two live channels share (`KanbanWeb.InboxChannel` on
  `me:inbox`, `KanbanWeb.AgentsChannel` on `me:agents`,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7): the join gate, the
  per-board subscriptions, the one-per-second rebuild and the push that
  sends nothing when nothing changed. docs/api/me_channels.md is the app's
  contract.

  ## Join

  `authorize_join/1` reads the socket's device again and checks that it is
  still signed in and its user still enabled
  (`Kanban.Devices.fetch_signed_in_device/1`), because a revoke that commits
  between `KanbanWeb.UserSocket.connect/3` and the socket's subscription to
  `"device:<id>"` is not seen by the socket, and then the `:mobile_app` plan
  on a freshly built scope (`Kanban.Plans.check_user/3` with
  `surface: :channel`, which emits `[:kanban, :plan, :feature_refused]` on a
  refusal). A refused join gets `%{reason: "unauthorized"}` or
  `%{reason: "plan_required"}`. An accepted join sends the channel
  `:after_join`, where it subscribes and pushes the full state, since a
  channel cannot push from `join/3`.

  Each rebuild runs the same checks first (`check_access/1`) and the channel
  stops when they fail, so a user disabled, or a person who left the
  Organization, while the app is open gets no further push, exactly as the
  REST routes would refuse them. Disabling a user does not revoke their
  devices, so this is what closes the gap for a live channel.

  ## Boards

  `sync_boards/2` subscribes the channel process to `"<prefix>:<id>"`, for
  each prefix the channel names, for every board
  `Kanban.Boards.list_app_board_ids/1` returns, the boards the person can
  access in any workspace that the plan unlocks, and unsubscribes
  from every board that is no longer among them. Each channel calls it on
  join and before every rebuild, so an access change that sends no
  notification (the person changed their own access, or turned the in-app
  notice off) is still picked up by the next rebuild. A subscription that is
  briefly stale can only cause an extra rebuild, never a leak: every push is
  rebuilt from the context for the person, and never forwards a broadcast.

  ## Pushes

  `push_changed/3` pushes the full state under `event` only when it differs
  from the last state this channel pushed. The first push after a join always
  goes out, so a reconnecting app gets the full state and never merges
  events.
  """

  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Kanban.Boards
  alias Kanban.Devices
  alias Kanban.Plans
  alias KanbanWeb.Coalescer
  alias KanbanWeb.Plugs.AuthenticateDeviceToken
  alias Phoenix.Socket

  @doc """
  The join gate described in the moduledoc. Returns `{:ok, socket}` with the
  channel's state assigned and `:after_join` sent to the caller, or
  `{:error, %{reason: reason}}`.
  """
  @spec authorize_join(Socket.t()) :: {:ok, Socket.t()} | {:error, %{reason: String.t()}}
  def authorize_join(%Socket{assigns: %{current_device: %{}}} = socket) do
    with {:ok, socket} <- check_access(socket) do
      send(self(), :after_join)

      {:ok,
       socket
       |> assign(:coalescer, Coalescer.new())
       |> assign(:board_ids, MapSet.new())
       |> assign(:last_payload, nil)}
    end
  end

  def authorize_join(%Socket{}), do: {:error, %{reason: "unauthorized"}}

  @doc """
  Runs the join gate again before a rebuild, on a freshly read device, user
  and Organization membership, so a device revoked, a user disabled or a
  person whose plan no longer includes the app after the join gets no
  further push. Returns `{:ok, socket}` with the fresh scope and device
  assigned, or `{:error, %{reason: reason}}`, on which the channel stops.
  """
  @spec check_access(Socket.t()) :: {:ok, Socket.t()} | {:error, %{reason: String.t()}}
  def check_access(%Socket{assigns: %{current_device: %{id: id, user_id: user_id}}} = socket) do
    with {:ok, device} <- signed_in_device(id, user_id),
         scope = AuthenticateDeviceToken.scope_for(device.user),
         :ok <- check_plan(scope) do
      {:ok, socket |> assign(:current_scope, scope) |> assign(:current_device, device)}
    end
  end

  defp signed_in_device(id, user_id) do
    case Devices.fetch_signed_in_device(id) do
      {:ok, %{user_id: ^user_id} = device} -> {:ok, device}
      _revoked_or_disabled -> {:error, %{reason: "unauthorized"}}
    end
  end

  defp check_plan(scope) do
    case Plans.check_user(scope, :mobile_app, surface: :channel) do
      :ok -> :ok
      {:error, {:plan_required, _feature}} -> {:error, %{reason: "plan_required"}}
    end
  end

  @doc """
  Brings the channel's board subscriptions on `"<prefix>:<id>"` in line with
  `Kanban.Boards.list_app_board_ids/1`, for one prefix or for each of a list
  of them, and stores the ids in `:board_ids`. A channel that needs more than
  one topic per board passes every prefix in one call, since the second of
  two calls would find `:board_ids` already current and subscribe nothing.
  """
  @spec sync_boards(Socket.t(), String.t() | [String.t()]) :: Socket.t()
  def sync_boards(%Socket{} = socket, prefix) when is_binary(prefix),
    do: sync_boards(socket, [prefix])

  def sync_boards(
        %Socket{assigns: %{current_scope: scope, board_ids: current}} = socket,
        prefixes
      )
      when is_list(prefixes) do
    wanted = scope |> Boards.list_app_board_ids() |> MapSet.new()
    lost = MapSet.difference(current, wanted)
    gained = MapSet.difference(wanted, current)

    Enum.each(prefixes, fn prefix ->
      each_topic(lost, prefix, &Phoenix.PubSub.unsubscribe/2)
      each_topic(gained, prefix, &Phoenix.PubSub.subscribe/2)
    end)

    assign(socket, :board_ids, wanted)
  end

  defp each_topic(ids, prefix, fun),
    do: Enum.each(ids, &fun.(Kanban.PubSub, board_topic(prefix, &1)))

  defp board_topic(prefix, id), do: "#{prefix}:#{id}"

  @doc "Asks for a rebuild, coalesced to one per interval (`KanbanWeb.Coalescer`)."
  @spec request_rebuild(Socket.t()) :: Socket.t()
  def request_rebuild(%Socket{assigns: %{coalescer: coalescer}} = socket) do
    assign(socket, :coalescer, Coalescer.request(coalescer))
  end

  @doc "Marks the coalesced `:rebuild` as arrived, so the next change schedules again."
  @spec rebuild_arrived(Socket.t()) :: Socket.t()
  def rebuild_arrived(%Socket{assigns: %{coalescer: coalescer}} = socket) do
    assign(socket, :coalescer, Coalescer.fired(coalescer))
  end

  @doc """
  Pushes `payload` under `event` unless it equals the last payload this
  channel pushed, and remembers it.
  """
  @spec push_changed(Socket.t(), String.t(), map()) :: Socket.t()
  def push_changed(%Socket{assigns: %{last_payload: payload}} = socket, _event, payload),
    do: socket

  def push_changed(%Socket{} = socket, event, payload) do
    push(socket, event, payload)
    assign(socket, :last_payload, payload)
  end
end
