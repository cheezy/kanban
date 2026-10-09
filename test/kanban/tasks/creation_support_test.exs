defmodule Kanban.Tasks.CreationSupportTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.CreationSupport
  alias Kanban.Tasks.Task

  doctest CreationSupport, import: true

  describe "new_task/1" do
    test "a task created into Review starts waiting for review" do
      assert %Task{column_id: 4, review_requested_at: %DateTime{}} =
               CreationSupport.new_task(%{id: 4, name: "Review"})
    end

    test "any other column gives a plain task in that column" do
      assert CreationSupport.new_task(%{id: 5, name: "Doing"}) == %Task{column_id: 5}
    end
  end

  describe "key style" do
    test "put_position/2 and put_assigned_to_id/2 follow the attrs' key style" do
      assert CreationSupport.put_position(%{}, 1) == %{position: 1}

      assert CreationSupport.put_assigned_to_id(%{title: "T"}, 2) == %{
               title: "T",
               assigned_to_id: 2
             }

      assert CreationSupport.put_assigned_to_id(%{"t" => 1}, 2) == %{
               "t" => 1,
               "assigned_to_id" => 2
             }
    end

    test "assigned_to_id_explicit?/1 accepts either key style" do
      assert CreationSupport.assigned_to_id_explicit?(%{assigned_to_id: nil})
      assert CreationSupport.assigned_to_id_explicit?(%{"assigned_to_id" => 3})
      refute CreationSupport.assigned_to_id_explicit?(%{})
    end
  end

  test "run_before_broadcast/2 passes every argument to the function" do
    assert CreationSupport.run_before_broadcast([before_broadcast: &{&1, &2}], [:goal, [:child]]) ==
             {:goal, [:child]}
  end
end
