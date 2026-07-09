defmodule Kanban.Tasks.PathSafetyTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.PathSafety

  doctest PathSafety

  describe "validate/1" do
    test "accepts normal relative paths" do
      assert PathSafety.validate("lib/kanban/tasks.ex") == :ok
      assert PathSafety.validate("a/b/c.txt") == :ok
      assert PathSafety.validate("README.md") == :ok
      assert PathSafety.validate("deep/nested/dir/file.ex") == :ok
    end

    test "rejects non-strings" do
      assert PathSafety.validate(nil) == {:error, :not_a_string}
      assert PathSafety.validate(123) == {:error, :not_a_string}
      assert PathSafety.validate(%{}) == {:error, :not_a_string}
    end

    test "rejects empty strings" do
      assert PathSafety.validate("") == {:error, :empty}
    end

    test "rejects absolute paths" do
      assert PathSafety.validate("/etc/passwd") == {:error, :absolute}
      assert PathSafety.validate("/") == {:error, :absolute}
    end

    test "rejects .. traversal, including mid-path and backslash forms" do
      assert PathSafety.validate("../secret") == {:error, :traversal}
      assert PathSafety.validate("../../etc/passwd") == {:error, :traversal}
      assert PathSafety.validate("a/../../b") == {:error, :traversal}
      assert PathSafety.validate("..\\..\\windows") == {:error, :traversal}
    end

    test "rejects null bytes" do
      assert PathSafety.validate("lib/foo\0.ex") == {:error, :null_byte}
    end
  end

  describe "relative_safe?/1" do
    test "true only for safe relative paths" do
      assert PathSafety.relative_safe?("lib/foo.ex")
      refute PathSafety.relative_safe?("")
      refute PathSafety.relative_safe?("/abs")
      refute PathSafety.relative_safe?("../x")
      refute PathSafety.relative_safe?("x\0y")
      refute PathSafety.relative_safe?(nil)
    end
  end
end
