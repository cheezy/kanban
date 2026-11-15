defmodule KanbanWeb.LocalTime do
  @moduledoc """
  The viewer's current timezone for the running process.

  `KanbanWeb.Plugs.Timezone` sets it for every browser request and
  `KanbanWeb.TimezoneOnMount` for every LiveView process, the same way
  `Gettext.put_locale/2` holds the current locale. Renderers read it with
  `timezone/0` instead of having the zone threaded through as an attr.

  The value put here has already been validated against the tz database. It is
  only for display and day bucketing, and is never an authorization input.
  """

  @default "Etc/UTC"
  @key {__MODULE__, :timezone}

  @doc """
  Sets the current process's viewer timezone.
  """
  @spec put_timezone(String.t()) :: :ok
  def put_timezone(timezone) when is_binary(timezone) do
    Process.put(@key, timezone)
    :ok
  end

  @doc """
  The current process's viewer timezone, or `"Etc/UTC"` when none was put.
  """
  @spec timezone() :: String.t()
  def timezone, do: Process.get(@key, @default)
end
