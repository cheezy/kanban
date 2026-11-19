defmodule Kanban.Devices.IdempotencyKey do
  @moduledoc """
  An `Idempotency-Key` a device sent with one review decision, ready to look
  up and store (`Kanban.Devices.Nonces.idempotency_key/5`).

  It carries the device, the hash of the key with its action and task (never
  the key itself) and `render`, the function that turns the decided task into
  the JSON body the device is sent, so the stored result is exactly what the
  first request answered.
  """

  alias Kanban.Tasks.Task

  @enforce_keys [:device_id, :key_hash, :render]
  defstruct [:device_id, :key_hash, :render]

  @type t :: %__MODULE__{
          device_id: integer(),
          key_hash: String.t(),
          render: (Task.t() -> map())
        }

  defimpl Inspect do
    def inspect(%{device_id: device_id}, _opts),
      do: "#Kanban.Devices.IdempotencyKey<device_id: #{device_id}>"
  end
end
