defmodule Kanban.PlansHelpers do
  @moduledoc """
  Turns paid-plan enforcement on for a single test.

      use Kanban.DataCase, async: false
      import Kanban.PlansHelpers

      test "a free board is locked" do
        enforce_plans()
        refute Kanban.Plans.board_unlocked?(board)
      end

  Or for every test in a module or describe block:

      setup :enforce_plans

  `enforce_plans/0` sets the `:plans_enforced` application env to `true` and
  registers an `on_exit` callback that restores the value it found, or deletes
  the key again when it was not set.

  **Modules using this helper must be `async: false`.** Application env is
  global to the VM, so an async test running at the same time would see
  enforcement switched on.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Switches enforcement on until the current test exits.

  The one-argument form takes the test context so it can be used as
  `setup :enforce_plans`; it returns `:ok`.
  """
  @spec enforce_plans() :: :ok
  def enforce_plans do
    previous = Application.fetch_env(:kanban, :plans_enforced)
    on_exit(fn -> restore_plans_enforced(previous) end)
    Application.put_env(:kanban, :plans_enforced, true)
  end

  @spec enforce_plans(map()) :: :ok
  def enforce_plans(_context), do: enforce_plans()

  @doc """
  Restores the `:plans_enforced` value captured by `Application.fetch_env/2`:
  puts it back when it was `{:ok, value}`, deletes the key when it was `:error`.
  """
  @spec restore_plans_enforced({:ok, term()} | :error) :: :ok
  def restore_plans_enforced({:ok, value}),
    do: Application.put_env(:kanban, :plans_enforced, value)

  def restore_plans_enforced(:error), do: Application.delete_env(:kanban, :plans_enforced)
end
