defmodule Kanban.Telemetry.AfterCommitTest do
  use Kanban.DataCase, async: true

  alias Kanban.Repo
  alias Kanban.Telemetry.AfterCommit

  defp record(tag) do
    test_pid = self()
    fn -> send(test_pid, {:emitted, tag}) end
  end

  describe "defer/2" do
    test "emits straight away when nothing is holding" do
      refute AfterCommit.holding?()

      assert :ok = :now |> record() |> AfterCommit.defer()
      assert_received {:emitted, :now}

      assert :ok = :now_first |> record() |> AfterCommit.defer(:first)
      assert_received {:emitted, :now_first}
    end
  end

  describe "after_commit/1" do
    test "holds deferred emits until the transaction returns {:ok, _}, in order" do
      test_pid = self()

      result =
        AfterCommit.after_commit(fn ->
          Repo.transaction(fn ->
            AfterCommit.defer(record(:first))
            AfterCommit.defer(record(:second))
            send(test_pid, {:holding, AfterCommit.holding?()})
            :done
          end)
        end)

      assert result == {:ok, :done}

      # Nothing was emitted while the transaction ran: the holding message
      # arrived first, then the two emits in the order they were deferred.
      assert {:messages, [{:holding, true}, {:emitted, :first}, {:emitted, :second}]} =
               Process.info(self(), :messages)

      refute AfterCommit.holding?()
    end

    test "flushes :first emits ahead of :last ones, each group in the order deferred" do
      {:ok, :done} =
        AfterCommit.after_commit(fn ->
          :last_a |> record() |> AfterCommit.defer()
          :first_b |> record() |> AfterCommit.defer(:first)
          :last_c |> record() |> AfterCommit.defer(:last)
          :first_d |> record() |> AfterCommit.defer(:first)
          {:ok, :done}
        end)

      assert {:messages,
              [
                {:emitted, :first_b},
                {:emitted, :first_d},
                {:emitted, :last_a},
                {:emitted, :last_c}
              ]} = Process.info(self(), :messages)
    end

    test "a nested after_commit hands its :first emits to the outer queue ahead of its :last ones" do
      {:ok, :outer} =
        AfterCommit.after_commit(fn ->
          :outer_last |> record() |> AfterCommit.defer()

          {:ok, :inner} =
            AfterCommit.after_commit(fn ->
              :inner_last |> record() |> AfterCommit.defer()
              :inner_first |> record() |> AfterCommit.defer(:first)
              {:ok, :inner}
            end)

          {:ok, :outer}
        end)

      assert {:messages,
              [
                {:emitted, :inner_first},
                {:emitted, :outer_last},
                {:emitted, :inner_last}
              ]} = Process.info(self(), :messages)
    end

    test "drops deferred emits when Repo.rollback/1 runs" do
      result =
        AfterCommit.after_commit(fn ->
          Repo.transaction(fn ->
            AfterCommit.defer(record(:rolled_back))
            Repo.rollback(:nope)
          end)
        end)

      assert result == {:error, :nope}
      refute_received {:emitted, _tag}
      refute AfterCommit.holding?()
    end

    test "drops deferred emits when the function returns an error" do
      assert {:error, :refused} =
               AfterCommit.after_commit(fn ->
                 AfterCommit.defer(record(:refused))
                 {:error, :refused}
               end)

      refute_received {:emitted, _tag}
    end

    test "drops deferred emits and stops holding when the function raises" do
      assert_raise RuntimeError, fn ->
        AfterCommit.after_commit(fn ->
          AfterCommit.defer(record(:raised))
          raise "boom"
        end)
      end

      refute_received {:emitted, _tag}
      refute AfterCommit.holding?()

      :later |> record() |> AfterCommit.defer()
      assert_received {:emitted, :later}
    end

    test "emits nothing when nothing was deferred" do
      assert {:ok, :quiet} = AfterCommit.after_commit(fn -> {:ok, :quiet} end)
      refute_received {:emitted, _tag}
    end

    test "a nested after_commit restores the outer queue and its flush waits for the outer commit" do
      test_pid = self()

      result =
        AfterCommit.after_commit(fn ->
          AfterCommit.defer(record(:outer))

          inner =
            AfterCommit.after_commit(fn ->
              AfterCommit.defer(record(:inner))
              {:ok, :inner}
            end)

          send(test_pid, {:after_inner, AfterCommit.holding?()})
          {:error, inner}
        end)

      assert result == {:error, {:ok, :inner}}
      assert_received {:after_inner, true}
      refute_received {:emitted, _tag}
      refute AfterCommit.holding?()
    end

    test "a nested after_commit's emits are flushed with the outer ones on commit" do
      {:ok, :outer} =
        AfterCommit.after_commit(fn ->
          AfterCommit.defer(record(:outer))
          {:ok, :inner} = AfterCommit.after_commit(fn -> defer_ok(record(:inner)) end)
          {:ok, :outer}
        end)

      assert_received {:emitted, :outer}
      assert_received {:emitted, :inner}
    end

    test "the hold queue is per process" do
      test_pid = self()

      AfterCommit.after_commit(fn ->
        AfterCommit.defer(record(:mine))

        # Another process is not holding, so its emit runs straight away, and
        # its own after_commit neither flushes nor drops this process's queue.
        fn ->
          send(test_pid, {:other_holding, AfterCommit.holding?()})
          AfterCommit.defer(fn -> send(test_pid, {:emitted, :theirs}) end)
          AfterCommit.after_commit(fn -> {:error, :theirs_failed} end)
          AfterCommit.after_commit(fn -> {:ok, :theirs_committed} end)
        end
        |> Task.async()
        |> Task.await()

        assert_received {:other_holding, false}
        assert_received {:emitted, :theirs}
        refute_received {:emitted, :mine}
        {:ok, :mine}
      end)

      assert_received {:emitted, :mine}
    end
  end

  defp defer_ok(emit) do
    AfterCommit.defer(emit)
    {:ok, :inner}
  end
end
