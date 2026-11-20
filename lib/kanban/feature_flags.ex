defmodule Kanban.FeatureFlags do
  @moduledoc """
  Feature flags. **This module is the only place that calls `FunWithFlags`.**
  Every screen, controller, context or job that hides unreleased work asks
  here. Apart from this module and its `FunWithFlags.Actor` implementation in
  `lib/kanban/feature_flags/user_actor.ex`, the only mention of the library in
  `lib/` is `FunWithFlags.Supervisor` in `Kanban.Application`.
  `test/kanban/feature_flags_test.exs` scans `lib/` and fails otherwise.

  ## Storage

  Flags are stored by the fun_with_flags library in the
  `fun_with_flags_toggles` table through `Kanban.Repo`, so a change needs no
  deploy and survives a restart. Each node keeps an ETS cache of the flags it
  has read; every change is broadcast on `Kanban.PubSub`, and each node drops
  its copy and reloads it from the database. `config/config.exs` holds that
  setup; `config/test.exs` turns the cache off so a test only ever sees its
  own sandboxed toggles.

  ## Adding a flag

  Add the atom to `@flags` below. That list is the whole registry: every
  function here raises `ArgumentError` for a flag that is not in it, so a
  misspelt flag fails the test suite instead of quietly reading `false`.
  Names come only from this compiled list, never from `String.to_atom/1` on
  request input. A flag with no stored gates is off for everyone.

  `:mobile_app_preview` hides the screens that only make sense once the
  native apps ship (goal G532). It is deliberately not `:mobile_app`, which
  is the paid plan feature in `Kanban.Plans`.

  ## Gates

    * A **user gate** turns a flag on for one user. `enable_for_user/2` writes
      it and `disable_for_user/2` removes it, so after removal the user simply
      follows the everyone gate again; nothing ever stores a user as forced
      off.
    * The **everyone gate** turns a flag on for every user, and for callers
      with no signed-in user. `disable_for_everyone/1` turns it off and leaves
      the user gates in place.

  `enabled?/2` takes the scope first, like the context modules. A `nil` scope,
  or one with no user, sees only the everyone gate.

  `state/1` reports what is stored: `:everyone` when the everyone gate is on
  (whatever user gates remain), `{:users, ids}` when only user gates are on,
  and `:off` otherwise. The ids come from the stored gates, so a deleted
  account whose gate remains is still listed.

  A user's gate is identified as `"user:<id>"` (the `FunWithFlags.Actor`
  implementation in `lib/kanban/feature_flags/user_actor.ex`).
  No email address or other personal data reaches the table.

  ## Keeping the user id out of logs and errors

  The library logs every write at `:debug` with the gate, and so the
  `"user:<id>"` target, in the line; `quiet_library_log/0`, called at boot,
  raises that module's level to `:info` so the line is never written, and
  `Kanban.Repo.QueryLogger` logs the gate's target as `"**redacted**"` in the
  query log. The library's
  `[:fun_with_flags, :persistence, ...]` telemetry events carry the same
  gate, so no handler may attach to them and they must never be added to
  `Kanban.Telemetry.Catalog` (`docs/telemetry.md`, "Privacy rule"). A
  failed write returns `{:error, :store_failed}`, never the store's own
  error, which can quote the gate.
  """

  alias FunWithFlags.Flag
  alias FunWithFlags.Gate
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User

  @flags [:mobile_app_preview]

  @type flag :: :mobile_app_preview
  @type state :: :off | :everyone | {:users, [pos_integer()]}

  @doc """
  Stops the library's `:debug` telemetry log line, which quotes the user
  gate. `Kanban.Application` calls it at boot.
  """
  @spec quiet_library_log() :: :ok
  def quiet_library_log, do: Logger.put_module_level(FunWithFlags.Telemetry, :info)

  @doc "Every registered flag."
  @spec flags() :: [flag()]
  def flags, do: @flags

  @doc """
  Whether `flag` is on for the scope's user. A `nil` scope, or a scope with no
  user, sees only the everyone gate.
  """
  @spec enabled?(Scope.t() | nil, flag()) :: boolean()
  def enabled?(%Scope{user: %User{} = user}, flag),
    do: flag |> validate!() |> FunWithFlags.enabled?(for: user)

  def enabled?(nil, flag), do: flag |> validate!() |> FunWithFlags.enabled?()
  def enabled?(%Scope{user: nil}, flag), do: flag |> validate!() |> FunWithFlags.enabled?()

  @doc "Turns `flag` on for `user` only."
  @spec enable_for_user(flag(), User.t()) :: :ok | {:error, :store_failed}
  def enable_for_user(flag, %User{id: id} = user) when is_integer(id) do
    flag |> validate!() |> FunWithFlags.enable(for_actor: user) |> store_result()
  end

  @doc """
  Removes `user`'s gate for `flag`. The user then follows the everyone gate,
  and every other user's gate is untouched.
  """
  @spec disable_for_user(flag(), User.t()) :: :ok | {:error, :store_failed}
  def disable_for_user(flag, %User{id: id} = user) when is_integer(id) do
    # clear/2, not disable/2: disable would store the user as forced off, which
    # would then override the everyone gate for them.
    flag |> validate!() |> FunWithFlags.clear(for_actor: user) |> store_result()
  end

  @doc "Turns `flag` on for every user and for callers with no user."
  @spec enable_for_everyone(flag()) :: :ok | {:error, :store_failed}
  def enable_for_everyone(flag) do
    flag |> validate!() |> FunWithFlags.enable() |> store_result()
  end

  @doc "Turns the everyone gate for `flag` off. User gates stay as they are."
  @spec disable_for_everyone(flag()) :: :ok | {:error, :store_failed}
  def disable_for_everyone(flag) do
    flag |> validate!() |> FunWithFlags.disable() |> store_result()
  end

  @doc """
  What is stored for `flag`: `:everyone`, `{:users, ids}` with the ids sorted,
  or `:off`. A store error raises, as a failed `Kanban.Repo` call would.
  """
  @spec state(flag()) :: state()
  def state(flag) do
    case flag |> validate!() |> FunWithFlags.get_flag() do
      nil -> :off
      %Flag{gates: gates} -> state_from_gates(gates)
    end
  end

  defp state_from_gates(gates) do
    if Enum.any?(gates, &match?(%Gate{type: :boolean, enabled: true}, &1)) do
      :everyone
    else
      gates |> enabled_user_ids() |> users_or_off()
    end
  end

  defp enabled_user_ids(gates) do
    ids =
      for %Gate{type: :actor, enabled: true, for: "user:" <> id} <- gates,
          {id, ""} <- [Integer.parse(id)],
          do: id

    Enum.sort(ids)
  end

  defp users_or_off([]), do: :off
  defp users_or_off(ids), do: {:users, ids}

  # The store's own error can quote the gate, and so the user id; callers get
  # only that the write failed.
  defp store_result(:ok), do: :ok
  defp store_result({:ok, _enabled}), do: :ok
  defp store_result({:error, _reason}), do: {:error, :store_failed}

  defp validate!(flag) when flag in @flags, do: flag

  defp validate!(flag) do
    raise ArgumentError,
          "unknown feature flag #{describe(flag)}, expected one of #{inspect(@flags)}"
  end

  # Only atoms are echoed into the message. Any other value may have come from
  # a request, so it is described by its kind rather than its content.
  defp describe(value) when is_atom(value), do: inspect(value)
  defp describe(value) when is_binary(value), do: "(a string)"
  defp describe(_value), do: "(a non-atom value)"
end
