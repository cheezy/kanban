defmodule KanbanWeb.API.CompletionResultGateTest do
  use ExUnit.Case, async: false

  alias KanbanWeb.API.CompletionResultGate

  # CompletionResultGate.strict?/0 reads the `:strict_completion_validation`
  # Application env key. This is the same key flipped by the
  # `STRIDE_STRICT_COMPLETION_VALIDATION=true` env-var branch in
  # `config/runtime.exs`. Asserting that the two ends of that wire agree
  # is the only practical way to catch the class of bug where the runtime
  # toggle sets the wrong value (which is exactly what motivated this
  # test — the prior block hard-coded `false` on the truthy branch).
  describe "strict?/0" do
    setup do
      previous = Application.get_env(:kanban, :strict_completion_validation, false)
      on_exit(fn -> Application.put_env(:kanban, :strict_completion_validation, previous) end)
      :ok
    end

    test "returns false when the application env is false (grace mode)" do
      Application.put_env(:kanban, :strict_completion_validation, false)
      refute CompletionResultGate.strict?()
    end

    test "returns true when the application env is true (strict mode)" do
      Application.put_env(:kanban, :strict_completion_validation, true)
      assert CompletionResultGate.strict?()
    end

    test "defaults to false when the key is absent" do
      Application.delete_env(:kanban, :strict_completion_validation)
      refute CompletionResultGate.strict?()
    end
  end
end
