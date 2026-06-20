defmodule Kanban.Agents.Agent do
  @moduledoc """
  Represents an AI agent derived from Task records.

  Agents are not persisted as their own schema. They are derived from the
  distinct non-nil values of `created_by_agent` and `completed_by_agent`
  across the visible Task set.

  Identity is the composite of `name` and `owner_key` (W1244): two agents that
  share a `name` but are run by different humans are distinct agents. `owner_key`
  is the owning user's id as a string, or `"none"` when no human owner resolves
  (so same-named agents with no owner stay a single entry). Group, select, and
  filter on `{name, owner_key}` — never on `name` alone.

  `status` (`:working` / `:waiting` / `:idle`) and `stuck` are independent
  dimensions: `stuck` flags an agent that has stalled mid-work or has been
  sitting in review past a threshold, regardless of which active status it
  carries. The stuck threshold and derivation live in `Kanban.Agents`.

  `last_active_at` is the agent's most recent activity timestamp (the same
  recency rule used to order the roster), and `dormant` flags an agent whose
  most recent activity is older than the dormancy threshold. The threshold and
  derivation live in `Kanban.Agents`. Dormant agents are excluded from the
  fleet-health rollup so its counts reflect only live agents.
  """

  @type status :: :working | :waiting | :idle

  @type t :: %__MODULE__{
          name: String.t(),
          owner_key: String.t(),
          owner: map() | nil,
          status: status(),
          stuck: boolean(),
          last_active_at: NaiveDateTime.t() | nil,
          dormant: boolean(),
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
    :last_active_at,
    owner_key: "none",
    stuck: false,
    dormant: false,
    capabilities: [],
    today: 0,
    last_7d: 0,
    success_rate: 0.0,
    claim_count: 0
  ]
end
