defmodule Kanban.ResourcesDemoSeedsTest do
  # Not async: the seed reads environment variables, which are global.
  use Kanban.DataCase, async: false

  import ExUnit.CaptureIO

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Organizations.Organization
  alias Kanban.Tasks.ChangedFilesAudit
  alias Kanban.Tasks.CompletionValidation
  alias Kanban.Tasks.Compliance
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.WorkflowSteps
  alias KanbanWeb.ReviewAcceptance

  @seed Path.expand("../../priv/repo/resources_demo_seeds.exs", __DIR__)
  @password "demo-password-for-the-seed-test"

  setup do
    System.put_env("RESOURCES_DEMO_PASSWORD", @password)
    on_exit(fn -> System.delete_env("RESOURCES_DEMO_PASSWORD") end)
  end

  defp run_seed(binding \\ []) do
    capture_io(fn ->
      {summary, _binding} = @seed |> File.read!() |> Code.eval_string(binding, file: @seed)
      send(self(), {:summary, summary})
    end)
  end

  defp counts do
    %{
      users: demo_count(User),
      boards: Repo.aggregate(Board, :count),
      tasks: Repo.aggregate(Task, :count),
      labels: Repo.aggregate(Label, :count),
      comments: Repo.aggregate(TaskComment, :count),
      tokens: Repo.aggregate(ApiToken, :count),
      members: Repo.aggregate(BoardUser, :count),
      organizations: Repo.aggregate(Organization, :count)
    }
  end

  defp demo_count(User),
    do: from(u in User, where: like(u.email, "%@example.test")) |> Repo.aggregate(:count)

  defp demo_board(name) do
    query =
      from b in Board,
        join: bu in BoardUser,
        on: bu.board_id == b.id,
        join: u in User,
        on: u.id == bu.user_id,
        where: u.email == "maya.chen@example.test" and bu.access == :owner and b.name == ^name

    Repo.one!(query)
  end

  defp tasks_by_column(board) do
    from(t in Task,
      join: c in Column,
      on: c.id == t.column_id,
      where: c.board_id == ^board.id,
      select: {c.name, t}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  test "seeding twice creates the demo data once" do
    before = counts()
    output = run_seed()
    assert_received {:summary, %{boards_created: ["Checkout Revamp", "Marketing Site Launch"]}}
    after_first = counts()

    assert after_first.users == before.users + 4
    assert after_first.boards == before.boards + 2

    run_seed()
    assert_received {:summary, %{boards_created: []}}
    assert counts() == after_first

    refute output =~ @password
  end

  test "the seed creates no Organization" do
    before = Repo.aggregate(Organization, :count)
    run_seed()
    run_seed()
    assert Repo.aggregate(Organization, :count) == before
  end

  test "the AI board has the data the guides photograph" do
    run_seed()
    board = demo_board("Checkout Revamp")
    by_column = tasks_by_column(board)

    for column <- ["Backlog", "Ready", "Doing", "Review", "Done"] do
      assert by_column[column] != nil, "#{column} has no tasks"
    end

    assert [review] =
             Enum.filter(by_column["Review"], &(&1.needs_review and &1.review_status == :pending))

    assert review.completed_at

    goal = Enum.find(by_column["Ready"], &(&1.type == :goal))
    assert from(t in Task, where: t.parent_id == ^goal.id) |> Repo.aggregate(:count) == 3

    recent = DateTime.add(DateTime.utc_now(), -30, :day)
    completed = Enum.filter(by_column["Done"], &(&1.status == :completed))
    assert length(completed) >= 20
    assert Enum.all?(completed, &(DateTime.compare(&1.completed_at, recent) == :gt))
    assert Enum.any?(completed, & &1.reviewed_at)
    assert completed |> Enum.map(& &1.completed_by_agent) |> Enum.uniq() |> length() > 1

    assert from(l in Label, where: l.board_id == ^board.id) |> Repo.aggregate(:count) == 5
    assert from(t in ApiToken, where: t.board_id == ^board.id) |> Repo.aggregate(:count) == 1

    [comment] = from(c in TaskComment, where: c.task_id == ^review.id) |> Repo.all()
    assert comment.content =~ "@[Maya Chen](user:"
  end

  test "the Review task carries a full completion for the Review queue" do
    run_seed()
    by_column = tasks_by_column(demo_board("Checkout Revamp"))
    [review] = by_column["Review"]
    result = review.reviewer_result

    assert {:ok, _} = CompletionValidation.validate_changed_files(review.changed_files)

    assert Enum.map(review.changed_files, & &1["path"]) ==
             String.split(review.actual_files_changed, ", ")

    refute ChangedFilesAudit.diff_missing?(review)
    assert {:ok, _} = CompletionValidation.validate_reviewer_result(result)
    assert CompletionValidation.review_contract_failures(result, review) == []
    assert CompletionValidation.acceptance_criteria_count_failures(result, review) == []
    assert {:ok, _} = CompletionValidation.cross_check_reviewer_result(result, review)
    assert ReviewAcceptance.acceptance_value(review) == "3/3"
    refute ReviewAcceptance.acceptance_inconsistent?(review)
    assert review.completed_by_id
  end

  @reviewed_title "Add a delivery estimate to the order summary"

  defp reviewed_tasks(board) do
    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id == ^board.id and t.title == @reviewed_title,
      select: {c.name, t}
    )
    |> Repo.all()
  end

  test "the reviewed Done task carries every section the task view can show" do
    run_seed()
    assert [{"Done", task}] = reviewed_tasks(demo_board("Checkout Revamp"))
    result = task.reviewer_result

    assert task.status == :completed
    assert task.review_status == :approved
    assert task.reviewed_by_id && task.reviewed_at
    assert Repo.preload(task, :created_by).created_by.name == "Maya Chen"
    assert task.why && task.what && task.where_context
    assert length(task.key_files) == 2
    assert length(task.verification_steps) == 2

    assert task.behaviour_test_matrix |> Enum.map(& &1.category) |> Enum.sort() ==
             Enum.sort(Kanban.Schemas.Task.BehaviourTestRow.categories())

    assert Enum.any?(task.behaviour_test_matrix, &(&1.status == "not_applicable"))
    assert task.telemetry_event && task.metrics_to_track && task.logging_requirements
    assert task.explorer_result["dispatched"] == true
    assert task.actual_complexity == :medium
    assert task.time_spent_minutes == 95

    assert {:ok, _} = CompletionValidation.validate_changed_files(task.changed_files)

    assert Enum.map(task.changed_files, & &1["path"]) ==
             String.split(task.actual_files_changed, ", ")

    refute ChangedFilesAudit.diff_missing?(task)
    assert {:ok, _} = CompletionValidation.validate_reviewer_result(result)
    assert CompletionValidation.review_contract_failures(result, task) == []
    assert CompletionValidation.acceptance_criteria_count_failures(result, task) == []
    assert {:ok, _} = CompletionValidation.cross_check_reviewer_result(result, task)
    assert ReviewAcceptance.acceptance_value(task) == "3/3"
  end

  test "a Checkout board seeded before the reviewed task existed gets it once" do
    run_seed()
    assert_received {:summary, %{reviewed_task: :created}}
    board = demo_board("Checkout Revamp")
    [{"Done", task}] = reviewed_tasks(board)

    # A board seeded by an older version of the script has no such task.
    Repo.delete!(task)
    run_seed()
    assert_received {:summary, %{boards_created: [], reviewed_task: :created}}
    assert [{"Done", _}] = reviewed_tasks(board)

    run_seed()
    assert_received {:summary, %{reviewed_task: :exists}}
    assert [{"Done", _}] = reviewed_tasks(board)
  end

  test "the Doing goal child depends on the finished one and stays in progress" do
    run_seed()
    tasks = demo_board("Checkout Revamp") |> tasks_by_column() |> Map.values() |> List.flatten()
    stored = Enum.find(tasks, &(&1.title == "Store card tokens with the payment provider"))
    shown = Enum.find(tasks, &(&1.title == "Show saved cards in the payment sheet"))

    assert stored.status == :completed
    assert shown.dependencies == [stored.identifier]
    assert shown.status == :in_progress
  end

  test "the custom board has a WIP-limited column and tasks in every column" do
    run_seed()
    board = demo_board("Marketing Site Launch")
    by_column = tasks_by_column(board)

    for column <- ["To Do", "In Progress", "In Review", "Published"] do
      assert by_column[column] != nil, "#{column} has no tasks"
    end

    in_progress =
      from(c in Column, where: c.board_id == ^board.id and c.name == "In Progress") |> Repo.one!()

    assert in_progress.wip_limit == 3
  end

  test "demo users use example.test addresses and are confirmed" do
    run_seed()

    users = from(u in User, where: like(u.email, "%@example.test")) |> Repo.all()
    assert length(users) == 4
    assert Enum.all?(users, & &1.confirmed_at)
    assert Enum.all?(users, & &1.two_factor_reminder_dismissed_at)
  end

  test "refuses to run against anything but the dev or test database" do
    before = counts()

    assert_raise RuntimeError, ~r/only runs against the dev database/, fn ->
      run_seed(env: :prod)
    end

    assert_raise RuntimeError, ~r/only runs against the dev database/, fn ->
      run_seed(database: "kanban_prod")
    end

    assert counts() == before
  end

  test "a password given on a later run replaces the demo password" do
    run_seed()
    System.put_env("RESOURCES_DEMO_PASSWORD", "a-different-demo-password")
    run_seed()

    assert Kanban.Accounts.get_user_by_email_and_password(
             "maya.chen@example.test",
             "a-different-demo-password"
           )
  end

  test "the returned binding carries no password" do
    capture_io(fn ->
      {_summary, binding} = @seed |> File.read!() |> Code.eval_string([], file: @seed)
      send(self(), {:binding, binding})
    end)

    assert_received {:binding, binding}
    refute inspect(binding, limit: :infinity, printable_limit: :infinity) =~ @password
  end

  test "refuses a password shorter than 12 characters without echoing it" do
    System.put_env("RESOURCES_DEMO_PASSWORD", "short-pw")

    error = assert_raise RuntimeError, fn -> run_seed() end
    assert error.message =~ "12 to 72 characters"
    refute error.message =~ "short-pw"
  end

  test "the AI board has workflow steps for the Compliance page" do
    run_seed()
    board = demo_board("Checkout Revamp")

    rates = Compliance.step_dispatch_rates(board.id)
    assert rates |> Map.keys() |> Enum.sort() == Enum.sort(WorkflowSteps.canonical_step_names())
    percentages = Enum.map(rates, fn {_name, %{rate: rate}} -> rate end)
    assert Enum.any?(percentages, &(&1 >= 80.0)), "no Done-coloured dispatch-rate bar"

    assert Enum.any?(percentages, &(&1 >= 50.0 and &1 < 80.0)),
           "no Review-coloured dispatch-rate bar"

    assert Enum.any?(percentages, &(&1 < 50.0)), "no red dispatch-rate bar"

    reasons = Compliance.skip_reasons(board.id)
    codes = Enum.map(WorkflowSteps.skip_reason_codes(), &to_string/1)
    assert reasons |> Map.keys() |> Enum.sort() == Enum.sort(codes)
    counts = Map.values(reasons)
    assert counts == Enum.uniq(counts), "skip reasons should have uneven counts"

    by_agent = Compliance.compliance_by_agent(board.id)
    assert map_size(by_agent) == 4
    assert by_agent |> Map.values() |> Enum.map(& &1.avg_steps) |> Enum.uniq() |> length() > 1
    assert Enum.any?(by_agent, fn {_agent, a} -> a.tasks_with_steps < a.total_tasks end)

    steps =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board.id,
        select: t.workflow_steps
      )
      |> Repo.all()
      |> List.flatten()

    assert steps != []
    assert Enum.all?(steps, &WorkflowSteps.valid_step?/1)
    assert Enum.all?(steps, &WorkflowSteps.valid_reason_code?/1)
  end

  test "every started demo task was created before it was claimed and completed" do
    run_seed()
    board = demo_board("Checkout Revamp")

    tasks =
      from(t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board.id,
        where: not is_nil(t.completed_at) or not is_nil(t.claimed_at),
        select: {t.title, t.inserted_at, t.claimed_at, t.completed_at}
      )
      |> Repo.all()

    assert length(tasks) > 30

    for {title, inserted, claimed, completed} <- tasks do
      inserted = DateTime.from_naive!(inserted, "Etc/UTC")

      if completed do
        assert DateTime.compare(inserted, completed) == :lt,
               "#{title} was completed before it was created"
      end

      if claimed do
        assert DateTime.compare(inserted, claimed) == :lt,
               "#{title} was claimed before it was created"
      end
    end
  end

  test "a board that fails part-way is rolled back, not left half-built" do
    priya = Kanban.AccountsFixtures.user_fixture(%{email: "priya.raman@example.test"})

    from(u in User, where: u.id == ^priya.id)
    |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

    boards_before = Repo.aggregate(Board, :count)

    assert_raise RuntimeError, ~r/to Checkout Revamp: :user_disabled/, fn ->
      run_seed()
    end

    assert Repo.aggregate(Board, :count) == boards_before
    refute from(b in Board, where: b.name == "Checkout Revamp") |> Repo.exists?()
    refute from(l in Label, where: l.name == "Payments") |> Repo.exists?()
  end

  test "adds an existing viewer to both demo boards when asked" do
    viewer = Kanban.AccountsFixtures.user_fixture()
    System.put_env("RESOURCES_DEMO_VIEWER", viewer.email)
    on_exit(fn -> System.delete_env("RESOURCES_DEMO_VIEWER") end)

    run_seed()
    assert_received {:summary, %{viewer_member_of: ["Checkout Revamp", "Marketing Site Launch"]}}

    for name <- ["Checkout Revamp", "Marketing Site Launch"] do
      board = demo_board(name)
      assert Repo.get_by(BoardUser, board_id: board.id, user_id: viewer.id).access == :modify
    end
  end

  test "reports no viewer membership when the free-board member cap stops the add" do
    Kanban.PlansHelpers.enforce_plans()
    viewer = Kanban.AccountsFixtures.user_fixture()
    System.put_env("RESOURCES_DEMO_VIEWER", viewer.email)
    on_exit(fn -> System.delete_env("RESOURCES_DEMO_VIEWER") end)

    output = run_seed()

    assert_received {:summary, %{viewer: email, viewer_member_of: []}}
    assert email == viewer.email
    assert output =~ "member cap is reached"
    refute Repo.get_by(BoardUser, board_id: demo_board("Checkout Revamp").id, user_id: viewer.id)
  end
end
