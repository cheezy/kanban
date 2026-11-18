defmodule KanbanWeb.ShownSecret do
  @moduledoc """
  A newly created secret held in a LiveView assign so it can be shown once.

  Its Inspect implementation prints no fields, so a crash report or debug log
  that inspects the LiveView's state shows only `#KanbanWeb.ShownSecret<...>`,
  never the value (D442, following D437). Formatting that bypasses Inspect,
  such as `inspect(struct, structs: false)` or Erlang's `~p`, would still print
  it. Templates read the value with `.value`.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}
end
