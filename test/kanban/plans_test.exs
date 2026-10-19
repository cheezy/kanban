defmodule Kanban.PlansTest do
  # async: false - these tests change the global :plans_enforced application env
  # (directly and through Kanban.PlansHelpers) and evaluate config/runtime.exs,
  # which reads process-wide environment variables.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards.Board
  alias Kanban.Organizations
  alias Kanban.Plans

  @config Path.expand("../../config/config.exs", __DIR__)
  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    previous = Application.fetch_env(:kanban, :plans_enforced)
    on_exit(fn -> restore_plans_enforced(previous) end)
    :ok
  end

  # Counts the Repo queries this test process runs while `fun` executes, and
  # returns {result, count}.
  defp count_queries(fun) do
    test_pid = self()
    ref = :counters.new(1, [])
    handler_id = "plans-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(ref, 1, 1)
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(ref, 1)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp org_board(organization) do
    organization |> org_workspace_fixture() |> place_board_in_workspace()
  end

  describe "enforced?/0" do
    test "is false when the flag is unset" do
      Application.delete_env(:kanban, :plans_enforced)
      refute Plans.enforced?()
    end

    test "is false in the test environment's loaded config" do
      assert Application.fetch_env(:kanban, :plans_enforced) == {:ok, false}
      refute Plans.enforced?()
    end

    test "reads the flag at call time" do
      Application.put_env(:kanban, :plans_enforced, true)
      assert Plans.enforced?()

      Application.put_env(:kanban, :plans_enforced, false)
      refute Plans.enforced?()
    end

    test "treats any value other than the boolean true as off" do
      for value <- ["true", 1, :yes, nil] do
        Application.put_env(:kanban, :plans_enforced, value)
        refute Plans.enforced?(), "expected #{inspect(value)} to leave enforcement off"
      end
    end
  end

  describe "paid_board?/1" do
    test "is true for a board in an org workspace, by struct and by id" do
      board = org_board(organization_fixture())

      assert Plans.paid_board?(board)
      assert Plans.paid_board?(board.id)
      assert board |> Repo.preload(:workspace) |> Plans.paid_board?()
    end

    test "is false for a board in a personal workspace, by struct and by id" do
      board = board_fixture(user_fixture())

      refute Plans.paid_board?(board)
      refute Plans.paid_board?(board.id)
      refute board |> Repo.preload(:workspace) |> Plans.paid_board?()
    end

    test "is false for a board without a workspace" do
      refute Plans.paid_board?(%Board{id: 1, workspace_id: nil, workspace: nil})
      refute Plans.paid_board?(%Board{workspace_id: nil})
    end

    test "is false for a board id that matches no board" do
      refute Plans.paid_board?(-1)
    end

    test "does not query when the workspace is preloaded" do
      paid = org_board(organization_fixture()) |> Repo.preload(:workspace)
      free = user_fixture() |> board_fixture() |> Repo.preload(:workspace)

      assert {true, 0} = count_queries(fn -> Plans.paid_board?(paid) end)
      assert {false, 0} = count_queries(fn -> Plans.paid_board?(free) end)
    end

    test "runs exactly one query when given an id or an unpreloaded board" do
      board = org_board(organization_fixture())

      assert {true, 1} = count_queries(fn -> Plans.paid_board?(board.id) end)
      assert {true, 1} = count_queries(fn -> Plans.paid_board?(board) end)
    end

    test "an unpreloaded board follows a move into an org workspace made after loading" do
      board = board_fixture(user_fixture())
      org_workspace = org_workspace_fixture(organization_fixture())

      {1, _} =
        Board
        |> where([b], b.id == ^board.id)
        |> Repo.update_all(set: [workspace_id: org_workspace.id])

      # board.workspace_id still names the personal workspace; the check reads
      # the board's current row, not the stale struct.
      assert Plans.paid_board?(board)
      assert Plans.paid_board?(board.id)
    end
  end

  describe "free_board_member_cap/0" do
    test "is 3" do
      assert Plans.free_board_member_cap() == 3
    end
  end

  describe "member_cap_reached?/2" do
    test "with enforcement on, a free board is full at 3 members and above" do
      enforce_plans()
      board = board_fixture(user_fixture())

      refute Plans.member_cap_reached?(board, 2)
      assert Plans.member_cap_reached?(board, 3)
      assert Plans.member_cap_reached?(board, 5)
      assert Plans.member_cap_reached?(board.id, 3)
    end

    test "with enforcement on, a board without a workspace is free and full at 3" do
      enforce_plans()
      board = %Board{id: 1, workspace_id: nil, workspace: nil}

      refute Plans.member_cap_reached?(board, 2)
      assert Plans.member_cap_reached?(board, 3)
    end

    test "with enforcement on, a paid board is never full" do
      enforce_plans()
      board = org_board(organization_fixture())

      for count <- [2, 3, 5], do: refute(Plans.member_cap_reached?(board, count))
      refute Plans.member_cap_reached?(board.id, 5)
    end

    test "with enforcement off, no board is full" do
      Application.put_env(:kanban, :plans_enforced, false)
      free = board_fixture(user_fixture())
      paid = org_board(organization_fixture())

      for board <- [free, paid], count <- [2, 3, 5] do
        refute Plans.member_cap_reached?(board, count)
      end
    end

    test "does not query under the cap or with enforcement off" do
      board = board_fixture(user_fixture())

      Application.put_env(:kanban, :plans_enforced, false)
      assert {false, 0} = count_queries(fn -> Plans.member_cap_reached?(board, 5) end)

      enforce_plans()
      assert {false, 0} = count_queries(fn -> Plans.member_cap_reached?(board, 2) end)
      assert {true, 1} = count_queries(fn -> Plans.member_cap_reached?(board.id, 3) end)
    end

    test "rejects a negative or non-integer count" do
      board = board_fixture(user_fixture())

      for count <- [-1, "3", nil, 3.0] do
        assert_raise FunctionClauseError, fn -> Plans.member_cap_reached?(board, count) end
      end
    end
  end

  describe "user_has_paid_access?/1" do
    setup do
      organization = organization_fixture()
      admin = user_fixture()
      member = user_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      organization_member_fixture(organization, member, :member)

      %{organization: organization, admin: admin, member: member, free: user_fixture()}
    end

    test "is true for an org_admin and a member, from a User", %{admin: admin, member: member} do
      assert Plans.user_has_paid_access?(admin)
      assert Plans.user_has_paid_access?(member)
    end

    test "is false for a user in no Organization, from a User", %{free: free} do
      refute Plans.user_has_paid_access?(free)
    end

    test "falls back to a lookup for a Scope without a loaded membership", ctx do
      assert {true, 1} =
               count_queries(fn ->
                 ctx.admin |> Scope.for_user() |> Plans.user_has_paid_access?()
               end)

      assert ctx.member |> Scope.for_user() |> Plans.user_has_paid_access?()

      assert {false, 1} =
               count_queries(fn ->
                 ctx.free |> Scope.for_user() |> Plans.user_has_paid_access?()
               end)
    end

    test "uses the scope's preloaded membership without querying", %{admin: admin, member: member} do
      for user <- [admin, member] do
        membership = Organizations.get_membership(user)
        scope = user |> Scope.for_user() |> Scope.put_organization_membership(membership)

        assert {true, 0} = count_queries(fn -> Plans.user_has_paid_access?(scope) end)
      end
    end

    test "is false for a scope without a user, and for nil" do
      assert {false, 0} = count_queries(fn -> Plans.user_has_paid_access?(%Scope{}) end)
      refute Plans.user_has_paid_access?(nil)
    end
  end

  describe "board_unlocked?/1 and user_unlocked?/1" do
    setup do
      organization = organization_fixture()
      member = user_fixture()
      organization_member_fixture(organization, member)
      free = user_fixture()

      %{
        member: member,
        free: free,
        paid_board: org_board(organization),
        free_board: board_fixture(free)
      }
    end

    test "are true for every subject, without querying, when enforcement is off", ctx do
      Application.put_env(:kanban, :plans_enforced, false)

      for board <- [ctx.paid_board, ctx.free_board, ctx.free_board.id] do
        assert {true, 0} = count_queries(fn -> Plans.board_unlocked?(board) end)
      end

      for subject <- [ctx.member, ctx.free, Scope.for_user(ctx.free), %Scope{}, nil] do
        assert {true, 0} = count_queries(fn -> Plans.user_unlocked?(subject) end)
      end
    end

    test "follow paid status when enforcement is on", ctx do
      enforce_plans()

      assert Plans.board_unlocked?(ctx.paid_board)
      assert Plans.board_unlocked?(ctx.paid_board.id)
      refute Plans.board_unlocked?(ctx.free_board)
      refute Plans.board_unlocked?(ctx.free_board.id)

      assert Plans.user_unlocked?(ctx.member)
      assert ctx.member |> Scope.for_user() |> Plans.user_unlocked?()
      refute Plans.user_unlocked?(ctx.free)
      refute ctx.free |> Scope.for_user() |> Plans.user_unlocked?()
      refute Plans.user_unlocked?(%Scope{})
    end
  end

  describe "paid status follows the board, not the user" do
    test "an Organization member's personal board stays free while their org board is paid" do
      organization = organization_fixture()
      member = user_fixture()
      organization_member_fixture(organization, member)
      personal_board = board_fixture(member)
      org_board = org_board(organization)

      assert Plans.user_has_paid_access?(member)
      refute Plans.paid_board?(personal_board)
      assert Plans.paid_board?(org_board)

      enforce_plans()
      refute Plans.board_unlocked?(personal_board)
      assert Plans.board_unlocked?(org_board)
    end
  end

  @refused [:kanban, :plan, :feature_refused]
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

  describe "features/0 and surfaces/0" do
    test "features/0 returns exactly the eight paid features in a stable order" do
      assert Plans.features() == @features
      assert Plans.features() == Plans.features()
    end

    test "surfaces/0 returns the six entry points a refusal can come from" do
      assert Plans.surfaces() == @surfaces
    end
  end

  describe "parse_feature/1" do
    test "maps each feature's name to its atom" do
      for feature <- @features do
        assert feature |> Atom.to_string() |> Plans.parse_feature() == feature
      end
    end

    test "returns :error for an unknown name" do
      for name <- ["", "billing", "plans", "notification", "audit_log"] do
        assert Plans.parse_feature(name) == :error, "expected #{inspect(name)} to be :error"
      end
    end

    test "rejects a different case or surrounding whitespace" do
      for name <- ["Notifications", "MCP", " sso", "audit ", "telemetry\n", "\tworkspaces"] do
        assert Plans.parse_feature(name) == :error, "expected #{inspect(name)} to be :error"
      end
    end

    test "returns :error for input that is not a string" do
      for input <- [nil, :notifications, 1, ~c"sso", %{}] do
        assert Plans.parse_feature(input) == :error
      end
    end

    test "never creates an atom" do
      name = "plans_test_feature_#{System.unique_integer([:positive])}"

      assert Plans.parse_feature(name) == :error
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "check_board/3" do
    setup do
      attach_telemetry(@refused)
      free = user_fixture()

      %{
        paid_board: org_board(organization_fixture()),
        free_board: board_fixture(free)
      }
    end

    test "is :ok for every board, without querying or emitting, when enforcement is off", ctx do
      Application.put_env(:kanban, :plans_enforced, false)

      for board <- [ctx.paid_board, ctx.free_board, ctx.free_board.id, %Board{workspace: nil}] do
        assert {:ok, 0} =
                 count_queries(fn -> Plans.check_board(board, :audit, surface: :live_view) end)
      end

      refute_received {:telemetry_event, @refused, _measurements, _metadata}
    end

    test "is :ok for a paid board when enforcement is on, and emits nothing", ctx do
      enforce_plans()

      assert Plans.check_board(ctx.paid_board, :notifications, surface: :rest) == :ok
      assert Plans.check_board(ctx.paid_board.id, :notifications, surface: :rest) == :ok

      refute_received {:telemetry_event, @refused, _measurements, _metadata}
    end

    test "refuses a free board when enforcement is on and emits feature and surface only", ctx do
      enforce_plans()

      assert Plans.check_board(ctx.free_board, :bulk_actions, surface: :controller) ==
               {:error, {:plan_required, :bulk_actions}}

      assert_received {:telemetry_event, @refused, %{count: 1}, metadata}
      assert metadata == %{feature: :bulk_actions, surface: :controller}

      assert Plans.check_board(ctx.free_board.id, :mcp, surface: :mcp) ==
               {:error, {:plan_required, :mcp}}

      assert_received {:telemetry_event, @refused, %{count: 1}, %{feature: :mcp, surface: :mcp}}
    end

    test "refuses a board without a workspace when enforcement is on" do
      enforce_plans()

      assert Plans.check_board(%Board{workspace: nil}, :sso, surface: :context) ==
               {:error, {:plan_required, :sso}}

      assert_received {:telemetry_event, @refused, %{count: 1},
                       %{feature: :sso, surface: :context}}
    end

    test "accepts every feature and every surface", ctx do
      enforce_plans()

      for feature <- @features, surface <- @surfaces do
        assert Plans.check_board(ctx.free_board, feature, surface: surface) ==
                 {:error, {:plan_required, feature}}

        assert_received {:telemetry_event, @refused, %{count: 1}, metadata}
        assert metadata == %{feature: feature, surface: surface}
      end
    end
  end

  describe "check_user/3" do
    setup do
      attach_telemetry(@refused)
      organization = organization_fixture()
      member = user_fixture()
      organization_member_fixture(organization, member)

      %{member: member, free: user_fixture()}
    end

    test "is :ok for every subject, without querying or emitting, when enforcement is off", ctx do
      Application.put_env(:kanban, :plans_enforced, false)

      for subject <- [ctx.member, ctx.free, Scope.for_user(ctx.free), %Scope{}, nil] do
        assert {:ok, 0} =
                 count_queries(fn -> Plans.check_user(subject, :telemetry, surface: :oban) end)
      end

      refute_received {:telemetry_event, @refused, _measurements, _metadata}
    end

    test "is :ok for an Organization member when enforcement is on, and emits nothing", ctx do
      enforce_plans()

      assert Plans.check_user(ctx.member, :integrations, surface: :live_view) == :ok

      member_scope = Scope.for_user(ctx.member)
      assert Plans.check_user(member_scope, :integrations, surface: :live_view) == :ok

      refute_received {:telemetry_event, @refused, _measurements, _metadata}
    end

    test "refuses a free user, a scope without a user and nil when enforcement is on", ctx do
      enforce_plans()

      for subject <- [ctx.free, Scope.for_user(ctx.free), %Scope{}, nil] do
        assert Plans.check_user(subject, :workspaces, surface: :rest) ==
                 {:error, {:plan_required, :workspaces}}

        assert_received {:telemetry_event, @refused, %{count: 1}, metadata}
        assert metadata == %{feature: :workspaces, surface: :rest}
      end
    end
  end

  describe "check_board/3 and check_user/3 reject a bad feature or surface" do
    setup do
      attach_telemetry(@refused)
      %{free_board: board_fixture(user_fixture()), free: user_fixture()}
    end

    for enforced <- [false, true] do
      @enforced enforced

      test "raise for an unknown feature, a parsed :error or a string (enforced: #{enforced})",
           ctx do
        Application.put_env(:kanban, :plans_enforced, @enforced)

        for feature <- [:billing, :error, "audit", nil] do
          assert_raise ArgumentError, ~r/unknown plan feature/, fn ->
            Plans.check_board(ctx.free_board, feature, surface: :rest)
          end

          assert_raise ArgumentError, ~r/unknown plan feature/, fn ->
            Plans.check_user(ctx.free, feature, surface: :rest)
          end
        end

        refute_received {:telemetry_event, @refused, _measurements, _metadata}
      end

      test "raise for an unknown or missing surface (enforced: #{enforced})", ctx do
        Application.put_env(:kanban, :plans_enforced, @enforced)

        for opts <- [[surface: :api], [surface: "rest"], [surface: nil]] do
          assert_raise ArgumentError, ~r/unknown plan surface/, fn ->
            Plans.check_board(ctx.free_board, :audit, opts)
          end

          assert_raise ArgumentError, ~r/unknown plan surface/, fn ->
            Plans.check_user(ctx.free, :audit, opts)
          end
        end

        assert_raise ArgumentError, ~r/needs a :surface option/, fn ->
          Plans.check_board(ctx.free_board, :audit, [])
        end

        assert_raise ArgumentError, ~r/needs a :surface option/, fn ->
          Plans.check_user(ctx.free, :audit, [])
        end

        refute_received {:telemetry_event, @refused, _measurements, _metadata}
      end
    end

    test "raise when the options are not a keyword list", ctx do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Plans.check_board(ctx.free_board, :audit, %{surface: :rest})
      end

      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Plans.check_user(ctx.free, :audit, nil)
      end
    end

    test "never echo a non-atom value into the error message", ctx do
      error =
        assert_raise ArgumentError, fn ->
          Plans.check_board(ctx.free_board, "secret-feature-name", surface: :rest)
        end

      refute error.message =~ "secret-feature-name"

      error =
        assert_raise ArgumentError, fn ->
          Plans.check_user(ctx.free, :audit, surface: "secret-surface-name")
        end

      refute error.message =~ "secret-surface-name"
    end
  end

  describe "paid_board_ids_query/0" do
    test "returns only the ids of boards in Organization workspaces" do
      organization = organization_fixture()
      paid_a = org_board(organization)
      paid_b = org_board(organization_fixture())
      _free = board_fixture(user_fixture())

      assert Plans.paid_board_ids_query() |> Repo.all() |> Enum.sort() ==
               Enum.sort([paid_a.id, paid_b.id])
    end

    test "composes into a subquery" do
      paid = org_board(organization_fixture())
      free = board_fixture(user_fixture())

      ids =
        Board
        |> where([b], b.id in ^[paid.id, free.id])
        |> where([b], b.id in subquery(Plans.paid_board_ids_query()))
        |> select([b], b.id)
        |> Repo.all()

      assert ids == [paid.id]
    end

    test "only builds the query and never runs it" do
      assert {%Ecto.Query{}, 0} = count_queries(fn -> Plans.paid_board_ids_query() end)
    end
  end

  describe "unlocked_board_ids/1" do
    test "returns every id without a query while enforcement is off" do
      Application.put_env(:kanban, :plans_enforced, false)
      paid = org_board(organization_fixture())
      free = board_fixture(user_fixture())

      assert {ids, 0} = count_queries(fn -> Plans.unlocked_board_ids([paid.id, free.id, -1]) end)
      assert ids == MapSet.new([paid.id, free.id, -1])
    end

    test "keeps only the paid ids in one query while enforcement is on" do
      enforce_plans()
      paid = org_board(organization_fixture())
      free = board_fixture(user_fixture())

      assert {ids, 1} = count_queries(fn -> Plans.unlocked_board_ids([paid.id, free.id, -1]) end)
      assert ids == MapSet.new([paid.id])
    end

    test "an empty list costs no query" do
      enforce_plans()

      assert {ids, 0} = count_queries(fn -> Plans.unlocked_board_ids([]) end)
      assert ids == MapSet.new()
    end
  end

  describe "Kanban.PlansHelpers" do
    test "enforce_plans/0 switches enforcement on" do
      Application.put_env(:kanban, :plans_enforced, false)

      assert enforce_plans() == :ok
      assert Plans.enforced?()
    end

    test "enforce_plans/1 works as a setup callback" do
      Application.put_env(:kanban, :plans_enforced, false)

      assert enforce_plans(%{}) == :ok
      assert Plans.enforced?()
    end

    test "restore_plans_enforced/1 puts back a previous value" do
      Application.put_env(:kanban, :plans_enforced, true)

      restore_plans_enforced({:ok, false})
      assert Application.fetch_env(:kanban, :plans_enforced) == {:ok, false}
    end

    test "restore_plans_enforced/1 deletes a key that was not set" do
      Application.put_env(:kanban, :plans_enforced, true)

      restore_plans_enforced(:error)
      assert Application.fetch_env(:kanban, :plans_enforced) == :error
    end
  end

  describe "the :plans_enforced config" do
    @env_var "STRIDE_PLANS_ENFORCED"
    @prod_env %{
      "DATABASE_URL" => "ecto://user:pass@db.internal/kanban",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "ENCRYPTION_KEY" => "k" |> String.duplicate(32) |> Base.encode64()
    }
    @touched [@env_var | Map.keys(@prod_env)] ++ ~w(DATABASE_SSL PHX_SERVER)

    setup do
      saved = Map.new(@touched, &{&1, System.get_env(&1)})

      on_exit(fn ->
        for {name, value} <- saved do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      for name <- @touched, do: System.delete_env(name)
      System.put_env(@prod_env)
      :ok
    end

    defp runtime_flag(env) do
      @runtime
      |> Config.Reader.read!(env: env, target: :host)
      |> get_in([:kanban, :plans_enforced])
    end

    test "config/config.exs defaults it to false in every environment" do
      for env <- [:dev, :test, :prod] do
        assert @config |> Config.Reader.read!(env: env) |> get_in([:kanban, :plans_enforced]) ==
                 false
      end
    end

    test "config/runtime.exs leaves it false in dev, test and prod when the variable is unset" do
      for env <- [:dev, :test, :prod], do: assert(runtime_flag(env) == false)
    end

    test "config/runtime.exs turns it on only when the variable is exactly true" do
      System.put_env(@env_var, "true")
      for env <- [:dev, :test, :prod], do: assert(runtime_flag(env) == true)

      for value <- ["TRUE", "True", "1", "", "yes", " true"] do
        System.put_env(@env_var, value)
        assert runtime_flag(:prod) == false, "expected #{inspect(value)} to leave it off"
      end
    end
  end
end
