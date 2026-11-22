defmodule Mix.Tasks.Mobile.ApiTest do
  # async: false — swaps the process-wide Mix shell and changes the working
  # directory.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kanban.Mobile.ApiContract

  @moduletag :tmp_dir

  @task Mix.Tasks.Mobile.Api

  # Key order and spacing that a decode/encode round trip would not keep, so
  # the tests prove the copy keeps the source's exact bytes.
  @contract """
  {
    "paths": {
      "/api/me": {
        "get": {
          "responses": {"200": {"description": "OK", "content": {"application/json": {"schema": {"type": "object"}}}}},
          "security": [{"deviceAuth": []}],
          "operationId": "getMe"
        }
      }
    },
    "openapi": "3.1.0",
    "components": {"securitySchemes": {"deviceAuth": {"type": "http", "scheme": "bearer"}}}
  }
  """

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  # Call run([]) only inside the tmp dir: elsewhere it writes the
  # repository's openapi.json.
  test "generate/1 copies the contract's exact bytes, creating the folder", %{tmp_dir: dir} do
    source = Path.join(dir, "stride-api.json")
    output = Path.join([dir, "nested", "openapi.json"])
    File.write!(source, @contract)

    printed = capture_io(fn -> assert @task.generate(source: source, output: output) == :ok end)

    assert printed =~ "Wrote #{output}"
    assert File.read!(output) == @contract

    capture_io(fn -> @task.generate(source: source, output: output) end)
    assert File.read!(output) == @contract
  end

  test "generate/1 writes nothing when the contract is invalid", %{tmp_dir: dir} do
    source = Path.join(dir, "stride-api.json")
    output = Path.join(dir, "openapi.json")
    File.write!(source, String.replace(@contract, ~s("deviceAuth": []), ~s("bearerAuth": [])))

    assert_raise ArgumentError, ~r/GET \/api\/me does not require deviceAuth/, fn ->
      @task.generate(source: source, output: output)
    end

    refute File.exists?(output)
  end

  test "run/1 with no arguments writes the default paths relative to the working directory",
       %{tmp_dir: dir} do
    source = Path.join(dir, ApiContract.source_path())
    source |> Path.dirname() |> File.mkdir_p!()
    File.write!(source, @contract)

    File.cd!(dir, fn -> capture_io(fn -> assert @task.run([]) == :ok end) end)

    assert dir |> Path.join(ApiContract.output_path()) |> File.read!() == @contract
  end

  test "the task takes no arguments" do
    assert_raise Mix.Error, ~r/takes no arguments, got: --check/, fn -> @task.run(["--check"]) end
  end
end
