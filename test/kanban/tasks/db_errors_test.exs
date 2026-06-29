defmodule Kanban.Tasks.DbErrorsTest do
  @moduledoc """
  Tests for the W1413 defense-in-depth safety net: a Postgres 22001
  (value-too-long) raised on a task write path is translated into a sanitized
  changeset error (a clean 422), while any other error propagates unchanged.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks.DbErrors
  alias Kanban.Tasks.Task

  defp postgrex_22001 do
    %Postgrex.Error{
      postgres: %{
        code: :string_data_right_truncation,
        message: "value too long for type character varying(255)"
      }
    }
  end

  describe "value_too_long_changeset/0" do
    test "carries a single sanitized :base error with no field name or DB text" do
      changeset = DbErrors.value_too_long_changeset()

      refute changeset.valid?
      assert %{base: [message]} = errors_on(changeset)
      assert message == "is too long for one or more fields"
      refute message =~ "Postgrex"
      refute message =~ "varchar"
      refute message =~ "22001"
    end
  end

  describe "translate_value_too_long/2 with a simulated 22001" do
    test "translates into the 2-tuple shape the single-task and update paths use" do
      result =
        DbErrors.translate_value_too_long(fn -> raise postgrex_22001() end, &{:error, &1})

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert %{base: ["is too long for one or more fields"]} = errors_on(changeset)
    end

    test "translates into the 3-tuple shape the goal and batch path uses" do
      result =
        DbErrors.translate_value_too_long(
          fn -> raise postgrex_22001() end,
          fn changeset -> {:error, :db, changeset} end
        )

      assert {:error, :db, %Ecto.Changeset{} = changeset} = result
      assert %{base: ["is too long for one or more fields"]} = errors_on(changeset)
    end

    test "passes a success value through untouched" do
      assert {:ok, :done} =
               DbErrors.translate_value_too_long(fn -> {:ok, :done} end, &{:error, &1})
    end

    test "passes a returned {:error, changeset} through without rescuing it" do
      changeset = DbErrors.value_too_long_changeset()

      assert {:error, ^changeset} =
               DbErrors.translate_value_too_long(fn -> {:error, changeset} end, &{:error, &1})
    end
  end

  describe "translate_value_too_long/2 does not swallow unrelated errors" do
    test "re-raises a Postgrex.Error carrying a non-22001 code unchanged" do
      other = %Postgrex.Error{postgres: %{code: :unique_violation}}

      # Captured via try/rescue rather than assert_raise so the assertion does
      # not invoke Postgrex.Error.message/1 on this minimal struct.
      reraised =
        try do
          DbErrors.translate_value_too_long(fn -> raise other end, &{:error, &1})
          nil
        rescue
          error in Postgrex.Error -> error
        end

      assert reraised == other
    end

    test "re-raises a non-Postgrex exception" do
      assert_raise RuntimeError, "boom", fn ->
        DbErrors.translate_value_too_long(fn -> raise "boom" end, &{:error, &1})
      end
    end
  end

  describe "translate_value_too_long/2 against a real database 22001" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      %{column: column}
    end

    test "translates a genuine Postgres 22001 into a sanitized 422-shaped error",
         %{column: column} do
      task = task_fixture(column)

      # Ecto.Changeset.change/2 bypasses the D81 length validators, so a 256-char
      # title reaches the database and raises a real 22001 — exactly the future
      # "bounded column without a validator" scenario this safety net guards.
      # Asserting only on the rescued return avoids issuing another query against
      # the now-aborted sandbox transaction.
      over_long = String.duplicate("a", 256)

      result =
        DbErrors.translate_value_too_long(
          fn ->
            task
            |> Ecto.Changeset.change(%{title: over_long})
            |> Repo.update()
          end,
          &{:error, &1}
        )

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert %{base: ["is too long for one or more fields"]} = errors_on(changeset)
      refute changeset.valid?
      assert changeset.data.__struct__ == Task
    end
  end
end
