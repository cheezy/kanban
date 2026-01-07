defmodule Kanban.Hooks.ValidatorTest do
  use ExUnit.Case, async: true

  alias Kanban.Hooks.Validator

  describe "validate_hook_execution/3" do
    test "returns :ok when hook result is valid and successful" do
      result = %{
        "exit_code" => 0,
        "output" => "Success",
        "duration_ms" => 1000
      }

      assert :ok = Validator.validate_hook_execution(result, "test_hook", blocking: true)
      assert :ok = Validator.validate_hook_execution(result, "test_hook", blocking: false)
    end

    test "returns error when hook result is nil" do
      assert {:error, "test_hook hook result is required"} =
               Validator.validate_hook_execution(nil, "test_hook", blocking: true)

      assert {:error, "another_hook hook result is required"} =
               Validator.validate_hook_execution(nil, "another_hook", blocking: false)
    end

    test "returns error when hook result is not a map" do
      assert {:error, "test_hook hook result must be a map"} =
               Validator.validate_hook_execution("not a map", "test_hook", blocking: true)

      assert {:error, "test_hook hook result must be a map"} =
               Validator.validate_hook_execution(123, "test_hook", blocking: true)

      assert {:error, "test_hook hook result must be a map"} =
               Validator.validate_hook_execution(["list"], "test_hook", blocking: true)
    end

    test "returns error when required fields are missing" do
      # Missing exit_code
      result = %{
        "output" => "Success",
        "duration_ms" => 1000
      }

      assert {:error, "test_hook hook result must include exit_code, output, and duration_ms fields"} =
               Validator.validate_hook_execution(result, "test_hook", blocking: true)

      # Missing output
      result = %{
        "exit_code" => 0,
        "duration_ms" => 1000
      }

      assert {:error, "test_hook hook result must include exit_code, output, and duration_ms fields"} =
               Validator.validate_hook_execution(result, "test_hook", blocking: true)

      # Missing duration_ms
      result = %{
        "exit_code" => 0,
        "output" => "Success"
      }

      assert {:error, "test_hook hook result must include exit_code, output, and duration_ms fields"} =
               Validator.validate_hook_execution(result, "test_hook", blocking: true)

      # All missing
      result = %{}

      assert {:error, "test_hook hook result must include exit_code, output, and duration_ms fields"} =
               Validator.validate_hook_execution(result, "test_hook", blocking: true)
    end

    test "returns error when blocking hook fails with non-zero exit code" do
      result = %{
        "exit_code" => 1,
        "output" => "Failed",
        "duration_ms" => 500
      }

      assert {:error, "test_hook is a blocking hook and failed with exit code 1. Fix the issues and try again."} =
               Validator.validate_hook_execution(result, "test_hook", blocking: true)

      result = %{
        "exit_code" => 127,
        "output" => "Command not found",
        "duration_ms" => 100
      }

      assert {:error,
              "before_doing is a blocking hook and failed with exit code 127. Fix the issues and try again."} =
               Validator.validate_hook_execution(result, "before_doing", blocking: true)
    end

    test "returns :ok when non-blocking hook fails with non-zero exit code" do
      result = %{
        "exit_code" => 1,
        "output" => "Failed but non-blocking",
        "duration_ms" => 500
      }

      assert :ok = Validator.validate_hook_execution(result, "test_hook", blocking: false)

      result = %{
        "exit_code" => 255,
        "output" => "Error",
        "duration_ms" => 100
      }

      assert :ok = Validator.validate_hook_execution(result, "test_hook", blocking: false)
    end

    test "defaults to non-blocking when blocking option is not provided" do
      result = %{
        "exit_code" => 1,
        "output" => "Failed",
        "duration_ms" => 500
      }

      assert :ok = Validator.validate_hook_execution(result, "test_hook", [])
    end

    test "allows extra fields in hook result" do
      result = %{
        "exit_code" => 0,
        "output" => "Success",
        "duration_ms" => 1000,
        "extra_field" => "ignored",
        "another_field" => 42
      }

      assert :ok = Validator.validate_hook_execution(result, "test_hook", blocking: true)
    end

    test "validates different hook names correctly" do
      result = %{
        "exit_code" => 0,
        "output" => "Success",
        "duration_ms" => 1000
      }

      assert :ok = Validator.validate_hook_execution(result, "before_doing", blocking: true)
      assert :ok = Validator.validate_hook_execution(result, "after_doing", blocking: true)
      assert :ok = Validator.validate_hook_execution(result, "before_review", blocking: false)
      assert :ok = Validator.validate_hook_execution(result, "after_review", blocking: false)
      assert :ok = Validator.validate_hook_execution(result, "custom_hook", blocking: true)
    end

    test "includes hook name in error messages" do
      assert {:error, message} = Validator.validate_hook_execution(nil, "before_doing", blocking: true)
      assert message =~ "before_doing"

      assert {:error, message} = Validator.validate_hook_execution(nil, "after_doing", blocking: true)
      assert message =~ "after_doing"

      result = %{"exit_code" => 1, "output" => "fail", "duration_ms" => 100}

      assert {:error, message} =
               Validator.validate_hook_execution(result, "custom_hook", blocking: true)

      assert message =~ "custom_hook"
    end

    test "handles zero exit code correctly" do
      result = %{
        "exit_code" => 0,
        "output" => "",
        "duration_ms" => 0
      }

      assert :ok = Validator.validate_hook_execution(result, "test_hook", blocking: true)
    end

    test "validates all negative and positive exit codes for blocking hooks" do
      # Negative exit codes should fail
      result = %{
        "exit_code" => -1,
        "output" => "Error",
        "duration_ms" => 100
      }

      assert {:error, message} = Validator.validate_hook_execution(result, "test_hook", blocking: true)
      assert message =~ "exit code -1"

      # Positive non-zero exit codes should fail
      for code <- [1, 2, 3, 126, 127, 128, 255] do
        result = %{
          "exit_code" => code,
          "output" => "Error",
          "duration_ms" => 100
        }

        assert {:error, message} =
                 Validator.validate_hook_execution(result, "test_hook", blocking: true)

        assert message =~ "exit code #{code}"
      end
    end
  end
end
