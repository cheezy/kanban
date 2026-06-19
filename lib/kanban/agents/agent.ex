defmodule Kanban.Agents.Agent do
  @moduledoc """
  Represents an AI agent derived from Task records.

  Agents are not persisted as their own schema. They are derived from the
  distinct non-nil values of `created_by_agent` and `completed_by_agent`
  across the visible Task set.

  `status` (`:working` / `:waiting` / `:idle`) and `stuck` are independent
  dimensions: `stuck` flags an agent that has stalled mid-work or has been
  sitting in review past a threshold, regardless of which active status it
  carries. The stuck threshold and derivation live in `Kanban.Agents`.
  """

  @type status :: :working | :waiting | :idle

  @type t :: %__MODULE__{
          name: String.t(),
          owner: map() | nil,
          status: status(),
          stuck: boolean(),
          current_task: %{identifier: String.t(), title: String.t()} | nil,
          capabilities: [String.t()],
          today: non_neg_integer(),
          last_7d: non_neg_integer(),
          success_rate: float(),
          claim_count: non_neg_integer()
        }

  defstruct [
    :name,
    :owner,
    :status,
    :current_task,
    stuck: false,
    capabilities: [],
    today: 0,
    last_7d: 0,
    success_rate: 0.0,
    claim_count: 0
  ]
end
