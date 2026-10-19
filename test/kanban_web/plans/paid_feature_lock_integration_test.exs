defmodule KanbanWeb.Plans.PaidFeatureLockIntegrationTest do
  @moduledoc """
  Every entry point to a paid feature, driven end to end in three modes:

    * `:free` - enforcement on and a board in the owner's personal workspace.
      Every probe must come back `:locked`.
    * `:paid` - enforcement on and the board in an Organization the owner
      belongs to. Every probe must come back `:unlocked`.
    * `:off` - enforcement turned on and then off again for the same free
      board. Every probe must come back `:unlocked`.

  The probes, and what `:locked`, `:unlocked` and `:neither` mean for each,
  are in `KanbanWeb.PlansProbes`. A lock removed from any single entry point
  turns its `:free` outcome into `:unlocked`, or into `:neither` when a lock
  further down still refuses, so this suite fails either way.

  The API token, the queued notification and the delivery job arguments are
  all created in the module setup, before the mode is applied, so the suite
  also covers work that existed before enforcement was turned on. The unit
  suites for each lock (W2405 to W2410) hold the detailed assertions; this
  suite keeps to one observable outcome per action.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.WebhooksFixtures

  import KanbanWeb.PlansProbes,
    only: [
      api_conn: 1,
      completed_last_week: 1,
      delivery_args: 2,
      digest_now: 0,
      expected: 2,
      flush_emails: 0,
      probe: 2
    ]

  import Swoosh.TestAssertions

  alias Kanban.Accounts.UserNotifier
  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Notifications.DigestWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.PlansProbes

  @moduletag capture_log: true

  @modes [
    free: "a free board under enforcement",
    paid: "a paid board under enforcement",
    off: "a free board with enforcement turned off"
  ]

  setup :register_and_log_in_user

  setup %{user: user} do
    board =
      user
      |> ai_optimized_board_fixture()
      |> Ecto.Changeset.change(field_visibility: %{"observability" => true})
      |> Repo.update!()

    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    task = task_fixture(cols["Ready"], %{title: "Probe task", status: :open})
    completed_last_week(cols["Done"])

    member = user_fixture()
    {:ok, _} = Boards.add_user_to_board(board, member, :modify, user)

    endpoint =
      webhook_endpoint_fixture(board,
        url: "https://hooks.example.com/stride",
        event_types: ["task.created", "task.moved"]
      )

    {:ok, {_token, plain_token}} =
      ApiTokens.create_api_token(user, board, %{
        "name" => "Lock suite token",
        "agent_capabilities" => ["code_generation"]
      })

    Repo.delete_all(Notification)
    Repo.delete_all(Oban.Job)

    # Inserted directly rather than through notify/3, so the row stands for a
    # notification created before enforcement whatever the plan checks say.
    queued =
      Repo.insert!(%Notification{
        user_id: member.id,
        board_id: board.id,
        event_type: :review_requested,
        title: "W1 is ready for review",
        url_path: "/review"
      })

    %{
      board: board,
      cols: cols,
      task: task,
      member: member,
      endpoint: endpoint,
      token: plain_token,
      queued_notification: queued,
      delivery_args: delivery_args(endpoint, task)
    }
  end

  # The owner of a paid board belongs to its Organization as an org-admin,
  # which also gives them paid access and the audit export.
  defp apply_mode(:free, _ctx), do: enforce_plans()

  defp apply_mode(:paid, %{board: board, user: user}) do
    organization = organization_fixture()
    paid = move_board_to_organization(board, organization)
    organization_member_fixture(organization, user, :org_admin)
    true = Plans.paid_board?(paid)
    enforce_plans()
  end

  defp apply_mode(:off, _ctx) do
    enforce_plans()
    Application.put_env(:kanban, :plans_enforced, false)
  end

  # ── The matrix: every probe in every mode ──────────────────────────

  for {mode, mode_name} <- @modes do
    describe mode_name do
      @describetag mode: mode

      setup ctx do
        apply_mode(ctx.mode, ctx)
        :ok
      end

      for {probe, probe_name} <- PlansProbes.probes() do
        @tag probe: probe
        test "#{probe_name} #{if mode == :free, do: "is locked", else: "works"}", ctx do
          outcomes = probe(ctx.probe, ctx)

          assert outcomes == expected(outcomes, ctx.mode)
        end
      end
    end
  end

  # ── Entry points that do not depend on the board's plan ────────────

  describe "a free board under enforcement keeps" do
    setup :enforce_plans

    test "REST claim and complete", %{token: token, task: task, cols: cols} do
      hook = %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}

      claimed =
        token
        |> api_conn()
        |> post(~p"/api/tasks/claim", %{"before_doing_result" => hook})
        |> json_response(200)

      assert claimed["data"]["id"] == task.id
      assert claimed["data"]["status"] == "in_progress"

      completed =
        token
        |> api_conn()
        |> patch(~p"/api/tasks/#{task.id}/complete", %{
          "completion_summary" => "Done",
          "actual_complexity" => "small",
          "actual_files_changed" => "1",
          "time_spent_minutes" => 5,
          "after_doing_result" => hook,
          "before_review_result" => hook
        })
        |> json_response(200)

      assert completed["data"]["id"] == task.id
      refute Repo.get!(Task, task.id).column_id == cols["Doing"].id
    end

    test "account emails for a user outside any Organization", %{user: user} do
      refute Plans.user_has_paid_access?(user)
      flush_emails()

      assert {:ok, _} =
               UserNotifier.deliver_confirmation_instructions(user, "https://example.test/c")

      assert_email_sent(to: [{"", user.email}])

      assert {:ok, _} =
               UserNotifier.deliver_reset_password_instructions(user, "https://example.test/r")

      assert_email_sent(to: [{"", user.email}])
    end

    test "the lock prompt's link, which sends every board feature to the contact form",
         %{conn: conn} do
      for feature <- ~w(notifications bulk_actions integrations telemetry mcp) do
        assert conn |> get(~p"/locked/#{feature}") |> redirected_to() == "/pricing#contact",
               "/locked/#{feature} did not lead to the contact form"
      end
    end
  end

  describe "the org audit export" do
    test "refuses a user outside any Organization, with or without enforcement",
         %{conn: conn} do
      enforce_plans()
      assert conn |> get(~p"/org/audit/export") |> redirected_to() == ~p"/boards"

      Application.put_env(:kanban, :plans_enforced, false)
      assert conn |> get(~p"/org/audit/export") |> redirected_to() == ~p"/boards"
    end

    test "downloads for the org-admin of a paid board's Organization", %{conn: conn} = ctx do
      apply_mode(:paid, ctx)

      conn = get(conn, ~p"/org/audit/export")

      assert response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/csv"
    end
  end

  describe "a weekly digest under enforcement" do
    setup :enforce_plans

    test "leaves out a free board for a user who also has a paid board", %{user: user} = ctx do
      paid = ai_optimized_board_fixture(user, %{name: "Paid digest board"})
      move_board_to_organization(paid, organization_fixture())
      paid |> Columns.list_columns() |> Enum.find(&(&1.name == "Done")) |> completed_last_week()
      flush_emails()

      :ok =
        perform_job(DigestWorker, %{
          user_id: user.id,
          week: "2026-W45",
          now: DateTime.to_iso8601(digest_now())
        })

      assert_received {:email, %{text_body: body}}
      assert body =~ "Paid digest board"
      refute body =~ ctx.board.name
    end
  end

  describe "a free board moved into an Organization under enforcement" do
    setup :enforce_plans

    test "unlocks on the next request, job and event", ctx do
      for probe <- [:rest_telemetry, :delivery_worker] do
        outcomes = probe(probe, ctx)
        assert outcomes == expected(outcomes, :free), "#{probe} was not locked"
      end

      move_board_to_organization(ctx.board, organization_fixture())

      for probe <- [:rest_telemetry, :delivery_worker, :mcp, :notification_email] do
        outcomes = probe(probe, ctx)
        assert outcomes == expected(outcomes, :paid), "#{probe} did not unlock"
      end
    end
  end
end
