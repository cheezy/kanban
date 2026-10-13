defmodule Kanban.Telemetry.AfterCommit do
  @moduledoc """
  Holds telemetry events back until a database transaction has committed.

  A caller that runs a change inside its own transaction, as `Kanban.Reviews`
  does for an approval, wraps that transaction in `after_commit/1`. An emitter
  that passes its emit to `defer/2` while it runs is held back and emitted
  only once the transaction has returned `{:ok, _}`, so a handler never sees
  an event for a change that can still roll back, and a rolled-back change
  emits nothing.

  Outside `after_commit/1`, `defer/2` emits straight away, so the same
  emitter works unchanged on paths that run no transaction of their own.

  The queue lives in the calling process's dictionary, so one process never
  flushes or drops another's events. It holds the emit closures, which
  capture only the event's already-built metadata.

  Only the transaction `after_commit/1` wraps is waited for. When that
  transaction is itself nested inside an outer `Repo.transaction/1`, its
  `{:ok, _}` flushes the events even though the outer transaction can still
  roll back; no caller does that today.
  """

  @held_key {__MODULE__, :held}

  @doc """
  Runs `fun`, a function that runs a database transaction and returns its
  result, and holds back every emit passed to `defer/2` while it runs. They
  are emitted once `fun` has returned `{:ok, _}`, and dropped when it returns
  anything else or raises. Returns `fun`'s result unchanged.

  Emits deferred with `:first` are emitted before those deferred with
  `:last`; within each group they keep the order they were deferred in.

  When it runs inside another `after_commit/1`, the flushed emits join the
  enclosing queue instead of being emitted, so they wait for the outer
  commit too.
  """
  @spec after_commit((-> result)) :: result when result: term()
  def after_commit(fun) when is_function(fun, 0) do
    previous = Process.put(@held_key, [])

    {result, held} =
      try do
        result = fun.()
        {result, Process.get(@held_key, [])}
      after
        restore_held(previous)
      end

    if match?({:ok, _}, result), do: flush(held)
    result
  end

  @doc """
  Runs `emit`, a zero-arity function that emits one event, straight away, or
  holds it back while `after_commit/1` is running in this process. Returns
  `:ok`.

  `position` only matters while holding: `:first` emits it ahead of every
  event deferred with `:last` (the default) when the transaction commits, for
  an event the others follow from, such as the task completion an approval's
  goal events report on.
  """
  @spec defer((-> term()), :first | :last) :: :ok
  def defer(emit, position \\ :last)
      when is_function(emit, 0) and position in [:first, :last] do
    case Process.get(@held_key) do
      held when is_list(held) -> Process.put(@held_key, [{position, emit} | held])
      _not_holding -> emit.()
    end

    :ok
  end

  @doc """
  Returns `true` while `after_commit/1` is running in this process.
  """
  @spec holding?() :: boolean()
  def holding?, do: is_list(Process.get(@held_key))

  # `held` is newest first. The sort is stable, so each group keeps the order
  # it was deferred in. Each emit goes back through defer/2, so a nested
  # after_commit/1 hands its emits, with their positions, to the enclosing one.
  defp flush(held) do
    held
    |> Enum.reverse()
    |> Enum.sort_by(fn {position, _emit} -> position == :last end)
    |> Enum.each(fn {position, emit} -> defer(emit, position) end)
  end

  defp restore_held(nil), do: Process.delete(@held_key)
  defp restore_held(previous), do: Process.put(@held_key, previous)
end
