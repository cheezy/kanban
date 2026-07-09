defmodule Kanban.Agents.Event do
  @moduledoc """
  Represents a derived activity event for an agent.

  Events are synthesized from Task timestamps — `inserted_at` (create),
  `claimed_at` (claim), `completed_at` (complete), and `reviewed_at`
  (review). No event records are persisted.
  """

  @type kind :: :claim | :complete | :review | :create | :unclaim

  @type t :: %__MODULE__{
          kind: kind(),
          actor: String.t() | nil,
          owner: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          parent_id: integer() | nil,
          at: DateTime.t(),
          move_to: atom() | nil,
          flag: atom() | nil,
          cycle_time_minutes: non_neg_integer() | nil
        }

  defstruct [
    :kind,
    :actor,
    :owner,
    :identifier,
    :title,
    :parent_id,
    :at,
    :move_to,
    :flag,
    :cycle_time_minutes
  ]
end
