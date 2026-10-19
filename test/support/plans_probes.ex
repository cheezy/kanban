defmodule KanbanWeb.PlansProbes do
  @moduledoc """
  Probes for `KanbanWeb.Plans.PaidFeatureLockIntegrationTest`. Each one
  drives a single entry point to a paid feature (a LiveView event, a REST or
  MCP request, a context call or an Oban job) and reports one outcome per
  action it tried:

    * `:unlocked` - the action took effect.
    * `:locked` - it did not, and the entry point said why: a flash with a
      `:live_view` refusal event, a REST `warnings` list, the JSON-RPC
      `plan_required` error, a `{:plan_required, feature}` tuple, or a job
      that left its row or endpoint untouched.
    * `:neither` - it did not take effect and nothing said why.

  `digest_fanout` is the one probe with no refusal signal, because the
  recipient query simply leaves the user out. It reports `:locked` whenever
  nothing was queued, and its `:paid` and `:off` runs prove its setup.

  A probe takes the test context built by the suite's setup: `conn`, `user`,
  `board`, `cols`, `task`, `member`, `endpoint`, `token`,
  `queued_notification` and `delivery_args`.
  """

  use KanbanWeb, :verified_routes
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Kanban.Accounts.Scope
  alias Kanban.Notifications
  alias Kanban.Notifications.DigestFanoutWorker
  alias Kanban.Notifications.DigestWorker
  alias Kanban.Notifications.EmailWorker
  alias Kanban.Notifications.Notification
  alias Kanban.Notifications.Preference
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Events
  alias Kanban.Webhooks.Payload
  alias Kanban.Webhooks.Transport
  alias KanbanWeb.MCP.JsonRpc

  @endpoint KanbanWeb.Endpoint

  @refused [:kanban, :plan, :feature_refused]
  @bulk_locked "Bulk actions are available to organizations. Nothing was changed."
  @integrations_locked "Integrations are available to organizations. Nothing was changed."
  @preferences_locked "Notification settings are available to organizations."
  @plan_required {:error, {:plan_required, :integrations}}
  @endpoint_params %{
    "kind" => "generic",
    "url" => "https://hooks.example.com/stride/new",
    "event_types" => ["task.created"]
  }
  @telemetry %{"telemetry_event" => "[:kanban, :probe]", "metrics_to_track" => "probe count"}

  # Monday of ISO week 2026-W45; the digest window is 2026-10-26 to 2026-11-02.
  @digest_now ~U[2026-11-02 13:00:00Z]

  @probes [
    bulk_live_view: "bulk_ events in the board LiveView",
    bulk_context: "Tasks.bulk_archive_tasks/3",
    integrations_live_view: "Integrations create, save_edit, send_test, rotate and toggle events",
    integrations_context: "Webhooks create, update, rotate and send-test calls",
    task_form: "the task form's telemetry fields",
    notification_preferences: "notification preference updates in /users/notifications",
    rest_telemetry: "REST create, batch and update with telemetry fields",
    mcp: "MCP initialize and tools/call",
    notification_email: "the notification email for a board event",
    email_worker: "EmailWorker for a notification queued before enforcement",
    digest_fanout: "DigestFanoutWorker's weekly recipient list",
    digest_worker: "DigestWorker for the board's weekly activity",
    webhook_events: "Webhooks.Events.emit/3 for a board event",
    delivery_worker: "Webhooks.DeliveryWorker for a delivery queued before enforcement"
  ]

  @doc "Every probe as `{name, description}`, in the order the suite runs them."
  def probes, do: @probes

  @doc "The `now` the digest probes run at."
  def digest_now, do: @digest_now

  @doc """
  The outcomes a probe must report in `mode`: all `:locked` for `:free`,
  all `:unlocked` otherwise.
  """
  def expected(outcomes, :free), do: Enum.map(outcomes, fn {action, _} -> {action, :locked} end)
  def expected(outcomes, _mode), do: Enum.map(outcomes, fn {action, _} -> {action, :unlocked} end)

  @doc "Adds a task to `column`, completed inside the digest window."
  def completed_last_week(column) do
    task = task_fixture(column, %{title: "Shipped last week"})

    Task
    |> where(id: ^task.id)
    |> Repo.update_all(set: [completed_at: ~U[2026-10-30 10:00:00Z]])
  end

  @doc "The job arguments of a `task.moved` delivery to `endpoint`."
  def delivery_args(endpoint, task) do
    {:ok, payload} = Payload.build("task.moved", task)

    %{
      "endpoint_id" => endpoint.id,
      "delivery_id" => "dlv-lock-suite",
      "event" => "task.moved",
      "payload" => payload |> Jason.encode!() |> Jason.decode!()
    }
  end

  @doc "Drops the emails waiting in the mailbox; `user_fixture/1` sends one."
  def flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  @doc "A fresh conn that authenticates with the API `token`."
  def api_conn(token, accept \\ "application/json") do
    build_conn()
    |> put_req_header("accept", accept)
    |> put_req_header("authorization", "Bearer #{token}")
  end

  # ── Outcomes ───────────────────────────────────────────────────────

  defp outcome(true = _took_effect?, _refused?), do: :unlocked
  defp outcome(false, true), do: :locked
  defp outcome(false, false), do: :neither

  # Takes one plan refusal for `surface` off the mailbox, so a probe can tell
  # the lock at its own entry point from a lock further down.
  defp refused_on?(surface) do
    receive do
      {:telemetry_event, @refused, _measurements, %{surface: ^surface}} -> true
    after
      0 -> false
    end
  end

  defp email_sent_to?(user) do
    receive do
      {:email, %{to: to}} -> Enum.any?(to, fn {_name, address} -> address == user.email end)
    after
      0 -> false
    end
  end

  # ── Probes ─────────────────────────────────────────────────────────

  @doc "Runs the probe `name` against the suite's test context."
  def probe(:bulk_live_view, %{conn: conn, board: board, task: task}) do
    view = live_with_refusals(conn, ~p"/boards/#{board}")

    render_hook(view, "bulk_toggle_mode", %{})
    render_hook(view, "bulk_toggle", %{"id" => to_string(task.id)})
    refused? = render_hook(view, "bulk_archive", %{}) =~ @bulk_locked

    [bulk_archive: outcome(archived?(task), refused? and refused_on?(:live_view))]
  end

  def probe(:bulk_context, %{user: user, board: board, task: task}) do
    result = user |> Scope.for_user() |> Tasks.bulk_archive_tasks(board, [task.id])
    refused? = result == {:error, {:plan_required, :bulk_actions}}

    [archive: outcome(match?({:ok, %{count: 1}}, result), refused?)]
  end

  def probe(:integrations_live_view, %{conn: conn, board: board, endpoint: endpoint}) do
    view = live_with_refusals(conn, ~p"/boards/#{board}/integrations")
    target = with_target(view, "#board-integrations-#{board.id}")

    # Toggle runs last: it disables the endpoint, and send_test refuses a
    # disabled one.
    [
      create: live_create(view, target, board),
      save_edit: live_save_edit(view, target, endpoint),
      send_test: live_send_test(view, target, endpoint),
      rotate: live_rotate(view, target, endpoint),
      toggle: live_toggle(view, target, endpoint)
    ]
  end

  def probe(:integrations_context, %{user: user, board: board, endpoint: endpoint}) do
    scope = Scope.for_user(user)

    [
      create: Webhooks.create_endpoint(scope, board, @endpoint_params),
      update: Webhooks.update_endpoint(scope, endpoint, %{"event_types" => ["task.deleted"]}),
      rotate: Webhooks.rotate_secret(scope, Repo.get!(Endpoint, endpoint.id)),
      send_test: Webhooks.send_test_event(scope, endpoint)
    ]
    |> Enum.map(fn {action, result} ->
      {action, outcome(match?({:ok, _}, result), result == @plan_required)}
    end)
  end

  def probe(:task_form, %{conn: conn, board: board, task: task}) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")
    locked? = has_element?(view, ~s(#task-telemetry-locked [data-locked-feature="telemetry"]))

    view
    |> element("#task-form")
    |> render_submit(%{"task" => Map.put(@telemetry, "title", "Probe task")})

    [save: outcome(telemetry_stored?(task.id), locked?)]
  end

  def probe(:notification_preferences, %{conn: conn, user: user}) do
    {:ok, view, _html} = live(conn, ~p"/users/notifications")

    html =
      render_hook(view, "save", %{
        "event_type" => "review_requested",
        "in_app" => "true",
        "email" => "false"
      })

    saved? = Preference |> where(user_id: ^user.id) |> Repo.exists?()
    [save: outcome(saved?, html =~ @preferences_locked)]
  end

  def probe(:rest_telemetry, %{token: token, cols: cols, user: user}) do
    {:ok, existing} =
      Tasks.create_task(cols["Backlog"], %{"title" => "Existing", "created_by_id" => user.id})

    [create: rest_create(token), batch: rest_batch(token), update: rest_update(token, existing)]
  end

  def probe(:mcp, %{token: token, task: task}) do
    init = mcp(token, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})
    claim = mcp(token, claim_request(task))
    claimed? = Repo.get!(Task, task.id).status == :in_progress

    [
      initialize: outcome(Map.has_key?(init, "result"), plan_required?(init)),
      tools_call: outcome(claimed?, plan_required?(claim))
    ]
  end

  def probe(:notification_email, %{board: board, member: member}) do
    flush_emails()

    {:ok, rows} =
      Notifications.notify(:review_requested, [member], %{
        title: "W1 is ready for review",
        url_path: "/review",
        board_id: board.id
      })

    for job <- all_enqueued(worker: EmailWorker), do: perform_job(EmailWorker, job.args)

    [email: outcome(email_sent_to?(member), rows == [])]
  end

  def probe(:email_worker, %{queued_notification: notification, member: member}) do
    flush_emails()
    :ok = perform_job(EmailWorker, %{notification_id: notification.id})

    skipped? = Repo.get!(Notification, notification.id).emailed_at == nil
    [email: outcome(email_sent_to?(member), skipped?)]
  end

  def probe(:digest_fanout, %{user: user}) do
    :ok = perform_job(DigestFanoutWorker, %{now: DateTime.to_iso8601(@digest_now)})

    queued? =
      [worker: DigestWorker] |> all_enqueued() |> Enum.any?(&(&1.args["user_id"] == user.id))

    [fanout: if(queued?, do: :unlocked, else: :locked)]
  end

  def probe(:digest_worker, %{user: user}) do
    flush_emails()

    :ok =
      perform_job(DigestWorker, %{
        user_id: user.id,
        week: "2026-W45",
        now: DateTime.to_iso8601(@digest_now)
      })

    no_digest? = Notification |> where(event_type: :weekly_digest) |> Repo.all() == []
    [digest: outcome(email_sent_to?(user), no_digest?)]
  end

  def probe(:webhook_events, %{board: board, task: task, endpoint: endpoint}) do
    :ok = Events.emit(board.id, :task_moved, task)

    queued? =
      [worker: DeliveryWorker]
      |> all_enqueued()
      |> Enum.any?(&(&1.args["endpoint_id"] == endpoint.id))

    [emit: outcome(queued?, Repo.get!(Endpoint, endpoint.id).enabled)]
  end

  def probe(:delivery_worker, %{delivery_args: args, endpoint: endpoint}) do
    stub_transport()
    :ok = perform_job(DeliveryWorker, args)

    delivered? =
      receive do
        {:request, _conn} -> true
      after
        0 -> false
      end

    no_log? = Delivery |> where(endpoint_id: ^endpoint.id) |> Repo.all() == []
    [delivery: outcome(delivered?, no_log? and Repo.get!(Endpoint, endpoint.id).enabled)]
  end

  # ── Bulk and Integrations helpers ──────────────────────────────────

  # Mounts `path` with plan refusals forwarded to the test process.
  defp live_with_refusals(conn, path) do
    attach_telemetry(@refused)
    {:ok, view, _html} = live(conn, path)
    view
  end

  defp archived?(task), do: Repo.get!(Task, task.id).archived_at != nil

  # The flash renders in the board LiveView, not in the targeted component.
  defp integrations_refused?(view),
    do: render(view) =~ @integrations_locked and refused_on?(:live_view)

  defp endpoint_count(board),
    do: Endpoint |> where(board_id: ^board.id) |> Repo.aggregate(:count)

  defp live_create(view, target, board) do
    before = endpoint_count(board)
    render_submit(target, "create", %{"endpoint" => @endpoint_params})
    outcome(endpoint_count(board) == before + 1, integrations_refused?(view))
  end

  defp live_save_edit(view, target, endpoint) do
    render_submit(target, "save_edit", %{
      "id" => "#{endpoint.id}",
      "endpoint_edit" => %{"event_types" => ["task.deleted"]}
    })

    edited? = Repo.get!(Endpoint, endpoint.id).event_types == ["task.deleted"]
    outcome(edited?, integrations_refused?(view))
  end

  defp live_send_test(view, target, endpoint) do
    render_click(target, "send_test", %{"id" => "#{endpoint.id}"})

    queued? =
      [worker: DeliveryWorker] |> all_enqueued() |> Enum.any?(&(&1.args["event"] == "ping"))

    outcome(queued?, integrations_refused?(view))
  end

  defp live_rotate(view, target, endpoint) do
    render_click(target, "rotate", %{"id" => "#{endpoint.id}"})

    rotated? = Repo.get!(Endpoint, endpoint.id).encrypted_secret != endpoint.encrypted_secret
    outcome(rotated?, integrations_refused?(view))
  end

  defp live_toggle(view, target, endpoint) do
    render_click(target, "toggle", %{"id" => "#{endpoint.id}"})

    outcome(not Repo.get!(Endpoint, endpoint.id).enabled, integrations_refused?(view))
  end

  # ── REST and MCP helpers ───────────────────────────────────────────

  defp telemetry_stored?(id) do
    Task
    |> Repo.get!(id)
    |> Map.take([:telemetry_event, :metrics_to_track])
    |> Kernel.==(%{telemetry_event: "[:kanban, :probe]", metrics_to_track: "probe count"})
  end

  defp rest_outcome(body, task_ids),
    do: outcome(Enum.all?(task_ids, &telemetry_stored?/1), Map.has_key?(body, "warnings"))

  defp rest_work, do: Map.merge(%{"title" => "REST probe", "type" => "work"}, @telemetry)

  defp rest_create(token) do
    body = token |> api_conn() |> post(~p"/api/tasks", task: rest_work()) |> json_response(201)
    rest_outcome(body, [body["data"]["id"]])
  end

  defp rest_batch(token) do
    goal = %{"title" => "Batch probe", "type" => "goal", "tasks" => [rest_work()]}
    body = token |> api_conn() |> post(~p"/api/tasks/batch", goals: [goal]) |> json_response(201)
    [%{"goal" => %{"id" => goal_id}}] = body["goals"]
    child_ids = Task |> where(parent_id: ^goal_id) |> select([t], t.id) |> Repo.all()
    rest_outcome(body, child_ids)
  end

  defp rest_update(token, task) do
    token
    |> api_conn()
    |> patch(~p"/api/tasks/#{task.id}", task: @telemetry)
    |> json_response(200)
    |> rest_outcome([task.id])
  end

  defp mcp(token, body) do
    token
    |> api_conn("application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp", Jason.encode!(body))
    |> json_response(200)
  end

  defp claim_request(task) do
    %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "stride_claim_task",
        "arguments" => %{
          "identifier" => task.identifier,
          "agent_name" => "Lock suite agent",
          "before_doing_result" => %{"exit_code" => 0, "output" => "ok", "duration_ms" => 1}
        }
      }
    }
  end

  defp plan_required?(response),
    do: get_in(response, ["error", "code"]) == JsonRpc.plan_required()

  defp stub_transport do
    test = self()

    Req.Test.stub(Transport, fn conn ->
      send(test, {:request, conn})
      Plug.Conn.send_resp(conn, 200, "ok")
    end)
  end
end
