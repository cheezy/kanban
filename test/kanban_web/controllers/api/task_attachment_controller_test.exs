defmodule KanbanWeb.API.TaskAttachmentControllerTest do
  @moduledoc """
  `GET /api/tasks/:id/attachments/:attachment_id` (W2517): the bytes, the
  headers, and the check order — token, board read access, plan, rate limit,
  task, attachment, stored object — each with its own status.
  """
  # Not async: tests point the application-wide storage adapter and local
  # storage root at their own, switch plan enforcement on and turn the rate
  # limiter back on.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.Storage.Local
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Tasks.TaskComment
  alias KanbanWeb.API.TaskAttachmentController

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @refused [:kanban, :plan, :feature_refused]
  @api_downloaded [:kanban, :api, :attachment_downloaded]
  @context_downloaded [:kanban, :attachment, :downloaded]
  @not_found_body %{"error" => "Attachment not found"}
  @plan_required_body %{
    "error" => "plan_required",
    "feature" => "attachments",
    "message" => "Attachments are available to boards in an Organization."
  }

  defmodule StreamAdapter do
    @moduledoc false
    # Delegates to the local adapter, letting a test replace the result of
    # stream/1. The controller runs in the test process under ConnTest, so
    # the process dictionary is the test's own.
    @behaviour Kanban.Attachments.Storage

    alias Kanban.Attachments.Storage.Local

    @impl true
    def put(key, source, opts), do: Local.put(key, source, opts)

    @impl true
    def stream(key), do: Process.get(:stream_result) || Local.stream(key)

    @impl true
    def delete(key), do: Local.delete(key)

    @impl true
    def exists(key), do: Local.exists(key)
  end

  setup %{tmp_dir: tmp_dir} do
    restore_env_on_exit(Storage)
    restore_env_on_exit(Local)
    restore_env_on_exit(Kanban.RateLimit)
    Application.put_env(:kanban, Storage, adapter: StreamAdapter)
    Application.put_env(:kanban, Local, root: Path.join(tmp_dir, "root"))

    owner = user_fixture()
    board = ai_optimized_board_fixture(owner)
    workspace = make_paid(board)
    enforce_plans()

    {:ok, {api_token, plain}} =
      ApiTokens.create_api_token(owner, board, %{
        "name" => "Downloads",
        "agent_capabilities" => ["code_generation"]
      })

    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))

    %{
      owner: owner,
      board: board,
      workspace: workspace,
      api_token: api_token,
      plain: plain,
      ready: ready,
      task: task_fixture(ready)
    }
  end

  defp restore_env_on_exit(key) do
    previous = Application.fetch_env(:kanban, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kanban, key, value)
        :error -> Application.delete_env(:kanban, key)
      end
    end)
  end

  defp make_paid(%Board{id: id}) do
    workspace = org_workspace_fixture(organization_fixture())

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    workspace
  end

  defp limit_downloads(id_limit) do
    Application.put_env(:kanban, Kanban.RateLimit,
      enabled: true,
      attachment_download: %{scale_ms: 60_000, id_limit: id_limit}
    )
  end

  # An attachment row with its bytes in storage.
  defp stored(task, attrs, bytes) do
    attachment = attachment_fixture(task, Map.put(attrs, :byte_size, byte_size(bytes)))
    :ok = Storage.put(attachment.storage_key, {:binary, bytes})
    attachment
  end

  defp api_conn(plain, accept \\ "*/*") do
    build_conn()
    |> put_req_header("accept", accept)
    |> put_req_header("authorization", "Bearer #{plain}")
  end

  defp download_path(task, attachment_id),
    do: ~p"/api/tasks/#{task_ref(task)}/attachments/#{attachment_id}"

  defp task_ref(%{id: id}), do: id
  defp task_ref(ref), do: ref

  defp download(ctx, task, attachment_id),
    do: ctx.plain |> api_conn() |> get(download_path(task, attachment_id))

  defp header(conn, name), do: get_resp_header(conn, name)

  defp free_board_task(ctx) do
    board = ai_optimized_board_fixture(ctx.owner)

    {:ok, {_token, plain}} =
      ApiTokens.create_api_token(ctx.owner, board, %{"name" => "Free board"})

    ready = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Ready"))
    %{plain: plain, task: task_fixture(ready)}
  end

  describe "a successful download" do
    test "streams the bytes with attachment disposition, nosniff and the stored content type",
         ctx do
      bytes = :crypto.strong_rand_bytes(200_000)

      pdf =
        stored(ctx.task, %{filename: "Q3 report.pdf", content_type: "application/pdf"}, bytes)

      conn = download(ctx, ctx.task, pdf.id)

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == bytes
      assert header(conn, "content-length") == ["200000"]
      assert header(conn, "content-type") == ["application/pdf"]

      assert header(conn, "content-disposition") ==
               ["attachment; filename=\"Q3 report.pdf\"; filename*=UTF-8''Q3%20report.pdf"]

      assert header(conn, "x-content-type-options") == ["nosniff"]
      assert header(conn, "cache-control") == ["private, no-store"]

      assert header(conn, "content-security-policy") ==
               ["default-src 'none'; frame-ancestors 'none'; sandbox"]

      off_list = stored(ctx.task, %{content_type: "application/x-msdownload"}, "MZ")
      conn = download(ctx, ctx.task, off_list.id)

      assert conn.status == 200
      assert header(conn, "content-type") == ["application/octet-stream"]
    end

    test "a one-byte attachment streams exactly one byte", ctx do
      attachment = stored(ctx.task, %{}, "x")

      conn = download(ctx, ctx.task, attachment.id)

      assert conn.status == 200
      assert conn.resp_body == "x"
      assert header(conn, "content-length") == ["1"]
    end

    test "the task may be named by its identifier", ctx do
      attachment = stored(ctx.task, %{}, "by identifier")

      conn = download(ctx, ctx.task.identifier, attachment.id)

      assert conn.status == 200
      assert conn.resp_body == "by identifier"
    end

    test "an attachment on a comment of the task downloads", ctx do
      comment = Repo.insert!(%TaskComment{task_id: ctx.task.id, content: "Here is the log"})
      attachment = stored(ctx.task, %{comment: comment}, "comment file")

      conn = download(ctx, ctx.task, attachment.id)

      assert conn.status == 200
      assert conn.resp_body == "comment file"
    end

    test "content-disposition sanitizes quotes, control characters and non-ASCII filenames",
         ctx do
      name = "a\"b\r\nX-Injected: 1;c/d\\e 🚀.txt"
      attachment = stored(ctx.task, %{filename: name}, "named")

      conn = download(ctx, ctx.task, attachment.id)

      assert conn.status == 200
      assert header(conn, "x-injected") == []
      assert [disposition] = header(conn, "content-disposition")
      refute disposition =~ "\r"
      refute disposition =~ "\n"

      assert [_, ascii] =
               Regex.run(~r/\Aattachment; filename="([^"]*)"; filename\*=/, disposition)

      assert ascii =~ ~r/\A[A-Za-z0-9._ -]+\z/

      assert [_, star] = Regex.run(~r/filename\*=UTF-8''(\S+)\z/, disposition)
      assert star =~ ~r/\A[A-Za-z0-9._~%-]+\z/
      assert URI.decode(star) =~ "🚀"
    end

    test "a workspace token naming the board with X-Stride-Board can download", ctx do
      admin = user_fixture()

      organization_member_fixture(
        Repo.preload(ctx.workspace, :organization).organization,
        admin,
        :org_admin
      )

      {:ok, {_, plain}} =
        ApiTokens.create_workspace_api_token(admin, ctx.workspace, %{
          name: "Fleet",
          agent_capabilities: ["code_generation"]
        })

      attachment = stored(ctx.task, %{}, "fleet")

      conn =
        plain
        |> api_conn()
        |> put_req_header("x-stride-board", Integer.to_string(ctx.board.id))
        |> get(download_path(ctx.task, attachment.id))

      assert conn.status == 200
      assert conn.resp_body == "fleet"

      conn = plain |> api_conn() |> get(download_path(ctx.task, attachment.id))

      assert conn.status == 400
      refute conn.resp_body =~ "fleet"
    end

    test "the download_url rendered in the task JSON routes to this action", ctx do
      attachment = stored(ctx.task, %{}, "linked")

      body =
        ctx.plain
        |> api_conn("application/json")
        |> get(~p"/api/tasks/#{ctx.task.id}")
        |> json_response(200)

      assert [%{"id" => id, "download_url" => url}] = body["data"]["attachments"]
      assert id == attachment.id

      conn = ctx.plain |> api_conn() |> get(url)

      assert conn.status == 200
      assert conn.resp_body == "linked"
      assert conn.private.phoenix_controller == TaskAttachmentController
      assert conn.private.phoenix_action == :download
    end

    test "a HEAD gets the headers and no body", ctx do
      attachment = stored(ctx.task, %{content_type: "image/png"}, "png bytes")
      attach_telemetry(@api_downloaded)

      conn = ctx.plain |> api_conn() |> head(download_path(ctx.task, attachment.id))

      assert conn.status == 200
      assert conn.resp_body == ""
      assert header(conn, "content-type") == ["image/png"]
      assert header(conn, "content-length") == ["9"]
      refute_received {:telemetry_event, @api_downloaded, _, _}
    end

    test "emits [:kanban, :api, :attachment_downloaded] with task_id and attachment_id", ctx do
      attachment = stored(ctx.task, %{}, "counted")
      missing_blob = attachment_fixture(ctx.task)
      attach_telemetry(@api_downloaded)

      assert download(ctx, ctx.task, attachment.id).status == 200

      assert_received {:telemetry_event, @api_downloaded, %{count: 1}, metadata}
      assert metadata.task_id == ctx.task.id
      assert metadata.attachment_id == attachment.id
      assert metadata.board_id == ctx.board.id
      assert metadata.user_id == ctx.owner.id

      assert download(ctx, ctx.task, missing_blob.id).status == 404
      Process.put(:stream_result, {:error, :storage_unavailable})
      assert download(ctx, ctx.task, attachment.id).status == 503
      assert download(ctx, ctx.task, "abc").status == 404
      refute_received {:telemetry_event, @api_downloaded, _, _}
    end
  end

  describe "authentication and board access" do
    test "returns 401 without a token", ctx do
      attachment = stored(ctx.task, %{}, "secret")

      conn =
        build_conn()
        |> put_req_header("accept", "*/*")
        |> get(download_path(ctx.task, attachment.id))

      assert conn.status == 401
      refute conn.resp_body =~ "secret"
    end

    test "returns 403 not_authorized when the board token's user lost board access", ctx do
      member = user_fixture()
      Repo.insert!(%BoardUser{board_id: ctx.board.id, user_id: member.id, access: :modify})
      {:ok, {_, plain}} = ApiTokens.create_api_token(member, ctx.board, %{name: "Member"})
      attachment = stored(ctx.task, %{}, "secret")

      {1, _} =
        BoardUser |> where(board_id: ^ctx.board.id, user_id: ^member.id) |> Repo.delete_all()

      attach_telemetry(@refused)

      conn = plain |> api_conn() |> get(download_path(ctx.task, attachment.id))

      assert conn.status == 403
      {:forbidden, :not_authorized, body} = KanbanWeb.API.TaskErrors.error_body(:not_authorized)
      assert Jason.decode!(conn.resp_body) == body |> Jason.encode!() |> Jason.decode!()
      refute conn.resp_body =~ "secret"
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "returns 406 for Accept application/octet-stream", ctx do
      attachment = stored(ctx.task, %{}, "bytes")

      assert {406, _headers, _body} =
               assert_error_sent(406, fn ->
                 ctx.plain
                 |> api_conn("application/octet-stream")
                 |> get(download_path(ctx.task, attachment.id))
               end)
    end
  end

  describe "the plan gate" do
    test "returns 403 plan_required on a free board under enforcement before any lookup", ctx do
      free = free_board_task(ctx)
      attachment = stored(free.task, %{}, "locked")

      for {task_ref, attachment_id} <- [
            {free.task.id, attachment.id},
            {999_999_999, 999_999_999},
            {free.task.id, "abc"}
          ] do
        conn = free.plain |> api_conn() |> get(download_path(task_ref, attachment_id))

        assert conn.status == 403
        assert Jason.decode!(conn.resp_body) == @plan_required_body
      end
    end

    test "a free board under enforcement emits exactly one feature_refused event", ctx do
      free = free_board_task(ctx)
      attachment = stored(free.task, %{}, "locked")
      attach_telemetry(@refused)

      conn = free.plain |> api_conn() |> get(download_path(free.task, attachment.id))

      assert conn.status == 403

      assert_received {:telemetry_event, @refused, %{count: 1},
                       %{feature: :attachments, surface: :rest}}

      refute_received {:telemetry_event, @refused, _, _}
    end

    test "plans enforcement off: a free board downloads with no refusal", ctx do
      free = free_board_task(ctx)
      attachment = stored(free.task, %{}, "unlocked")
      Application.put_env(:kanban, :plans_enforced, false)
      attach_telemetry(@refused)

      conn = free.plain |> api_conn() |> get(download_path(free.task, attachment.id))

      assert conn.status == 200
      assert conn.resp_body == "unlocked"
      refute_received {:telemetry_event, @refused, _, _}
    end

    test "a plan-refused request does not consume the download limit", ctx do
      free = free_board_task(ctx)
      attachment = stored(free.task, %{}, "locked")
      limit_downloads(1)

      for _ <- 1..3 do
        assert (free.plain |> api_conn() |> get(download_path(free.task, attachment.id))).status ==
                 403
      end

      Application.put_env(:kanban, :plans_enforced, false)

      assert (free.plain |> api_conn() |> get(download_path(free.task, attachment.id))).status ==
               200
    end
  end

  describe "lookups" do
    test "returns 404 Task not found for a task on another board", ctx do
      other = ai_optimized_board_fixture(user_fixture())
      other_task = other |> Columns.list_columns() |> hd() |> task_fixture()
      attachment = stored(other_task, %{}, "elsewhere")

      # Identifiers are numbered per board, so another board's task is named by
      # its id here; "W999999" names no task on this board.
      for task_ref <- [other_task.id, 999_999_999, "W999999"] do
        conn = download(ctx, task_ref, attachment.id)

        assert conn.status == 404
        assert Jason.decode!(conn.resp_body) == %{"error" => "Task not found"}
      end
    end

    test "returns 404 Attachment not found for an attachment of another task on the same board",
         ctx do
      other_task = task_fixture(ctx.ready)
      attachment = stored(other_task, %{}, "sibling")
      attach_telemetry([@api_downloaded, @context_downloaded])

      conn = download(ctx, ctx.task, attachment.id)

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == @not_found_body
      refute_received {:telemetry_event, _, _, _}
    end

    test "returns 404 Attachment not found for a non-numeric or out-of-range attachment_id",
         ctx do
      handler = {__MODULE__, :queries, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler,
        [:kanban, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:query, metadata[:source]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      for id <- ["0", "-1", "1.5", "abc", "9223372036854775808"] do
        conn = download(ctx, ctx.task, id)

        assert conn.status == 404, id
        assert Jason.decode!(conn.resp_body) == @not_found_body, id
      end

      refute_received {:query, "task_attachments"}

      conn = download(ctx, ctx.task, 999_999_999)
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == @not_found_body
    end

    test "returns 404 and logs no storage key when the blob is missing from storage", ctx do
      attachment = attachment_fixture(ctx.task)

      log =
        capture_log(fn ->
          conn = download(ctx, ctx.task, attachment.id)

          assert conn.status == 404
          assert Jason.decode!(conn.resp_body) == @not_found_body
          assert header(conn, "content-disposition") == []
          refute conn.resp_body =~ attachment.storage_key
        end)

      assert log =~ "attachment_id=#{attachment.id} reason=:not_found"
      refute log =~ attachment.storage_key
    end

    test "returns 503 when storage fails before the first byte", ctx do
      attachment = stored(ctx.task, %{}, "bytes")
      Process.put(:stream_result, {:error, :storage_unavailable})

      log =
        capture_log(fn ->
          conn = download(ctx, ctx.task, attachment.id)

          assert conn.status == 503

          assert Jason.decode!(conn.resp_body) == %{
                   "error" => "Attachment storage is unavailable. Try again later."
                 }

          assert header(conn, "content-disposition") == []

          for {_name, value} <- conn.resp_headers,
              do: refute(value =~ attachment.storage_key)
        end)

      assert log =~ "attachment_id=#{attachment.id} reason=:storage_unavailable"
      refute log =~ attachment.storage_key
    end
  end

  describe "the :attachment_download rate limit" do
    test "returns 429 with retry-after once the attachment_download limit is reached", ctx do
      attachment = stored(ctx.task, %{}, "bytes")
      limit_downloads(2)

      assert download(ctx, ctx.task, attachment.id).status == 200
      assert download(ctx, ctx.task, attachment.id).status == 200

      conn = download(ctx, ctx.task, attachment.id)

      assert conn.status == 429
      assert Jason.decode!(conn.resp_body) == %{"error" => "Too many requests"}
      assert [retry_after] = header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..61

      # The limit is per token: another token on the same board is unaffected.
      {:ok, {_, other}} = ApiTokens.create_api_token(ctx.owner, ctx.board, %{name: "Second"})
      assert (other |> api_conn() |> get(download_path(ctx.task, attachment.id))).status == 200
    end

    test "concurrent downloads with one token share one rate-limit bucket", ctx do
      attachment = stored(ctx.task, %{}, "bytes")
      limit_downloads(3)

      statuses =
        1..10
        |> Task.async_stream(fn _ -> download(ctx, ctx.task, attachment.id).status end,
          max_concurrency: 10
        )
        |> Enum.map(fn {:ok, status} -> status end)
        |> Enum.frequencies()

      assert statuses == %{200 => 3, 429 => 7}
    end
  end
end
