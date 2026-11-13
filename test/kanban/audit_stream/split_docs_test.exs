defmodule Kanban.AuditStream.SplitDocsTest do
  @moduledoc """
  Keeps the docs that point at moved behaviour in step with where it lives
  (W2738). The send and record phases moved from
  `Kanban.AuditStream.DispatchWorker` to `Kanban.AuditStream.Send`, the rows
  both phases write to `Kanban.AuditStream.DispatchRows`, and the retention
  gap steps to `Kanban.AuditStream.Retention.Leases`, `.Snapshot` and
  `.Losses`. These tests fail if a doc stops naming the module that now
  does the work.
  """
  use ExUnit.Case, async: true

  alias Kanban.AuditStream.DestinationEvents
  alias Kanban.AuditStream.DispatchWorker
  alias Kanban.AuditStream.Gaps
  alias Kanban.AuditStream.Lease
  alias Kanban.AuditStream.Outcome
  alias Kanban.AuditStream.Retention

  defp moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => doc}, _meta, _docs} = Code.fetch_docs(module)
    doc
  end

  defp function_doc(module, name, arity) do
    {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, docs} = Code.fetch_docs(module)

    Enum.find_value(docs, fn
      {{:function, ^name, ^arity}, _anno, _signature, %{"en" => doc}, _meta} -> doc
      _entry -> nil
    end)
  end

  test "the worker's moduledoc names where the send, the record and the rows live" do
    doc = moduledoc(DispatchWorker)

    assert doc =~ "2. **Send** (`Kanban.AuditStream.Send`)"
    assert doc =~ "3. **Record** (`Kanban.AuditStream.Send`)"
    assert doc =~ "emitted by\n`Kanban.AuditStream.Send` after the outcome commits"
    assert doc =~ "`Kanban.AuditStream.DispatchRows`"
  end

  test "Outcome names the module that writes each plan" do
    doc = moduledoc(Outcome)

    assert doc =~ "`Kanban.AuditStream.DispatchWorker` reads the rows\nand writes what `halt/4`"
    assert doc =~ "`Kanban.AuditStream.Send` sends and\nwrites what `plan/5` returns"
  end

  test "the audit events are recorded from DispatchRows, not the worker" do
    doc = moduledoc(DestinationEvents)

    assert doc =~ "`Kanban.AuditStream.DispatchRows`"
    refute doc =~ "`Kanban.AuditStream.DispatchWorker`"
  end

  test "retention's gap and lease callers name Retention.Losses" do
    assert moduledoc(Gaps) =~ "The callers are `Kanban.AuditStream.Retention.Losses`,"

    assert function_doc(Lease, :owned, 2) =~
             "as `Kanban.AuditStream.Retention.Losses` does after a"
  end

  test "Retention's moduledoc names the three modules it orders" do
    doc = moduledoc(Retention)

    for module <- ["Retention.Leases", "Retention.Snapshot", "Retention.Losses"] do
      assert doc =~ "`Kanban.AuditStream.#{module}`"
    end
  end
end
