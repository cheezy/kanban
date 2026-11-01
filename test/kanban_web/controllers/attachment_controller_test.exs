defmodule KanbanWeb.AttachmentControllerTest do
  # Not async: tests point the application-wide storage adapter and local
  # storage root at their own, and switch plan enforcement on.
  use KanbanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.AttachmentsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.Storage.Local
  alias Kanban.Boards
  alias Kanban.Tasks.Comments

  @moduletag :tmp_dir

  @feature_refused [:kanban, :plan, :feature_refused]
  @raster ~w(image/png image/jpeg image/gif image/webp)

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
    Application.put_env(:kanban, Storage, adapter: StreamAdapter)
    Application.put_env(:kanban, Local, root: Path.join(tmp_dir, "root"))
    enforce_plans()

    owner = user_fixture()
    reader = user_fixture()
    organization = organization_fixture()
    board = owner |> board_fixture() |> move_board_to_organization(organization)
    join_board_organization(board, owner)
    join_board_organization(board, reader)
    {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)

    %{
      owner: owner,
      reader: reader,
      stranger: user_fixture(),
      board: board,
      task: board |> column_fixture() |> task_fixture()
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

  # An attachment row with its bytes in storage.
  defp stored(task, attrs, bytes) do
    attachment = attachment_fixture(task, Map.put(attrs, :byte_size, byte_size(bytes)))
    :ok = Storage.put(attachment.storage_key, {:binary, bytes})
    attachment
  end

  defp get_as(conn, user, path), do: conn |> log_in_user(user) |> get(path)

  defp download(conn, user, id), do: get_as(conn, user, ~p"/attachments/#{id}/download")
  defp preview(conn, user, id), do: get_as(conn, user, ~p"/attachments/#{id}/preview")

  defp header(conn, name), do: get_resp_header(conn, name)

  defp assert_not_found(conn) do
    assert conn.status == 404
    assert header(conn, "content-disposition") == []
    assert conn.resp_body =~ "Page Not Found"
  end

  test "a board member downloads a task attachment as an attachment", %{conn: conn} = ctx do
    bytes = :crypto.strong_rand_bytes(200_000)

    pdf =
      stored(ctx.task, %{filename: "Q3 report.pdf", content_type: "application/pdf"}, bytes)

    conn = download(conn, ctx.reader, pdf.id)

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == bytes
    assert header(conn, "content-type") == ["application/pdf"]

    assert header(conn, "content-disposition") ==
             ["attachment; filename=\"Q3 report.pdf\"; filename*=UTF-8''Q3%20report.pdf"]

    png = stored(ctx.task, %{filename: "shot.png", content_type: "image/png"}, "png bytes")
    conn = download(build_conn(), ctx.owner, png.id)

    assert conn.status == 200
    assert [disposition] = header(conn, "content-disposition")
    assert String.starts_with?(disposition, "attachment;")
  end

  test "a comment attachment uses the same access rules as its task", %{conn: conn} = ctx do
    {:ok, comment} =
      ctx.owner
      |> Scope.for_user()
      |> Comments.create_comment(ctx.task, %{"content" => "see the file"})

    attachment = stored(ctx.task, %{comment: comment}, "comment file")
    assert attachment.comment_id == comment.id

    conn = download(conn, ctx.reader, attachment.id)
    assert conn.status == 200
    assert conn.resp_body == "comment file"

    assert_not_found(download(build_conn(), ctx.stranger, attachment.id))
  end

  test "preview serves only png, jpeg, gif and webp inline", %{conn: conn} = ctx do
    for type <- @raster do
      image = stored(ctx.task, %{filename: "image", content_type: type}, "bytes of #{type}")
      conn = preview(conn, ctx.reader, image.id)

      assert conn.status == 200
      assert conn.resp_body == "bytes of #{type}"
      assert header(conn, "content-type") == [type]
      assert [disposition] = header(conn, "content-disposition")
      assert String.starts_with?(disposition, "inline; filename=")
    end

    for type <- ["image/svg+xml", "text/html", "application/pdf", "text/plain"] do
      file = stored(ctx.task, %{filename: "file", content_type: type}, "<svg onload=x>")
      assert_not_found(preview(conn, ctx.reader, file.id))
    end
  end

  test "sets nosniff, sandbox CSP, private no-store and same-origin resource policy headers",
       %{conn: conn} = ctx do
    pdf = stored(ctx.task, %{filename: "a.pdf", content_type: "application/pdf"}, "%PDF-1.4")
    png = stored(ctx.task, %{filename: "a.png", content_type: "image/png"}, "png")

    for served <- [download(conn, ctx.reader, pdf.id), preview(build_conn(), ctx.reader, png.id)] do
      assert served.status == 200
      assert header(served, "x-content-type-options") == ["nosniff"]
      assert header(served, "content-security-policy") == ["default-src 'none'; sandbox"]
      assert header(served, "cache-control") == ["private, no-store"]
      assert header(served, "cross-origin-resource-policy") == ["same-origin"]
    end

    svg = stored(ctx.task, %{filename: "x.svg", content_type: "image/svg+xml"}, "<svg/>")
    served = download(build_conn(), ctx.reader, svg.id)
    assert served.status == 200
    assert header(served, "content-type") == ["application/octet-stream"]

    hostile =
      stored(
        ctx.task,
        %{
          filename: "a\"b\r\nSet-Cookie: x=1#{<<0x202E::utf8>>}gpj.exe",
          content_type: "text/plain"
        },
        "text"
      )

    served = download(build_conn(), ctx.reader, hostile.id)
    assert served.status == 200
    assert [disposition] = header(served, "content-disposition")
    assert disposition =~ ~r/\A[\x20-\x7E]+\z/
    assert header(served, "set-cookie") |> Enum.all?(&(not String.starts_with?(&1, "x=1")))
  end

  test "outsiders, other boards, unknown and malformed ids get 404", %{conn: conn} = ctx do
    attachment = stored(ctx.task, %{content_type: "image/png", filename: "a.png"}, "png")

    other_owner = user_fixture()
    other_organization = organization_fixture()

    other_board =
      other_owner |> board_fixture() |> move_board_to_organization(other_organization)

    join_board_organization(other_board, other_owner)
    elsewhere = stored(other_board |> column_fixture() |> task_fixture(), %{}, "elsewhere")

    for route <- [&download/3, &preview/3] do
      assert_not_found(route.(conn, ctx.stranger, attachment.id))
      assert_not_found(route.(conn, ctx.reader, elsewhere.id))

      for id <- ["abc", "-5", "0", "1.5", "99999999999999999999", "#{attachment.id + 1_000_000}"] do
        assert_not_found(route.(conn, ctx.reader, id))
      end
    end
  end

  test "a locked free board gets 404 and emits one feature_refused event", %{conn: conn} = ctx do
    free_task = ctx.owner |> board_fixture() |> column_fixture() |> task_fixture()
    attachment = stored(free_task, %{}, "locked")
    attach_telemetry([@feature_refused])

    assert_not_found(download(conn, ctx.owner, attachment.id))

    assert_received {:telemetry_event, @feature_refused, %{count: 1},
                     %{feature: :attachments, surface: :context}}

    refute_received {:telemetry_event, @feature_refused, _, _}
  end

  test "returns 404 when the stored object is missing", %{conn: conn} = ctx do
    never_stored = attachment_fixture(ctx.task, %{filename: "gone.txt"})
    deleted = stored(ctx.task, %{filename: "deleted.txt"}, "soon gone")
    :ok = Storage.delete(deleted.storage_key)

    for attachment <- [never_stored, deleted] do
      log = capture_log(fn -> assert_not_found(download(conn, ctx.reader, attachment.id)) end)

      assert log =~ "attachment_id=#{attachment.id}"
      assert log =~ "reason=:not_found"
      refute log =~ attachment.storage_key
      refute log =~ attachment.filename
    end

    unavailable = stored(ctx.task, %{}, "bytes")
    Process.put(:stream_result, {:error, :storage_unavailable})

    log = capture_log(fn -> assert_not_found(download(conn, ctx.reader, unavailable.id)) end)
    assert log =~ "reason=:storage_unavailable"

    # A reason that is not an atom could carry a key or a path: it is logged
    # as :unknown.
    Process.put(:stream_result, {:error, {:failed, unavailable.storage_key}})
    log = capture_log(fn -> assert_not_found(download(conn, ctx.reader, unavailable.id)) end)
    assert log =~ "reason=:unknown"
    refute log =~ unavailable.storage_key
  end

  test "a stream that fails after the headers are sent ends the response without raising",
       %{conn: conn} = ctx do
    attachment = stored(ctx.task, %{}, "bytes")
    secret_path = "boards/1/" <> attachment.storage_key

    failing =
      Stream.concat(
        ["first"],
        Stream.map([:next], fn _ ->
          raise File.Error, reason: :enoent, action: "stream", path: secret_path
        end)
      )

    Process.put(:stream_result, {:ok, failing})
    log = capture_log(fn -> assert download(conn, ctx.reader, attachment.id).status == 200 end)
    assert log =~ "attachment_id=#{attachment.id} reason=:enoent"
    refute log =~ attachment.storage_key

    for {stream, reason} <- [
          {Stream.map([:next], fn _ -> raise ArgumentError, "boom" end), ":stream_failed"},
          {Stream.map([:next], fn _ -> exit(:closed) end), ":stream_failed"}
        ] do
      Process.put(:stream_result, {:ok, stream})

      log =
        capture_log(fn ->
          assert download(build_conn(), ctx.reader, attachment.id).status == 200
        end)

      assert log =~ "reason=#{reason}"
    end
  end

  test "a signed-out visitor is sent to log in", %{conn: conn} = ctx do
    attachment = stored(ctx.task, %{}, "bytes")

    for path <- [
          ~p"/attachments/#{attachment.id}/download",
          ~p"/attachments/#{attachment.id}/preview"
        ] do
      assert redirected_to(get(conn, path)) == ~p"/users/log-in"
    end
  end

  test "an image Accept header passes the browser pipeline", %{conn: conn} = ctx do
    png = stored(ctx.task, %{filename: "a.png", content_type: "image/png"}, "png")

    conn =
      conn
      |> put_req_header("accept", "image/avif,image/webp,image/*,*/*;q=0.8")
      |> preview(ctx.reader, png.id)

    assert conn.status == 200
    assert conn.resp_body == "png"
  end
end
