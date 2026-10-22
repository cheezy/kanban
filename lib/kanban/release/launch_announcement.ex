defmodule Kanban.Release.LaunchAnnouncement do
  @moduledoc """
  The operator path behind `Kanban.Release.send_launch_announcement/1` (W2416).

  A release command started with `bin/kanban eval` has no running Oban, and
  `Oban.insert/2` needs one. So `send/1` starts the `:oban` application (its
  registry, which `eval` does not start) and an insert-only instance — no
  queues, no plugins, no peer, no stager — when none is registered under the
  name, runs the fan-out through it and stops the instance again. The jobs
  land in the database, where the running app's `:notifications` queue sends
  them. Under `bin/kanban rpc`, or in tests, the existing instance is used as
  is.

  Under `bin/kanban eval` the app's telemetry handlers are not running, so
  `[:kanban, :announcement, :fanout_completed]` reaches no handler and is not
  stored; the returned counts are the record of that run. The per-user
  `email_sent` events come from the running app and are recorded as usual.
  """

  alias Kanban.Notifications.Announcement

  @insert_only [queues: false, plugins: false, peer: false, stager: false]

  @doc """
  Runs `Kanban.Notifications.Announcement.fan_out/2` for `opts[:key]`.

  Options: `:key` (required), `:dry_run` (`true` or `false`, default `false`)
  and `:oban`, the instance name to use or start (default `Oban`, a test
  seam). Any other option, such as a misspelled `dryrun:`, raises
  `ArgumentError` before anything is sent.
  """
  @spec send(keyword()) :: {:ok, Announcement.result()} | {:error, :unknown_announcement}
  def send(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:key, dry_run: false, oban: Oban])
    name = opts[:oban]

    with_oban(name, fn ->
      Announcement.fan_out(opts[:key], Keyword.take(opts, [:dry_run, :oban]))
    end)
  end

  defp with_oban(name, fun) do
    {:ok, _apps} = Application.ensure_all_started(:oban)

    if Oban.whereis(name) do
      fun.()
    else
      {:ok, pid} = name |> oban_config() |> Oban.start_link()

      try do
        fun.()
      after
        Supervisor.stop(pid)
      end
    end
  end

  defp oban_config(name) do
    :kanban
    |> Application.fetch_env!(Oban)
    |> Keyword.merge(@insert_only)
    |> Keyword.put(:name, name)
  end
end
