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
  alias KanbanWeb.AttachmentStream

  @moduletag :tmp_dir

  @feature_refused [:kanban, :plan, :feature_refused]
  @downloaded [:kanban, :attachment, :downloaded]
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
    # The recorded size is declared, so a client can tell a cut-off file.
    assert header(conn, "content-length") == ["200000"]
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
      assert header(conn, "content-length") == ["#{byte_size("bytes of #{type}")}"]
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

      assert header(served, "content-security-policy") == [
               "default-src 'none'; frame-ancestors 'none'; sandbox"
             ]

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

  test "a download and a preview are told apart in the downloaded event", %{conn: conn} = ctx do
    png = stored(ctx.task, %{filename: "shot.png", content_type: "image/png"}, "png bytes")
    attach_telemetry([@downloaded])

    assert download(conn, ctx.reader, png.id).status == 200
    assert_received {:telemetry_event, @downloaded, %{count: 1}, %{via: :download}}

    assert preview(conn, ctx.reader, png.id).status == 200
    assert_received {:telemetry_event, @downloaded, %{count: 1}, %{via: :preview}}

    refute_received {:telemetry_event, @downloaded, _, _}
  end

  describe "HEAD" do
    # Reports every chunk the controller pulls from storage to the test process.
    defp count_reads(attachment) do
      me = self()
      {:ok, chunks} = Storage.stream(attachment.storage_key)

      Process.put(
        :stream_result,
        {:ok, Stream.each(chunks, &send(me, {:read_chunk, byte_size(&1)}))}
      )
    end

    defp head_as(conn, user, path), do: conn |> log_in_user(user) |> head(path)

    defp read_bytes(total \\ 0) do
      receive do
        {:read_chunk, n} -> read_bytes(total + n)
      after
        0 -> total
      end
    end

    test "sends the GET headers without reading the file", %{conn: conn} = ctx do
      big = stored(ctx.task, %{filename: "big.bin"}, :crypto.strong_rand_bytes(300_000))
      get_conn = download(conn, ctx.reader, big.id)
      count_reads(big)

      head_conn = head_as(conn, ctx.reader, ~p"/attachments/#{big.id}/download")

      assert head_conn.status == 200
      assert head_conn.resp_body == ""
      assert header(head_conn, "content-length") == ["300000"]

      for name <-
            ~w(content-type content-disposition content-security-policy cache-control x-content-type-options) do
        assert header(head_conn, name) == header(get_conn, name), name
      end

      # At most one chunk is read, only so the opened stream is closed.
      assert read_bytes() <= 65_536
    end

    test "a preview HEAD reads at most one chunk too", %{conn: conn} = ctx do
      png =
        stored(
          ctx.task,
          %{filename: "a.png", content_type: "image/png"},
          :crypto.strong_rand_bytes(200_000)
        )

      count_reads(png)

      head_conn = head_as(conn, ctx.reader, ~p"/attachments/#{png.id}/preview")

      assert head_conn.status == 200
      assert header(head_conn, "content-length") == ["200000"]
      assert read_bytes() <= 65_536
    end

    test "is recorded as via: :head, not as a download or a preview", %{conn: conn} = ctx do
      png = stored(ctx.task, %{filename: "a.png", content_type: "image/png"}, "png bytes")
      attach_telemetry([@downloaded])

      head_as(conn, ctx.reader, ~p"/attachments/#{png.id}/download")
      assert_received {:telemetry_event, @downloaded, %{count: 1}, %{via: :head}}

      head_as(conn, ctx.reader, ~p"/attachments/#{png.id}/preview")
      assert_received {:telemetry_event, @downloaded, %{count: 1}, %{via: :head}}

      refute_received {:telemetry_event, @downloaded, _, _}
    end

    test "a blob shorter than its row is not an aborted transfer on HEAD", %{conn: conn} = ctx do
      short = stored(ctx.task, %{filename: "short.txt"}, "bytes")
      Process.put(:stream_result, {:ok, ["by"]})

      head_conn = head_as(conn, ctx.reader, ~p"/attachments/#{short.id}/download")

      assert head_conn.status == 200
      assert header(head_conn, "content-length") == ["5"]
    end

    test "a stream that fails on its first read is a 404, decided before any header",
         %{conn: conn} = ctx do
      broken = stored(ctx.task, %{filename: "broken.txt"}, "bytes")

      failing =
        Stream.resource(
          fn -> :start end,
          fn _ -> raise File.Error, reason: :eio, action: "read", path: "attachment" end,
          fn _ -> :ok end
        )

      Process.put(:stream_result, {:ok, failing})

      log =
        capture_log(fn ->
          head_conn = head_as(conn, ctx.reader, ~p"/attachments/#{broken.id}/download")
          assert head_conn.status == 404
          assert header(head_conn, "content-disposition") == []
        end)

      assert log =~ "attachment_id=#{broken.id} reason=:eio"
      refute log =~ broken.storage_key
    end

    test "a refused HEAD is the same uniform 404 as a GET", %{conn: conn} = ctx do
      attachment = stored(ctx.task, %{}, "secret")

      head_conn = head_as(conn, ctx.stranger, ~p"/attachments/#{attachment.id}/download")
      get_conn = download(conn, ctx.stranger, attachment.id)

      assert head_conn.status == 404
      assert get_conn.status == 404
      assert header(head_conn, "content-disposition") == []
      assert header(head_conn, "content-length") == header(get_conn, "content-length")
    end
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

    # A reason outside the storage contract could carry a key or a path: the
    # storage facade logs only that the contract was broken, and the
    # controller sees :storage_unavailable.
    Process.put(:stream_result, {:error, {:failed, unavailable.storage_key}})
    log = capture_log(fn -> assert_not_found(download(conn, ctx.reader, unavailable.id)) end)
    assert log =~ "attachment storage stream failed: :unexpected_reason"
    assert log =~ "reason=:storage_unavailable"
    refute log =~ unavailable.storage_key
  end

  test "a blob the app cannot read is a 404, not an empty 200", %{conn: conn} = ctx do
    png = stored(ctx.task, %{filename: "shot.png", content_type: "image/png"}, "png bytes")
    path = Path.join(Local.root(), png.storage_key)
    File.chmod!(path, 0o000)

    # A superuser reads any file, so there is nothing to refuse.
    if match?({:error, :eacces}, File.read(path)) do
      log =
        capture_log(fn ->
          assert_not_found(download(conn, ctx.reader, png.id))
          assert_not_found(preview(build_conn(), ctx.reader, png.id))
        end)

      assert log =~ "attachment_id=#{png.id} reason=:storage_unavailable"
      refute log =~ png.storage_key
    end
  end

  # Once the headers are out the status cannot change, so a body that falls
  # short of the declared length must end the connection rather than finish
  # the response: a finished response would read as the whole file.
  test "a stream that fails after the headers are sent aborts the response", ctx do
    attachment = stored(ctx.task, %{}, "bytes")
    secret_path = "boards/1/" <> attachment.storage_key

    failing =
      Stream.concat(
        ["by"],
        Stream.map([:next], fn _ ->
          raise File.Error, reason: :enoent, action: "stream", path: secret_path
        end)
      )

    for {stream, reason} <- [
          {failing, ":enoent"},
          {Stream.map([:next], fn _ -> raise ArgumentError, "boom" end), ":stream_failed"},
          {Stream.map([:next], fn _ -> exit(:closed) end), ":stream_failed"}
        ] do
      Process.put(:stream_result, {:ok, stream})

      log =
        capture_log(fn ->
          assert_raise AttachmentStream.IncompleteTransfer, fn ->
            download(build_conn(), ctx.reader, attachment.id)
          end
        end)

      assert log =~ "attachment_id=#{attachment.id} reason=#{reason}"
      refute log =~ attachment.storage_key
    end
  end

  test "a blob shorter than its recorded size aborts the response", %{conn: conn} = ctx do
    attachment = stored(ctx.task, %{}, "bytes")
    Process.put(:stream_result, {:ok, ["by", "te"]})

    log =
      capture_log(fn ->
        error =
          assert_raise AttachmentStream.IncompleteTransfer, fn ->
            download(conn, ctx.reader, attachment.id)
          end

        assert Exception.message(error) =~ "attachment #{attachment.id}"
        refute Exception.message(error) =~ attachment.storage_key
      end)

    assert log =~ "attachment_id=#{attachment.id} reason=:incomplete"
  end

  test "a blob longer than its recorded size is cut at that size", %{conn: conn} = ctx do
    attachment = stored(ctx.task, %{}, "bytes")
    Process.put(:stream_result, {:ok, ["byt", "es and more", " still more"]})

    log =
      capture_log(fn ->
        conn = download(conn, ctx.reader, attachment.id)
        assert conn.status == 200
        assert conn.resp_body == "bytes"
        assert header(conn, "content-length") == ["5"]
      end)

    assert log =~ "attachment_id=#{attachment.id} reason=:size_mismatch"
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
