defmodule Mix.Tasks.Kanban.BackfillChangedFilesTest do
  # async: false — mutates process-wide env vars.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kanban.BackfillChangedFiles

  describe "resolve_config/0" do
    setup do
      original = {System.get_env("STRIDE_API_URL"), System.get_env("STRIDE_API_TOKEN")}

      on_exit(fn ->
        {url, token} = original
        put_or_delete("STRIDE_API_URL", url)
        put_or_delete("STRIDE_API_TOKEN", token)
      end)

      :ok
    end

    test "returns url + token when both env vars are set, trimming a trailing slash" do
      System.put_env("STRIDE_API_URL", "https://example.com/")
      System.put_env("STRIDE_API_TOKEN", "stride_abc")

      assert {:ok, %{url: "https://example.com", token: "stride_abc"}} =
               BackfillChangedFiles.resolve_config()
    end

    test "errors naming the missing variable when the token is unset" do
      System.put_env("STRIDE_API_URL", "https://example.com")
      System.delete_env("STRIDE_API_TOKEN")

      assert {:error, {:missing_config, "STRIDE_API_TOKEN"}} =
               BackfillChangedFiles.resolve_config()
    end

    test "errors when the url is unset" do
      System.delete_env("STRIDE_API_URL")
      System.put_env("STRIDE_API_TOKEN", "stride_abc")

      assert {:error, {:missing_config, "STRIDE_API_URL"}} =
               BackfillChangedFiles.resolve_config()
    end
  end

  describe "binary_numstat?/1" do
    test "true when git reports the file as binary (-\\t-)" do
      assert BackfillChangedFiles.binary_numstat?("-\t-\tassets/logo.png")
    end

    test "false for a text file with numeric add/remove counts" do
      refute BackfillChangedFiles.binary_numstat?("12\t3\tlib/a.ex")
    end

    test "false for empty numstat output" do
      refute BackfillChangedFiles.binary_numstat?("")
    end
  end

  defp put_or_delete(var, nil), do: System.delete_env(var)
  defp put_or_delete(var, value), do: System.put_env(var, value)
end
