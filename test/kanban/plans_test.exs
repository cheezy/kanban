defmodule Kanban.PlansTest do
  # async: false - these tests change the global :plans_enforced application env
  # (directly and through Kanban.PlansHelpers) and evaluate config/runtime.exs,
  # which reads process-wide environment variables.
  use Kanban.DataCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
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
