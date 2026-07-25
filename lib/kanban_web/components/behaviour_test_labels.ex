defmodule KanbanWeb.BehaviourTestLabels do
  @moduledoc """
  Translated display labels for the behaviour/test-matrix vocabularies.

  The canonical values live in `Kanban.Schemas.Task.BehaviourTestRow`; this
  module only decides how they are *shown*. Both the task form's selects and
  the task detail view read from here so the two surfaces cannot drift.

  Labels are translated, values are not: a stored row always carries the
  canonical English string the changeset validates against.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Schemas.Task.BehaviourTestRow

  @doc "`{label, value}` option tuples for the seven fixed categories, in canonical order."
  def category_options do
    Enum.map(BehaviourTestRow.categories(), &{category_label(&1), &1})
  end

  @doc "`{label, value}` option tuples for the row statuses, in canonical order."
  def status_options do
    Enum.map(BehaviourTestRow.statuses(), &{status_label(&1), &1})
  end

  # Each canonical value is matched literally so gettext can extract every
  # msgid; a runtime-interpolated gettext/1 would extract nothing.
  @doc "Translated label for a category value; unknown values pass through unchanged."
  def category_label("Happy path"), do: gettext("Happy path")
  def category_label("Boundary"), do: gettext("Boundary")
  def category_label("Error / exception"), do: gettext("Error / exception")
  def category_label("Null / empty"), do: gettext("Null / empty")
  def category_label("Concurrency"), do: gettext("Concurrency")
  def category_label("Lifecycle / wiring"), do: gettext("Lifecycle / wiring")
  def category_label("Contract / serialization"), do: gettext("Contract / serialization")
  def category_label(category), do: category

  @doc "Translated label for a status value; unknown values pass through unchanged."
  def status_label("planned"), do: gettext("Planned")
  def status_label("passing"), do: gettext("Passing")
  def status_label("failing"), do: gettext("Failing")
  def status_label("not_applicable"), do: gettext("Not applicable")
  def status_label(status), do: status
end
