defmodule Kanban.Attachments.RuntimeConfigTest do
  # Not async: these tests set OS environment variables, which are global.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @vars ~w(
    ATTACHMENTS_STORAGE ATTACHMENTS_DIR
    ATTACHMENTS_S3_BUCKET ATTACHMENTS_S3_ENDPOINT ATTACHMENTS_S3_REGION
    ATTACHMENTS_S3_ACCESS_KEY_ID ATTACHMENTS_S3_SECRET_ACCESS_KEY ATTACHMENTS_S3_PATH_STYLE
    BUCKET_NAME AWS_ENDPOINT_URL_S3 AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    ATTACHMENTS_MAX_FILE_MB ATTACHMENTS_MAX_FILES_PER_TASK ATTACHMENTS_ORG_QUOTA_GB
    DATABASE_URL SECRET_KEY_BASE ENCRYPTION_KEY DATABASE_SSL PHX_SERVER
  )

  # What the prod block needs besides attachments; a Fly-internal database
  # host passes its plaintext-database guard.
  @prod_env %{
    "DATABASE_URL" => "ecto://user:pass@db.internal/kanban",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "ENCRYPTION_KEY" => "k" |> String.duplicate(32) |> Base.encode64()
  }

  @sentinel "sentinel-value-never-printed"

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  # Each read starts from none of @vars set, then sets exactly `env`.
  defp read(env) do
    Enum.each(@vars, &System.delete_env/1)
    System.put_env(env)
    @runtime |> Config.Reader.read!(env: :test) |> Keyword.get(:kanban, [])
  end

  # A prod read of `env` on top of @prod_env, returning what it printed to
  # stderr.
  defp read_prod_stderr(env) do
    Enum.each(@vars, &System.delete_env/1)
    @prod_env |> Map.merge(env) |> System.put_env()

    {_config, stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Config.Reader.read!(@runtime, env: :prod, target: :host)
      end)

    stderr
  end

  describe "the prod local-storage warning" do
    test "warns when neither ATTACHMENTS_STORAGE nor ATTACHMENTS_DIR is set" do
      stderr = read_prod_stderr(%{})

      assert stderr =~ "Attachments use local storage under the system temp directory"
      assert stderr =~ "docs/attachments-fly-setup.md"
    end

    test "is silent when ATTACHMENTS_DIR names a persistent directory" do
      refute read_prod_stderr(%{"ATTACHMENTS_DIR" => "/data/attachments"}) =~ "temp directory"
    end

    test "is silent when ATTACHMENTS_STORAGE selects S3" do
      env = %{
        "ATTACHMENTS_STORAGE" => "s3",
        "ATTACHMENTS_S3_BUCKET" => "b",
        "ATTACHMENTS_S3_ACCESS_KEY_ID" => "id",
        "ATTACHMENTS_S3_SECRET_ACCESS_KEY" => @sentinel
      }

      refute read_prod_stderr(env) =~ "temp directory"
    end

    test "never warns outside prod" do
      {_config, stderr} = ExUnit.CaptureIO.with_io(:stderr, fn -> read(%{}) end)
      refute stderr =~ "temp directory"
    end
  end

  defp read_error(env) do
    error = assert_raise RuntimeError, fn -> read(env) end
    Exception.message(error)
  end

  test "sets nothing for attachments when no variable is set" do
    kanban = read(%{})

    refute Keyword.has_key?(kanban, Kanban.Attachments.Storage)
    refute Keyword.has_key?(kanban, Kanban.Attachments.Storage.S3)
    refute Keyword.has_key?(kanban, Kanban.Attachments.Storage.Local)
    refute Keyword.has_key?(kanban, Kanban.Attachments.Limits)
  end

  test "selects the local adapter and its directory" do
    kanban = read(%{"ATTACHMENTS_STORAGE" => "local", "ATTACHMENTS_DIR" => "/srv/files"})

    assert kanban[Kanban.Attachments.Storage] == [adapter: Kanban.Attachments.Storage.Local]
    assert kanban[Kanban.Attachments.Storage.Local] == [root: "/srv/files"]
  end

  test "reads the Tigris names, and an ATTACHMENTS_S3_* name wins over its fallback" do
    kanban =
      read(%{
        "ATTACHMENTS_STORAGE" => "s3",
        "BUCKET_NAME" => "tigris-bucket",
        "AWS_ENDPOINT_URL_S3" => "https://fly.storage.tigris.dev",
        "AWS_REGION" => "auto",
        "AWS_ACCESS_KEY_ID" => "tigris-id",
        "AWS_SECRET_ACCESS_KEY" => @sentinel,
        "ATTACHMENTS_S3_BUCKET" => "own-bucket",
        "ATTACHMENTS_S3_PATH_STYLE" => "true"
      })

    assert kanban[Kanban.Attachments.Storage] == [adapter: Kanban.Attachments.Storage.S3]

    s3 = kanban[Kanban.Attachments.Storage.S3]
    assert s3[:bucket] == "own-bucket"
    assert s3[:endpoint] == "https://fly.storage.tigris.dev"
    assert s3[:region] == "auto"
    assert s3[:access_key_id] == "tigris-id"
    assert s3[:secret_access_key] == @sentinel
    assert s3[:path_style] == true
  end

  test "path style reads true or 1 as on and false, 0 or unset as off, in any case" do
    base = %{
      "ATTACHMENTS_STORAGE" => "s3",
      "ATTACHMENTS_S3_BUCKET" => "b",
      "ATTACHMENTS_S3_ACCESS_KEY_ID" => "id",
      "ATTACHMENTS_S3_SECRET_ACCESS_KEY" => @sentinel
    }

    path_style = fn value ->
      env = if value, do: Map.put(base, "ATTACHMENTS_S3_PATH_STYLE", value), else: base
      read(env)[Kanban.Attachments.Storage.S3][:path_style]
    end

    assert path_style.(nil) == false

    for value <- ["true", "TRUE", " True ", "1"], do: assert(path_style.(value) == true)
    for value <- ["false", "FALSE", "0"], do: assert(path_style.(value) == false)
  end

  test "raises on a path style that is neither true nor false, without echoing it" do
    message =
      read_error(%{
        "ATTACHMENTS_STORAGE" => "s3",
        "ATTACHMENTS_S3_BUCKET" => "b",
        "ATTACHMENTS_S3_ACCESS_KEY_ID" => "id",
        "ATTACHMENTS_S3_SECRET_ACCESS_KEY" => @sentinel,
        "ATTACHMENTS_S3_PATH_STYLE" => "yes-please"
      })

    assert message =~ "ATTACHMENTS_S3_PATH_STYLE must be true or false"
    refute message =~ "yes-please"
  end

  test "raises on an endpoint that carries a user name or password, without echoing it" do
    message =
      read_error(%{
        "ATTACHMENTS_STORAGE" => "s3",
        "ATTACHMENTS_S3_BUCKET" => "b",
        "ATTACHMENTS_S3_ACCESS_KEY_ID" => "id",
        "ATTACHMENTS_S3_SECRET_ACCESS_KEY" => @sentinel,
        "ATTACHMENTS_S3_ENDPOINT" => "https://user:#{@sentinel}@storage.test"
      })

    assert message =~ "no user name or password"
    refute message =~ @sentinel
  end

  test "raises on a relative ATTACHMENTS_DIR without echoing it" do
    message = read_error(%{"ATTACHMENTS_DIR" => "relative/files"})

    assert message =~ "ATTACHMENTS_DIR must be an absolute path"
    refute message =~ "relative/files"
  end

  test "raises naming each missing S3 variable without printing any value" do
    message =
      read_error(%{
        "ATTACHMENTS_STORAGE" => "s3",
        "ATTACHMENTS_S3_ACCESS_KEY_ID" => @sentinel,
        "ATTACHMENTS_S3_SECRET_ACCESS_KEY" => @sentinel
      })

    assert message =~ "ATTACHMENTS_S3_BUCKET (or BUCKET_NAME)"
    refute message =~ "ACCESS_KEY_ID"
    refute message =~ @sentinel

    message = read_error(%{"ATTACHMENTS_STORAGE" => "s3"})
    assert message =~ "ATTACHMENTS_S3_BUCKET (or BUCKET_NAME)"
    assert message =~ "ATTACHMENTS_S3_ACCESS_KEY_ID (or AWS_ACCESS_KEY_ID)"
    assert message =~ "ATTACHMENTS_S3_SECRET_ACCESS_KEY (or AWS_SECRET_ACCESS_KEY)"
  end

  test "an empty variable counts as unset" do
    message =
      read_error(%{
        "ATTACHMENTS_STORAGE" => "s3",
        "ATTACHMENTS_S3_BUCKET" => "",
        "ATTACHMENTS_S3_ACCESS_KEY_ID" => "id",
        "ATTACHMENTS_S3_SECRET_ACCESS_KEY" => @sentinel
      })

    assert message =~ "ATTACHMENTS_S3_BUCKET (or BUCKET_NAME)"
  end

  test "raises on an endpoint that is not an http or https URL" do
    message =
      read_error(%{
        "ATTACHMENTS_STORAGE" => "s3",
        "ATTACHMENTS_S3_BUCKET" => "b",
        "ATTACHMENTS_S3_ACCESS_KEY_ID" => "id",
        "ATTACHMENTS_S3_SECRET_ACCESS_KEY" => @sentinel,
        "ATTACHMENTS_S3_ENDPOINT" => "fly.storage.tigris.dev"
      })

    assert message =~ "ATTACHMENTS_S3_ENDPOINT (or AWS_ENDPOINT_URL_S3) must be an http"
    refute message =~ "fly.storage.tigris.dev"
  end

  test "raises on an unknown storage value without echoing it" do
    message = read_error(%{"ATTACHMENTS_STORAGE" => "dropbox-#{@sentinel}"})

    assert message =~ "ATTACHMENTS_STORAGE must be local or s3"
    refute message =~ @sentinel
  end

  test "converts the limits from MiB and GiB into bytes" do
    kanban =
      read(%{
        "ATTACHMENTS_MAX_FILE_MB" => "25",
        "ATTACHMENTS_MAX_FILES_PER_TASK" => "20",
        "ATTACHMENTS_ORG_QUOTA_GB" => "10"
      })

    assert kanban[Kanban.Attachments.Limits] == [
             max_file_bytes: 26_214_400,
             max_files_per_task: 20,
             organization_quota_bytes: 10_737_418_240
           ]

    assert read(%{"ATTACHMENTS_MAX_FILES_PER_TASK" => "5"})[Kanban.Attachments.Limits] ==
             [max_files_per_task: 5]
  end

  test "raises naming a limit that is not a positive integer" do
    for value <- ["0", "-1", "25MB", "1.5", "ten"] do
      message = read_error(%{"ATTACHMENTS_MAX_FILE_MB" => value})
      assert message =~ "ATTACHMENTS_MAX_FILE_MB must be a positive integer"
    end
  end
end
