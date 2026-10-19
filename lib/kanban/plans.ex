defmodule Kanban.Plans do
  @moduledoc """
  The plan check. **This module is the only place that decides paid versus
  free.** Every lock, the free-board member cap and every paid gate calls it,
  and nothing else reads the `:plans_enforced` flag. See section 5 of
  `docs/plans/PAYING-ORGANIZATIONS-DESIGN.md`.

  ## Paid status

    * A **board** is paid only when its workspace belongs to an Organization
      (`workspaces.organization_id` is set). Who is asking does not matter, so
      an Organization member's personal-workspace board is free. A board with
      no workspace is free.
    * A **user** has paid access when they are a member of an Organization, in
      either role. This decides only whether user-level paid UI shows unlocked;
      board-level features still resolve per board.

  The decision depends only on the board or the user handed in. Only
  `parse_feature/1` (a fixed allow-list) and `strip_locked_task_fields/3`
  (which only removes fields) take request input, so a caller cannot
  influence the answer except through which board or user it asks about.

  ## Enforcement

  `enforced?/0` reads `Application.get_env(:kanban, :plans_enforced, false)` at
  call time, never with `compile_env`, because launch flips the flag with a
  restart rather than a rebuild. The flag is false in every environment until
  the deployment sets `STRIDE_PLANS_ENFORCED=true` (see `config/runtime.exs`).
  Only the deployment environment can switch it on; no request parameter or API
  field reads or writes it.

  `board_unlocked?/1` and `user_unlocked?/1` are true whenever enforcement is
  off, without touching the database. Render-time UI uses them.

  Paid status is never cached in a process or ETS: a board can move into an
  Organization at any time.

  ## Paid features and refusals

  `features/0` lists the paid features, and `parse_feature/1` turns a string
  into one of them through a fixed allow-list, never `String.to_atom/1`.

  `check_board/3` and `check_user/3` are the refusal helpers every entry point
  calls: a LiveView event, a controller, the REST API, an MCP tool, an Oban job
  or a context function. Each returns `:ok`, or
  `{:error, {:plan_required, feature}}` and emits
  `[:kanban, :plan, :feature_refused]` with only the `feature` and the
  `surface` that refused it, so the error shape and the telemetry are the same
  everywhere. They decide through `board_unlocked?/1` and `user_unlocked?/1`,
  so there is still only one paid-versus-free decision.

  A feature outside `features/0`, or a `:surface` outside `surfaces/0`, raises
  `ArgumentError` before anything is decided or emitted, whether or not
  enforcement is on, so a mistake fails the test suite instead of reaching
  telemetry.

  `strip_locked_task_fields/3` is the accept-but-do-not-store form for the
  paid task fields (`telemetry_event` and `metrics_to_track`): on a locked
  board it removes them from task params, child tasks included, and reports
  which ones it removed, so the request still succeeds.

  `paid_board_ids_query/0` is the list-filter form of `paid_board?/1`: a
  query of the ids of boards in Organization workspaces, for filters such as
  the notification bell. It only builds the query; the caller runs it.

  ## Free-board member cap

  `free_board_member_cap/0` is the number of human members a free board holds
  while plans are enforced, and `member_cap_reached?/2` decides whether a board
  with a given member count may take another. Members are `board_users` rows,
  the owner's included. `Kanban.Boards.add_user_to_board/4` asks it under a row
  lock on the board, and board invitations and board moves (G442) will ask it
  the same way.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace

  @features [
    :notifications,
    :audit,
    :sso,
    :workspaces,
    :bulk_actions,
    :integrations,
    :telemetry,
    :mcp
  ]

  @surfaces [:live_view, :controller, :rest, :mcp, :oban, :context]

  # The task fields only a paid board stores, in the order warnings name them.
  @locked_task_fields ["telemetry_event", "metrics_to_track"]
  @locked_task_keys ["telemetry_event", :telemetry_event, "metrics_to_track", :metrics_to_track]

  @free_board_member_cap 3

  @type feature ::
          :notifications
          | :audit
          | :sso
          | :workspaces
          | :bulk_actions
          | :integrations
          | :telemetry
          | :mcp

  @type surface :: :live_view | :controller | :rest | :mcp | :oban | :context

  @doc """
  Returns true only when paid-plan enforcement is switched on.

  Reads the `:plans_enforced` application env at call time and treats any value
  other than the boolean `true` as off.
  """
  @spec enforced?() :: boolean()
  def enforced?, do: Application.get_env(:kanban, :plans_enforced, false) == true

  @doc """
  Returns true when the board's workspace belongs to an Organization.

  Accepts a `%Board{}` or a board id. A board whose workspace is preloaded is
  decided without a query; a board without a preloaded workspace, or a board
  id, costs one query. A board with no workspace, and an id that matches no
  board, are free.
  """
  @spec paid_board?(Board.t() | integer()) :: boolean()
  def paid_board?(%Board{workspace: %Workspace{organization_id: organization_id}}),
    do: not is_nil(organization_id)

  def paid_board?(%Board{workspace: nil}), do: false
  def paid_board?(%Board{id: id}) when is_integer(id), do: paid_board?(id)
  def paid_board?(%Board{}), do: false

  def paid_board?(board_id) when is_integer(board_id) do
    from(b in Board,
      join: w in assoc(b, :workspace),
      where: b.id == ^board_id,
      select: not is_nil(w.organization_id)
    )
    |> Repo.one()
    |> Kernel.==(true)
  end

  @doc """
  Returns true when the user belongs to an Organization, in either role.

  Accepts a `%User{}` or a `%Scope{}`. A scope that carries its
  `organization_membership` is decided without a query. A scope without one
  (scopes built outside `KanbanWeb.UserAuth` leave it `nil`) falls back to
  `Kanban.Organizations.get_membership/1`. A scope without a user, and `nil`,
  have no paid access.
  """
  @spec user_has_paid_access?(User.t() | Scope.t() | nil) :: boolean()
  def user_has_paid_access?(%Scope{organization_membership: %OrganizationMember{}}), do: true
  def user_has_paid_access?(%Scope{user: %User{} = user}), do: user_has_paid_access?(user)
  def user_has_paid_access?(%Scope{}), do: false
  def user_has_paid_access?(%User{} = user), do: not is_nil(Organizations.get_membership(user))
  def user_has_paid_access?(nil), do: false

  @doc """
  Returns true when enforcement is off or the board is paid.

  Accepts what `paid_board?/1` accepts. When enforcement is off it never
  queries.
  """
  @spec board_unlocked?(Board.t() | integer()) :: boolean()
  def board_unlocked?(board), do: not enforced?() or paid_board?(board)

  @doc """
  Returns true when enforcement is off or the user has paid access.

  Accepts what `user_has_paid_access?/1` accepts. When enforcement is off it
  never queries.
  """
  @spec user_unlocked?(User.t() | Scope.t() | nil) :: boolean()
  def user_unlocked?(user_or_scope), do: not enforced?() or user_has_paid_access?(user_or_scope)

  @doc """
  Returns true when enforcement is off or `membership` is an Organization
  membership.

  For callers that have already looked the membership up, where `nil` means the
  user belongs to no Organization (as `KanbanWeb.UserAuth` does when it builds a
  scope), so it never queries.
  """
  @spec membership_unlocked?(OrganizationMember.t() | nil) :: boolean()
  def membership_unlocked?(membership),
    do: not enforced?() or match?(%OrganizationMember{}, membership)

  @doc """
  Returns the most human members a free board holds while plans are enforced.
  """
  @spec free_board_member_cap() :: pos_integer()
  def free_board_member_cap, do: @free_board_member_cap

  @doc """
  Returns true when a board with `member_count` members may not take another:
  plans are enforced, the board is free, and `member_count` is already
  `free_board_member_cap/0` or more.

  Accepts what `paid_board?/1` accepts. It never queries when the count is
  under the cap or enforcement is off. Pass a board id, or a board without a
  preloaded workspace, to decide from the database rather than from a
  workspace loaded earlier.
  """
  @spec member_cap_reached?(Board.t() | integer(), non_neg_integer()) :: boolean()
  def member_cap_reached?(board, member_count)
      when is_integer(member_count) and member_count >= 0 do
    member_count >= @free_board_member_cap and not board_unlocked?(board)
  end

  @doc """
  Returns the paid feature atoms, always in the same order.
  """
  @spec features() :: [feature()]
  def features, do: @features

  @doc """
  Returns the surfaces a refusal can come from, the values `check_board/3` and
  `check_user/3` accept for `:surface`.
  """
  @spec surfaces() :: [surface()]
  def surfaces, do: @surfaces

  @doc """
  Maps a feature name to its atom through a fixed allow-list, or returns
  `:error`.

  The match is exact: a different case or surrounding whitespace is `:error`.
  It never creates an atom.
  """
  @spec parse_feature(term()) :: feature() | :error
  def parse_feature("notifications"), do: :notifications
  def parse_feature("audit"), do: :audit
  def parse_feature("sso"), do: :sso
  def parse_feature("workspaces"), do: :workspaces
  def parse_feature("bulk_actions"), do: :bulk_actions
  def parse_feature("integrations"), do: :integrations
  def parse_feature("telemetry"), do: :telemetry
  def parse_feature("mcp"), do: :mcp
  def parse_feature(_name), do: :error

  @doc """
  Returns `:ok` when `board_unlocked?/1` is true for the board, else refuses.

  A refusal returns `{:error, {:plan_required, feature}}` and emits
  `[:kanban, :plan, :feature_refused]` with `feature` and `surface`. `opts`
  must carry `:surface`, one of `surfaces/0`. Accepts what `paid_board?/1`
  accepts, and never queries when enforcement is off.

  Raises `ArgumentError` for a feature outside `features/0` or a missing or
  unknown surface.
  """
  @spec check_board(Board.t() | integer(), feature(), [{:surface, surface()}]) ::
          :ok | {:error, {:plan_required, feature()}}
  def check_board(board, feature, opts) do
    surface = validate!(feature, opts)
    if board_unlocked?(board), do: :ok, else: refuse(feature, surface)
  end

  @doc """
  Returns `:ok` when `user_unlocked?/1` is true for the user or scope, else
  refuses.

  Refuses, validates and queries exactly as `check_board/3` does. Accepts what
  `user_has_paid_access?/1` accepts.
  """
  @spec check_user(User.t() | Scope.t() | nil, feature(), [{:surface, surface()}]) ::
          :ok | {:error, {:plan_required, feature()}}
  def check_user(user_or_scope, feature, opts) do
    surface = validate!(feature, opts)
    if user_unlocked?(user_or_scope), do: :ok, else: refuse(feature, surface)
  end

  @doc """
  Removes the paid task fields from `params` when the board is locked.

  Returns `{params, dropped}`, where `dropped` names the removed fields in the
  order of `locked_task_fields/0`. `params` is a task map with string or atom
  keys, or a list of them; the child tasks under `"tasks"` (or `:tasks`) are
  stripped too. A field counts as dropped whenever its key is present, even
  with a `nil` or empty value. Anything else passes through unchanged. On an
  unlocked board it returns `{params, []}` without looking at them.

  With `surface: surface` it also emits `[:kanban, :plan, :feature_refused]`
  for `:telemetry` once when anything was dropped; without it, it never emits.
  """
  @spec strip_locked_task_fields(term(), Board.t() | integer(), [{:surface, surface()}]) ::
          {term(), [String.t()]}
  def strip_locked_task_fields(params, board, opts \\ []) do
    surface = if opts == [], do: nil, else: validate!(:telemetry, opts)

    if board_unlocked?(board) do
      {params, []}
    else
      params |> drop_locked_task_fields() |> report_dropped(surface)
    end
  end

  @doc "The task fields `strip_locked_task_fields/3` removes on a locked board."
  @spec locked_task_fields() :: [String.t()]
  def locked_task_fields, do: @locked_task_fields

  @doc """
  Returns a query selecting the id of every board whose workspace belongs to an
  Organization.

  It builds the query and never runs it, so callers compose it, for example as
  `where: b.id in subquery(Kanban.Plans.paid_board_ids_query())`. It ignores
  `:plans_enforced`; a caller that filters by it checks `enforced?/0` first.
  """
  @spec paid_board_ids_query() :: Ecto.Query.t()
  def paid_board_ids_query do
    from(b in Board,
      join: w in assoc(b, :workspace),
      where: not is_nil(w.organization_id),
      select: b.id
    )
  end

  @doc """
  Returns the ids among `board_ids` whose boards are unlocked, as a set.

  When enforcement is off every id is unlocked and it never queries. When it
  is on, one query keeps only the paid boards; an empty list costs nothing,
  and an id that matches no board is left out.
  """
  @spec unlocked_board_ids([integer()]) :: MapSet.t(integer())
  def unlocked_board_ids(board_ids) when is_list(board_ids) do
    if enforced?(), do: paid_ids_among(board_ids), else: MapSet.new(board_ids)
  end

  defp paid_ids_among([]), do: MapSet.new()

  defp paid_ids_among(board_ids) do
    paid_board_ids_query()
    |> where([b], b.id in ^board_ids)
    |> Repo.all()
    |> MapSet.new()
  end

  defp drop_locked_task_fields(params) when is_list(params) do
    {stripped, dropped} = Enum.map_reduce(params, [], &drop_with_acc/2)
    {stripped, ordered_fields(dropped)}
  end

  defp drop_locked_task_fields(params) when is_map(params) do
    present = for key <- @locked_task_keys, Map.has_key?(params, key), do: to_string(key)

    {stripped, child_dropped} =
      params |> Map.drop(@locked_task_keys) |> drop_child_task_fields()

    {stripped, ordered_fields(present ++ child_dropped)}
  end

  defp drop_locked_task_fields(other), do: {other, []}

  defp drop_with_acc(params, acc) do
    {stripped, dropped} = drop_locked_task_fields(params)
    {stripped, dropped ++ acc}
  end

  defp drop_child_task_fields(params) do
    Enum.reduce(["tasks", :tasks], {params, []}, &drop_children_under/2)
  end

  defp drop_children_under(key, {params, dropped}) do
    case params do
      %{^key => children} when is_list(children) ->
        {stripped, child_dropped} = drop_locked_task_fields(children)
        {Map.put(params, key, stripped), child_dropped ++ dropped}

      _no_children ->
        {params, dropped}
    end
  end

  defp ordered_fields(names), do: Enum.filter(@locked_task_fields, &(&1 in names))

  defp report_dropped({_params, [_ | _]} = result, surface) when not is_nil(surface) do
    refuse(:telemetry, surface)
    result
  end

  defp report_dropped(result, _surface), do: result

  defp validate!(feature, opts) when feature in @features and is_list(opts) do
    case Keyword.fetch(opts, :surface) do
      {:ok, surface} when surface in @surfaces ->
        surface

      {:ok, surface} ->
        raise ArgumentError,
              "unknown plan surface #{describe(surface)}, expected one of #{inspect(@surfaces)}"

      :error ->
        raise ArgumentError, "a plan check needs a :surface option, one of #{inspect(@surfaces)}"
    end
  end

  defp validate!(feature, opts) when is_list(opts) do
    raise ArgumentError,
          "unknown plan feature #{describe(feature)}, expected one of #{inspect(@features)}"
  end

  defp validate!(_feature, opts) do
    raise ArgumentError, "plan check options must be a keyword list, got #{describe(opts)}"
  end

  # Only atoms are echoed into the message. Any other value may have come from
  # a request, so it is described by its kind rather than its content.
  defp describe(value) when is_atom(value), do: inspect(value)
  defp describe(value) when is_binary(value), do: "(a string)"
  defp describe(_value), do: "(a non-atom value)"

  defp refuse(feature, surface) do
    Kanban.Telemetry.emit([:kanban, :plan, :feature_refused], %{count: 1}, %{
      feature: feature,
      surface: surface
    })

    {:error, {:plan_required, feature}}
  end
end
