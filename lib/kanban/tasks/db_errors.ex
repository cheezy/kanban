defmodule Kanban.Tasks.DbErrors do
  @moduledoc """
  Defense-in-depth translation of raw database exceptions on the task API write
  paths into sanitized changeset errors.

  The per-field `varchar(255)` length validators (D81) keep oversized values
  from reaching the database on every *known* bounded column, and the W1412
  regression guard asserts that allow-list stays complete. This module is the
  runtime safety net behind those validators: if a future bounded column is ever
  added to a cast allow-list without a matching length validator, an oversized
  value would otherwise raise a `Postgrex.Error` with SQLSTATE 22001
  (`:string_data_right_truncation`) and surface as an HTTP 500. Wrapping the
  create / update / batch Repo calls with `translate_value_too_long/2` converts
  that single SQLSTATE into a clean 422 instead, without leaking the raw
  database message.

  Only 22001 is translated. Every other `Postgrex.Error` (and every other
  exception) propagates unchanged so unrelated database failures are never
  swallowed, and the batch `Ecto.Multi` rollback semantics are preserved — the
  transaction is already rolled back by Postgres before the exception reaches
  the rescue.
  """

  alias Ecto.Changeset
  alias Kanban.Tasks.Task

  # Sanitized, client-facing message: no field name, no Postgrex/SQL text.
  @value_too_long_message "is too long for one or more fields"

  @doc """
  Runs `run` and translates a Postgres 22001 (`:string_data_right_truncation`)
  raised inside it into an error tuple built by `on_error`, which receives the
  sanitized changeset from `value_too_long_changeset/0`.

  `on_error` lets each call site shape the tuple it needs — the single-task and
  update paths pass `&{:error, &1}`, while the goal/batch path passes
  `fn changeset -> {:error, :db, changeset} end` to match the 3-tuple its caller
  pattern-matches on. Any non-22001 `Postgrex.Error` (or any other exception) is
  re-raised, never swallowed.
  """
  def translate_value_too_long(run, on_error)
      when is_function(run, 0) and is_function(on_error, 1) do
    run.()
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :string_data_right_truncation}} ->
          on_error.(value_too_long_changeset())

        _ ->
          reraise error, __STACKTRACE__
      end
  end

  @doc """
  Builds a changeset whose only error is a sanitized `:base` "is too long for
  one or more fields" message — safe to render to API clients. It carries no
  field name and no raw database text, so the 422 body never leaks schema
  internals.
  """
  def value_too_long_changeset do
    %Task{}
    |> Changeset.change()
    |> Changeset.add_error(:base, @value_too_long_message)
  end
end
