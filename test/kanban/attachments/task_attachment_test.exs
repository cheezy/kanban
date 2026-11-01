defmodule Kanban.Attachments.TaskAttachmentTest do
  # Not async: the Limits tests change application config, which is global.
  use ExUnit.Case, async: false

  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.TaskAttachment

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
  @pdf "%PDF-1.7\n"
  @sha String.duplicate("ab", 32)

  setup do
    saved = Application.fetch_env(:kanban, Limits)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:kanban, Limits, value)
        :error -> Application.delete_env(:kanban, Limits)
      end
    end)
  end

  defp attachment, do: %TaskAttachment{task_id: 1, board_id: 2, storage_key: "boards/2/abc"}

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "filename" => "diagram.png",
        "content_type" => "image/png",
        "byte_size" => 100,
        "sha256" => @sha
      },
      overrides
    )
  end

  defp changeset(overrides \\ %{}, head \\ @png),
    do: TaskAttachment.create_changeset(attachment(), attrs(overrides), head)

  # A text type is checked over its whole body, so pass every byte and a
  # matching byte_size.
  defp text_changeset(overrides, body),
    do: changeset(Map.put(overrides, "byte_size", byte_size(body)), body)

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  describe "create_changeset/3" do
    test "accepts a valid png attachment" do
      changeset = changeset()
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :filename) == "diagram.png"
      assert Ecto.Changeset.get_field(changeset, :content_type) == "image/png"
    end

    test "accepts a file of exactly max_file_bytes and refuses one byte more" do
      max = Limits.max_file_bytes()
      assert changeset(%{"byte_size" => max}).valid?

      refused = changeset(%{"byte_size" => max + 1})
      refute refused.valid?
      assert %{byte_size: [_message]} = errors(refused)
    end

    test "honours a configured max_file_bytes" do
      Application.put_env(:kanban, Limits, max_file_bytes: 1_000)
      assert changeset(%{"byte_size" => 1_000}).valid?
      refute changeset(%{"byte_size" => 1_001}).valid?
    end

    test "refuses a zero-byte file" do
      refused = changeset(%{"byte_size" => 0})
      refute refused.valid?
      assert %{byte_size: ["must be greater than %{number}"]} = errors(refused)
    end

    test "refuses a content type outside the allow-list" do
      for type <- ["image/svg+xml", "text/html", "application/zip"] do
        refused = changeset(%{"content_type" => type})
        assert %{content_type: ["is not an allowed type"]} = errors(refused)
      end
    end

    test "refuses an unknown extension when the declared type is empty" do
      refused = changeset(%{"filename" => "archive.zip", "content_type" => ""})
      assert %{content_type: ["is not an allowed type"]} = errors(refused)
    end

    test "refuses a png declared type whose bytes are a pdf" do
      refused = changeset(%{}, @pdf)
      refute refused.valid?
      assert %{content_type: ["does not match the file contents"]} = errors(refused)
    end

    test "refuses a text declared type whose head contains a NUL byte" do
      refused =
        changeset(%{"filename" => "notes.txt", "content_type" => "text/plain"}, "a\0b")

      assert %{content_type: ["does not match the file contents"]} = errors(refused)
    end

    test "infers text/markdown for an octet-stream .md upload" do
      changeset =
        text_changeset(
          %{"filename" => "README.md", "content_type" => "application/octet-stream"},
          "# Read me\n"
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :content_type) == "text/markdown"
    end

    test "infers text/plain for a .log upload with no declared type" do
      changeset =
        text_changeset(%{"filename" => "server.log", "content_type" => nil}, "boot ok\n")

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :content_type) == "text/plain"
    end

    test "normalises a declared type with a charset parameter and an alias" do
      changeset =
        text_changeset(
          %{"filename" => "notes.txt", "content_type" => "text/plain; charset=utf-8"},
          "hi"
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :content_type) == "text/plain"

      jpeg =
        changeset(
          %{"filename" => "a.jpg", "content_type" => "image/jpg"},
          <<0xFF, 0xD8, 0xFF, 0xE0>>
        )

      assert jpeg.valid?
      assert Ecto.Changeset.get_change(jpeg, :content_type) == "image/jpeg"
    end

    test "refuses a declared type whose file extension disagrees with it" do
      for {name, body} <- [
            {"report.html", "<html><script>x()</script></html>"},
            {"logo.svg", "<svg onload='x()'/>"},
            {"bomb.zip", "PKcomment"},
            {"notes.md.exe", "hello"},
            {".html", "<script>x()</script>"},
            {"../.svg", "<svg onload='x()'/>"}
          ] do
        refused = text_changeset(%{"filename" => name, "content_type" => "text/plain"}, body)
        assert %{content_type: ["does not match the file extension"]} = errors(refused), name
      end

      refused = changeset(%{"filename" => "diagram.pdf", "content_type" => "image/png"})
      assert %{content_type: ["does not match the file extension"]} = errors(refused)
    end

    test "accepts a matching or missing extension, and text/plain for any text extension" do
      assert changeset(%{"filename" => "DIAGRAM.PNG"}).valid?
      assert changeset(%{"filename" => "diagram"}).valid?

      for name <- ["notes.md", "data.csv", "data.json", "server.log", "Makefile"] do
        accepted = text_changeset(%{"filename" => name, "content_type" => "text/plain"}, "a,b\n")
        assert accepted.valid?, name
        assert Ecto.Changeset.get_change(accepted, :content_type) == "text/plain"
      end

      refused =
        text_changeset(%{"filename" => "notes.txt", "content_type" => "text/csv"}, "a,b\n")

      assert %{content_type: ["does not match the file extension"]} = errors(refused)
    end

    test "checks a text type over its whole body, not only the head" do
      prefixed_binary = String.duplicate("a", 600) <> <<"PK", 3, 4, 0, 0>>

      refused =
        text_changeset(
          %{"filename" => "notes.txt", "content_type" => "text/plain"},
          prefixed_binary
        )

      assert %{content_type: ["does not match the file contents"]} = errors(refused)

      head_only =
        changeset(%{"filename" => "notes.txt", "content_type" => "text/plain"}, "only the head")

      assert %{content_type: ["must be checked against the whole file"]} = errors(head_only)
    end

    @tag :tmp_dir
    test "reads the contents from a file", %{tmp_dir: tmp_dir} do
      text = Path.join(tmp_dir, "notes.txt")
      File.write!(text, String.duplicate("line of text\n", 100))

      text_attrs = %{
        "filename" => "notes.txt",
        "content_type" => "text/plain",
        "byte_size" => 1_300
      }

      assert changeset(text_attrs, {:file, text}).valid?

      wrong_size = changeset(Map.put(text_attrs, "byte_size", 1_299), {:file, text})
      assert %{content_type: ["must be checked against the whole file"]} = errors(wrong_size)

      hidden = Path.join(tmp_dir, "hidden.txt")
      File.write!(hidden, String.duplicate("a", 600) <> <<0>>)

      hidden_attrs = %{
        "filename" => "hidden.txt",
        "content_type" => "text/plain",
        "byte_size" => 601
      }

      assert %{content_type: ["does not match the file contents"]} =
               errors(changeset(hidden_attrs, {:file, hidden}))

      png = Path.join(tmp_dir, "diagram.png")
      File.write!(png, @png <> String.duplicate(<<0>>, 2_000))
      assert changeset(%{"byte_size" => 2_016}, {:file, png}).valid?

      pdf = Path.join(tmp_dir, "fake.png")
      File.write!(pdf, @pdf)

      assert %{content_type: ["does not match the file contents"]} =
               errors(changeset(%{}, {:file, pdf}))

      empty = Path.join(tmp_dir, "empty.png")
      File.write!(empty, "")

      assert %{content_type: ["does not match the file contents"]} =
               errors(changeset(%{}, {:file, empty}))

      missing = Path.join(tmp_dir, "missing.png")
      assert %{content_type: ["could not be checked"]} = errors(changeset(%{}, {:file, missing}))

      missing_text = Path.join(tmp_dir, "missing.txt")

      assert %{content_type: ["could not be checked"]} =
               errors(
                 changeset(
                   %{"filename" => "missing.txt", "content_type" => "text/plain"},
                   {:file, missing_text}
                 )
               )

      assert %{content_type: ["could not be checked"]} = errors(changeset(%{}, {:file, 42}))
    end

    @tag :tmp_dir
    test "refuses a text file that is not a regular file", %{tmp_dir: tmp_dir} do
      attrs = %{"filename" => "dir.txt", "content_type" => "text/plain", "byte_size" => 1}

      assert %{content_type: ["could not be checked"]} =
               errors(changeset(attrs, {:file, tmp_dir}))

      # A device opens and reads as empty, so only the whole-body check refuses it.
      assert %{content_type: ["could not be checked"]} =
               errors(changeset(attrs, {:file, "/dev/null"}))
    end

    test "never casts task_id, board_id, comment_id, uploaded_by_id or storage_key from attrs" do
      forged = %{
        "task_id" => 999,
        "board_id" => 999,
        "comment_id" => 999,
        "uploaded_by_id" => 999,
        "storage_key" => "boards/999/stolen"
      }

      changeset = changeset(forged)
      assert changeset.valid?

      for field <- [:task_id, :board_id, :comment_id, :uploaded_by_id, :storage_key] do
        refute Map.has_key?(changeset.changes, field)
      end

      assert Ecto.Changeset.get_field(changeset, :task_id) == 1
      assert Ecto.Changeset.get_field(changeset, :board_id) == 2
      assert Ecto.Changeset.get_field(changeset, :comment_id) == nil
      assert Ecto.Changeset.get_field(changeset, :uploaded_by_id) == nil
      assert Ecto.Changeset.get_field(changeset, :storage_key) == "boards/2/abc"
    end

    test "requires the server-set task_id, board_id and storage_key on the struct" do
      refused = TaskAttachment.create_changeset(%TaskAttachment{}, attrs(), @png)
      errors = errors(refused)

      for field <- [:task_id, :board_id, :storage_key] do
        assert errors[field] == ["can't be blank"]
      end
    end

    test "refuses a sha256 that is not 64 lowercase hex characters" do
      for bad <- [
            String.upcase(@sha),
            @sha <> "\n",
            String.slice(@sha, 0, 63),
            @sha <> "a",
            String.duplicate("g", 64)
          ] do
        refused = changeset(%{"sha256" => bad})
        assert %{sha256: ["must be 64 lowercase hex characters"]} = errors(refused), inspect(bad)
      end
    end

    test "sanitises the filename and refuses one left empty" do
      changeset = changeset(%{"filename" => "../../secret/diagram\u202E.png"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :filename) == "diagram.png"

      refused = changeset(%{"filename" => "uploads/.."})
      assert %{filename: ["is invalid"]} = errors(refused)
    end

    test "refuses a filename that sanitises to invisible characters only" do
      refused = changeset(%{"filename" => "\u3164", "content_type" => "image/png"})
      assert %{filename: ["can't be blank"]} = errors(refused)
    end

    test "requires the filename, byte_size and sha256" do
      refused = TaskAttachment.create_changeset(attachment(), %{}, @png)
      errors = errors(refused)

      for field <- [:filename, :byte_size, :sha256] do
        assert errors[field] == ["can't be blank"]
      end
    end
  end

  describe "Limits" do
    test "Limits defaults to 25 MiB, 20 files and 10 GiB and reads config at call time" do
      Application.delete_env(:kanban, Limits)

      assert Limits.max_file_bytes() == 26_214_400
      assert Limits.max_files_per_task() == 20
      assert Limits.organization_quota_bytes() == 10_737_418_240

      Application.put_env(:kanban, Limits,
        max_file_bytes: 10,
        max_files_per_task: 3,
        organization_quota_bytes: 99
      )

      assert Limits.max_file_bytes() == 10
      assert Limits.max_files_per_task() == 3
      assert Limits.organization_quota_bytes() == 99

      Application.put_env(:kanban, Limits, max_files_per_task: 7)
      assert Limits.max_file_bytes() == 26_214_400
      assert Limits.max_files_per_task() == 7
      assert Limits.organization_quota_bytes() == 10_737_418_240
    end
  end
end
