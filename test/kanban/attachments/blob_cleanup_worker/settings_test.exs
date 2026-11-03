defmodule Kanban.Attachments.BlobCleanupWorker.SettingsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kanban.Attachments.BlobCleanupWorker.Settings

  @config Path.expand("../../../../config/config.exs", __DIR__)

  describe "check!/1" do
    test "accepts absent settings and positive integers within the timeout" do
      for settings <- [
            [],
            [batch_size: 200],
            [max_run_seconds: 600],
            [batch_size: 1, max_run_seconds: 1],
            [max_run_seconds: 1799]
          ] do
        assert Settings.check!(settings) == :ok, "expected #{inspect(settings)} to pass"
      end
    end

    test "refuses a batch_size that is not a positive integer, naming the setting" do
      for value <- [0, -1, "200", 1.5, nil, :lots] do
        assert_raise ArgumentError,
                     ~r/BlobCleanupWorker: batch_size must be a positive integer/,
                     fn ->
                       Settings.check!(batch_size: value)
                     end
      end
    end

    test "refuses a max_run_seconds that is not positive or reaches the job timeout" do
      for value <- [0, -5, 1800, 7200, "600", nil] do
        assert_raise ArgumentError,
                     ~r/max_run_seconds must be a positive integer below the job timeout of 1800 seconds/,
                     fn ->
                       Settings.check!(max_run_seconds: value)
                     end
      end
    end

    test "refuses settings that are not a keyword list" do
      for settings <- [%{batch_size: 200}, nil, [200], "batch_size: 200"] do
        assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
          Settings.check!(settings)
        end
      end
    end

    test "the settings config/config.exs ships pass it in every environment" do
      for env <- [:dev, :test, :prod] do
        settings =
          @config
          |> Config.Reader.read!(env: env)
          |> get_in([:kanban, Kanban.Attachments.BlobCleanupWorker])

        assert Settings.check!(settings || []) == :ok
      end
    end

    test "Kanban.Application checks them before starting the supervision tree" do
      source = "../../../../lib/kanban/application.ex" |> Path.expand(__DIR__) |> File.read!()
      [before_start, _rest] = String.split(source, "|> Supervisor.start_link(opts)", parts: 2)

      assert before_start =~ "Kanban.Attachments.BlobCleanupWorker.Settings.check!()"
    end
  end

  describe "batch_size/1 and budget_ms/1" do
    test "use a valid value, the default when absent, and warn when a value is invalid" do
      assert Settings.batch_size(batch_size: 7) == 7
      assert Settings.batch_size([]) == 200
      assert Settings.budget_ms(max_run_seconds: 5) == 5_000
      assert Settings.budget_ms([]) == 600_000

      log =
        capture_log(fn ->
          assert Settings.batch_size(batch_size: 0) == 200
          assert Settings.budget_ms(max_run_seconds: 7200) == 600_000
        end)

      assert log =~ "batch_size must be a positive integer; using 200"
      assert log =~ "max_run_seconds must be a positive integer below the job timeout"
    end
  end

  describe "run_time/2" do
    test "honours a now argument in the test environment, with microsecond precision" do
      log =
        capture_log(fn ->
          assert Settings.run_time(%{"now" => "2026-11-01T12:00:00Z"}, :test) ==
                   ~U[2026-11-01 12:00:00.000000Z]
        end)

      refute log =~ "ignored"
    end

    test "ignores a now argument outside the test environment, without logging it" do
      for env <- [:prod, :dev, nil] do
        log =
          capture_log(fn ->
            time = Settings.run_time(%{"now" => "2099-01-01T00:00:00Z"}, env)
            assert DateTime.diff(DateTime.utc_now(), time, :second) in 0..5
            assert {_, 6} = time.microsecond
          end)

        assert log =~ "ignored a now job argument outside the test environment"
        refute log =~ "2099"
      end
    end

    test "ignores a malformed now argument with a warning, and uses the clock with none" do
      for value <- ["tomorrow", "2026-13-01T00:00:00Z", 42, nil] do
        log =
          capture_log(fn ->
            time = Settings.run_time(%{"now" => value}, :test)
            assert DateTime.diff(DateTime.utc_now(), time, :second) in 0..5
          end)

        assert log =~ "ignored a now job argument that is not an ISO 8601 time"
        refute log =~ "tomorrow"
      end

      log = capture_log(fn -> Settings.run_time(%{}, :prod) end)
      refute log =~ "ignored"
    end
  end
end
