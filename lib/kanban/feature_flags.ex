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

  ## The admin page

  `/admin/feature-flags` (`KanbanWeb.Admin.FeatureFlagLive.Index`) reads a
  flag through `overview/1` and changes it only through the four `turn_*`
  functions. Each takes the acting site admin's scope first, refuses anyone
  else with `{:error, :unauthorized}`, and after a successful write records a
  `:feature_flag_enabled` or `:feature_flag_disabled` audit event (the actor's
  id, the flag name, the target user's id and the scope, never an email) and
  broadcasts `{:feature_flag_changed, flag}` on `topic/0`, so every open copy
  of the page refreshes. The `enable_*` and `disable_*` functions above are
  the unaudited primitives, for the console and for tests.
  `docs/feature-flags.md` describes the page.
  """

  alias FunWithFlags.Flag
  alias FunWithFlags.Gate
  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditLog

  @flags [:mobile_app_preview, :blog]
  @topic "feature_flags"

  # users.email accepts at most 160 characters (validate_length counts
  # characters, not bytes), so a value with more can match no account and is
  # refused before the lookup.
  @max_email_length 160

  # A hand-written gate could name any numeral; only ids a bigint column can
  # hold are ever passed on to a query.
  @max_bigint 9_223_372_036_854_775_807

  @type flag :: :mobile_app_preview | :blog
  @type state :: :off | :everyone | {:users, [pos_integer()]}
  @type overview :: %{
          flag: flag(),
          everyone?: boolean(),
          users: [User.t()],
          missing_user_ids: [pos_integer()]
        }
  @type change_error ::
          :unauthorized
          | :invalid_email
          | :user_not_found
          | :user_disabled
          | :already_enabled
          | :not_enabled
          | :store_failed

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
    gates = gates(flag)

    if everyone_gate?(gates) do
      :everyone
    else
      gates |> enabled_user_ids() |> users_or_off()
    end
  end

  @doc """
  Everything the admin page shows for `flag`, from one read of the store and
  one query: whether the everyone gate is on, the users with their own gate
  (disabled accounts included, ordered by email) whatever the everyone gate
  says, and the ids of gates whose account has been deleted.
  """
  @spec overview(flag()) :: overview()
  def overview(flag) do
    gates = gates(flag)
    ids = enabled_user_ids(gates)
    users = Accounts.list_users_by_ids(ids)
    found = MapSet.new(users, & &1.id)

    %{
      flag: flag,
      everyone?: everyone_gate?(gates),
      users: users,
      missing_user_ids: Enum.reject(ids, &MapSet.member?(found, &1))
    }
  end

  @doc """
  The PubSub topic every audited change is broadcast on, as
  `{:feature_flag_changed, flag}`: `"feature_flags"`. The message names only
  the flag, never a user.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to `topic/0`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Kanban.PubSub, @topic)

  @doc """
  Turns `flag` on for the user whose email is `email`, trimmed and matched
  without regard to case. Only an enabled site admin may; the check comes
  before the lookup, so nobody else can learn whether an address exists.
  A disabled account, or one that already has the gate, is refused with
  nothing written.
  """
  @spec turn_on_for_email(Scope.t() | nil, flag(), term()) :: :ok | {:error, change_error()}
  def turn_on_for_email(scope, flag, email) do
    validate!(flag)

    with {:ok, actor} <- authorize(scope),
         {:ok, email} <- normalize_email(email),
         {:ok, user} <- find_addable_user(email),
         :ok <- refute_user_gate(flag, user.id),
         :ok <- enable_for_user(flag, user) do
      record_user_enabled(actor, flag, user.id)
    end
  end

  @doc """
  Removes the gate for `flag` of the user with id `user_id`, which works for a
  deleted account too. Refused with `{:error, :not_enabled}` when that user
  has no gate, as on a second click from a page that has not refreshed yet.
  """
  @spec turn_off_for_user_id(Scope.t() | nil, flag(), integer()) ::
          :ok | {:error, change_error()}
  def turn_off_for_user_id(scope, flag, user_id) when is_integer(user_id) do
    validate!(flag)

    with {:ok, actor} <- authorize(scope),
         :ok <- require_user_gate(flag, user_id),
         :ok <- disable_for_user(flag, %User{id: user_id}) do
      record_user_disabled(actor, flag, user_id)
    end
  end

  @doc "Turns the everyone gate for `flag` on, as a site admin, audited."
  @spec turn_on_for_everyone(Scope.t() | nil, flag()) :: :ok | {:error, change_error()}
  def turn_on_for_everyone(scope, flag) do
    validate!(flag)

    with {:ok, actor} <- authorize(scope),
         :ok <- refute_everyone_gate(flag),
         :ok <- enable_for_everyone(flag) do
      AuditLog.event(:feature_flag_enabled,
        user_id: actor.id,
        flag: Atom.to_string(flag),
        scope: "everyone"
      )

      broadcast(flag)
    end
  end

  @doc """
  Turns the everyone gate for `flag` off, as a site admin, audited. Users
  with their own gate keep it.
  """
  @spec turn_off_for_everyone(Scope.t() | nil, flag()) :: :ok | {:error, change_error()}
  def turn_off_for_everyone(scope, flag) do
    validate!(flag)

    with {:ok, actor} <- authorize(scope),
         :ok <- require_everyone_gate(flag),
         :ok <- disable_for_everyone(flag) do
      AuditLog.event(:feature_flag_disabled,
        user_id: actor.id,
        flag: Atom.to_string(flag),
        scope: "everyone"
      )

      broadcast(flag)
    end
  end

  # The caller passes a scope built from a freshly read user; a stale or
  # demoted one is refused here as well.
  defp authorize(%Scope{user: %User{type: :admin, disabled_at: nil} = actor}), do: {:ok, actor}
  defp authorize(_scope), do: {:error, :unauthorized}

  defp normalize_email(email) when is_binary(email) do
    case String.trim(email) do
      "" -> {:error, :invalid_email}
      trimmed -> check_email_length(trimmed)
    end
  end

  defp normalize_email(_email), do: {:error, :invalid_email}

  defp check_email_length(email) do
    if String.length(email) > @max_email_length,
      do: {:error, :invalid_email},
      else: {:ok, email}
  end

  # users.email is citext, so the lookup ignores case without downcasing here.
  defp find_addable_user(email) do
    case Accounts.get_user_by_email(email) do
      nil -> {:error, :user_not_found}
      %User{disabled_at: nil} = user -> {:ok, user}
      %User{} -> {:error, :user_disabled}
    end
  end

  # The audited writes check the gates through fetch_gates/1, so a store read
  # error is {:error, :store_failed} like a failed write, never a crash whose
  # report would carry the admin's event payload (the typed address) with it.
  defp refute_user_gate(flag, user_id) do
    with {:ok, gates} <- fetch_gates(flag) do
      if user_id in enabled_user_ids(gates), do: {:error, :already_enabled}, else: :ok
    end
  end

  defp require_user_gate(flag, user_id) do
    with {:ok, gates} <- fetch_gates(flag) do
      if user_id in enabled_user_ids(gates), do: :ok, else: {:error, :not_enabled}
    end
  end

  defp refute_everyone_gate(flag) do
    with {:ok, gates} <- fetch_gates(flag) do
      if everyone_gate?(gates), do: {:error, :already_enabled}, else: :ok
    end
  end

  defp require_everyone_gate(flag) do
    with {:ok, gates} <- fetch_gates(flag) do
      if everyone_gate?(gates), do: :ok, else: {:error, :not_enabled}
    end
  end

  # Each audit call names its action and keys literally, as the telemetry
  # catalog requires.
  defp record_user_enabled(actor, flag, user_id) do
    AuditLog.event(:feature_flag_enabled,
      user_id: actor.id,
      flag: Atom.to_string(flag),
      target_user_id: user_id,
      scope: "user"
    )

    broadcast(flag)
  end

  defp record_user_disabled(actor, flag, user_id) do
    AuditLog.event(:feature_flag_disabled,
      user_id: actor.id,
      flag: Atom.to_string(flag),
      target_user_id: user_id,
      scope: "user"
    )

    broadcast(flag)
  end

  defp broadcast(flag) do
    Phoenix.PubSub.broadcast(Kanban.PubSub, @topic, {:feature_flag_changed, flag})
    :ok
  end

  # A store error raises, as a failed Kanban.Repo call would.
  defp gates(flag) do
    case flag |> validate!() |> FunWithFlags.get_flag() do
      nil -> []
      %Flag{gates: gates} -> gates
    end
  end

  defp fetch_gates(flag) do
    case flag |> validate!() |> FunWithFlags.get_flag() do
      nil -> {:ok, []}
      %Flag{gates: gates} -> {:ok, gates}
      _store_error -> {:error, :store_failed}
    end
  end

  defp everyone_gate?(gates),
    do: Enum.any?(gates, &match?(%Gate{type: :boolean, enabled: true}, &1))

  defp enabled_user_ids(gates) do
    ids =
      for %Gate{type: :actor, enabled: true, for: "user:" <> id} <- gates,
          {id, ""} <- [Integer.parse(id)],
          id > 0 and id <= @max_bigint,
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
