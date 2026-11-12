defmodule Kanban.AuditLog.SignedExport.Slots do
  @moduledoc """
  Caps how many signed audit exports read their snapshot at once.

  Each signed build holds one pool connection, and one snapshot that holds
  back VACUUM, for the whole read (`Kanban.AuditLog.SignedExport.Snapshot`).
  The export rate limit is per org-admin, so a burst of exports by several
  org-admins could otherwise take every pool connection at once and make
  every other tenant's requests wait. This server hands out a fixed number
  of slots, 2 by default, well below the pool size.

  A build that finds every slot taken waits for one, up to 30 seconds by
  default. It waits without a connection: the slot is taken before the
  transaction starts. A build still waiting when that time is up gets
  `{:error, :busy}`, and the signed export then fails as any failed build
  does.

  A slot is given back when the function returns, raises, throws or exits,
  and when the process holding it dies, because the server monitors every
  holder and every waiter.

  `config :kanban, #{inspect(__MODULE__)}, slots: n, wait: ms` overrides the
  two defaults.
  """

  use GenServer

  @default_slots 2
  @default_wait :timer.seconds(30)

  @doc """
  Starts the server. `opts`: `:name` (default `#{inspect(__MODULE__)}`; `nil`
  starts it unnamed), `:slots` and `:wait`, which override the application
  config.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Runs `fun` in a slot of `server` and returns `{:ok, result}`, or
  `{:error, :busy}` without running it when no slot came free in time.
  """
  @spec with_slot(GenServer.server(), (-> result)) :: {:ok, result} | {:error, :busy}
        when result: var
  def with_slot(server \\ __MODULE__, fun) when is_function(fun, 0) do
    case GenServer.call(server, :checkout, :infinity) do
      {:ok, ref} ->
        try do
          {:ok, fun.()}
        after
          GenServer.cast(server, {:checkin, ref})
        end

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  @impl true
  def init(opts) do
    config = :kanban |> Application.get_env(__MODULE__, []) |> Keyword.merge(opts)

    {:ok,
     %{
       slots: Keyword.get(config, :slots, @default_slots),
       wait: Keyword.get(config, :wait, @default_wait),
       active: MapSet.new(),
       waiting: :queue.new(),
       timers: %{}
     }}
  end

  # A waiter is monitored from the moment it asks, and the same monitor ref
  # becomes its slot's id once it is granted one.
  @impl true
  def handle_call(:checkout, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)

    if MapSet.size(state.active) < state.slots do
      {:reply, {:ok, ref}, %{state | active: MapSet.put(state.active, ref)}}
    else
      timer = Process.send_after(self(), {:expire, ref}, state.wait)

      {:noreply,
       %{
         state
         | waiting: :queue.in({ref, from}, state.waiting),
           timers: Map.put(state.timers, ref, timer)
       }}
    end
  end

  @impl true
  def handle_cast({:checkin, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, release(state, ref)}
  end

  @impl true
  def handle_info({:expire, ref}, state) do
    case take_waiter(state, ref) do
      {{^ref, from}, state} ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, {:error, :busy})
        {:noreply, state}

      :none ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case take_waiter(state, ref) do
      {_waiter, state} -> {:noreply, state}
      :none -> {:noreply, release(state, ref)}
    end
  end

  defp release(state, ref) do
    if MapSet.member?(state.active, ref) do
      grant_next(%{state | active: MapSet.delete(state.active, ref)})
    else
      state
    end
  end

  defp grant_next(state) do
    case :queue.out(state.waiting) do
      {{:value, {ref, from}}, waiting} ->
        {timer, timers} = Map.pop(state.timers, ref)
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, ref})
        %{state | waiting: waiting, timers: timers, active: MapSet.put(state.active, ref)}

      {:empty, _waiting} ->
        state
    end
  end

  defp take_waiter(state, ref) do
    case Map.pop(state.timers, ref) do
      {nil, _timers} ->
        :none

      {timer, timers} ->
        Process.cancel_timer(timer)

        {[waiter], rest} =
          state.waiting |> :queue.to_list() |> Enum.split_with(&(elem(&1, 0) == ref))

        {waiter, %{state | waiting: :queue.from_list(rest), timers: timers}}
    end
  end
end
