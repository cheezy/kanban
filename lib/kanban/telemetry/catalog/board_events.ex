defmodule Kanban.Telemetry.Catalog.BoardEvents do
  @moduledoc """
  The board, board membership and column events in `Kanban.Telemetry.Catalog`.

  Board changes are emitted by `Kanban.Boards`, membership changes by
  `Kanban.Boards.BoardTelemetry` once the change has committed, and column
  changes by `Kanban.Columns`. `[:kanban, :api, :token_bulk_revoked]` lives
  here too, because a membership change is what revokes the tokens. Metadata
  carries ids, access levels and changed field names only, never a board or
  column name. `Kanban.Telemetry.Catalog` appends these entries to its own
  list; nothing else should call this module.
  """

  @events [
    %{
      name: [:kanban, :board, :creation],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id],
      description: "A board was created.",
      legacy: true,
      metrics: [sum: :count],
      persist: true
    },
    %{
      name: [:kanban, :board, :updated],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :actor_user_id, :fields],
      description:
        "A board owner changed a board's settings. fields lists the changed field names, never their values.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :board, :deleted],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :actor_user_id],
      description: "A board owner deleted a board, with its columns, tasks and memberships.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :board, :field_visibility_changed],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :actor_user_id, :fields],
      description:
        "A board owner changed which task fields the board shows. fields lists the toggled field names.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :board, :member_added],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id, :access, :actor_user_id],
      description:
        "A user was given access to a board. user_id is the member, actor_user_id the owner who added them.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :board, :member_removed],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id, :access, :actor_user_id],
      description: "A user was removed from a board. access is the level they held.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :board, :member_access_changed],
      kind: :event,
      domain: :board,
      measurements: [:count],
      metadata: [:board_id, :user_id, :from_access, :to_access, :actor_user_id],
      description: "A board member's access level changed.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :token_bulk_revoked],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:board_id, :user_id, :actor_user_id, :reason],
      description:
        "A member's API tokens for a board were revoked because they were removed (reason :member_removed) or set to read_only (:read_only_access). count is the number revoked and may be 0.",
      legacy: false,
      metrics: [sum: :count],
      persist: false
    },
    %{
      name: [:kanban, :column, :created],
      kind: :event,
      domain: :column,
      measurements: [:count],
      metadata: [:board_id, :column_id, :actor_user_id],
      description: "A board owner added a column.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :column, :updated],
      kind: :event,
      domain: :column,
      measurements: [:count],
      metadata: [:board_id, :column_id, :actor_user_id, :fields],
      description:
        "A board owner changed a column. fields lists the changed field names, never their values.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :column, :deleted],
      kind: :event,
      domain: :column,
      measurements: [:count],
      metadata: [:board_id, :column_id],
      description: "A column was deleted, along with its tasks.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :column, :reordered],
      kind: :event,
      domain: :column,
      measurements: [:count, :column_count],
      metadata: [:board_id],
      description:
        "A board's columns were reordered. column_count is the number of column ids given.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    }
  ]

  @doc """
  Returns the board, membership and column entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
