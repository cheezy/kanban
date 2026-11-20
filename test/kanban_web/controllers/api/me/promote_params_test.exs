defmodule KanbanWeb.API.Me.PromoteParamsTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.Me.PromoteParams

  defp errors({:error, changeset}) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end

  test "casts task_ids and an optional needs_review" do
    assert PromoteParams.cast(%{"task_ids" => [3, 1]}) == {:ok, [3, 1], nil}

    assert PromoteParams.cast(%{"task_ids" => [1], "needs_review" => true}) ==
             {:ok, [1], true}

    assert PromoteParams.cast(%{"task_ids" => [1], "needs_review" => false}) ==
             {:ok, [1], false}
  end

  test "ignores any other key" do
    assert PromoteParams.cast(%{"task_ids" => [1], "title" => "Edited", "priority" => "high"}) ==
             {:ok, [1], nil}
  end

  test "an empty or missing list is blank" do
    assert errors(PromoteParams.cast(%{"task_ids" => []})) == %{task_ids: ["can't be blank"]}
    assert errors(PromoteParams.cast(%{})) == %{task_ids: ["can't be blank"]}
  end

  test "more than 100 ids is too many" do
    assert errors(PromoteParams.cast(%{"task_ids" => Enum.to_list(1..101)})) == %{
             task_ids: ["should have at most 100 item(s)"]
           }

    assert {:ok, ids, nil} = PromoteParams.cast(%{"task_ids" => Enum.to_list(1..100)})
    assert length(ids) == 100
  end

  test "a non-positive, oversized or non-integer id is invalid" do
    for ids <- [[0], [-1], [9_223_372_036_854_775_808], ["abc"], [1.5], "1"] do
      assert errors(PromoteParams.cast(%{"task_ids" => ids})) == %{task_ids: ["is invalid"]},
             inspect(ids)
    end
  end

  test "a non-boolean needs_review is invalid" do
    assert errors(PromoteParams.cast(%{"task_ids" => [1], "needs_review" => "maybe"})) == %{
             needs_review: ["is invalid"]
           }
  end
end
