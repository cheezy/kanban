defmodule Kanban.Metrics.BusinessTimeTest do
  use ExUnit.Case, async: true

  alias Kanban.Metrics.BusinessTime

  doctest Kanban.Metrics.BusinessTime

  @hour 3600

  describe "business_seconds/2" do
    test "returns the full interval when no weekend is touched" do
      # Tuesday 09:00 -> Wednesday 09:00
      assert BusinessTime.business_seconds(
               ~U[2026-02-03 09:00:00Z],
               ~U[2026-02-04 09:00:00Z]
             ) == 24 * @hour
    end

    test "returns the full interval for a sub-day weekday wait" do
      # Friday 09:00 -> Friday 17:00
      assert BusinessTime.business_seconds(
               ~U[2026-01-30 09:00:00Z],
               ~U[2026-01-30 17:00:00Z]
             ) == 8 * @hour
    end

    test "subtracts only the weekend portion of a Saturday-to-Monday wait" do
      # Saturday 20:00 -> Monday 08:00 is 36 hours, 28 of them on the weekend.
      # The previous whole-day subtraction collapsed this case to zero.
      assert BusinessTime.business_seconds(
               ~U[2026-01-31 20:00:00Z],
               ~U[2026-02-02 08:00:00Z]
             ) == 8 * @hour
    end

    test "subtracts both weekend days from a Friday-to-Monday wait" do
      # Friday 18:00 -> Monday 10:00 is 64 hours, 48 of them on the weekend.
      assert BusinessTime.business_seconds(
               ~U[2026-01-30 18:00:00Z],
               ~U[2026-02-02 10:00:00Z]
             ) == 16 * @hour
    end

    test "returns zero when the interval lies entirely within a weekend" do
      # Saturday 10:00 -> Sunday 14:00
      assert BusinessTime.business_seconds(
               ~U[2026-01-31 10:00:00Z],
               ~U[2026-02-01 14:00:00Z]
             ) == 0
    end

    test "clamps out-of-order timestamps to zero" do
      assert BusinessTime.business_seconds(
               ~U[2026-02-02 08:00:00Z],
               ~U[2026-01-31 20:00:00Z]
             ) == 0
    end

    test "returns zero for a zero-length interval" do
      assert BusinessTime.business_seconds(
               ~U[2026-02-03 09:00:00Z],
               ~U[2026-02-03 09:00:00Z]
             ) == 0
    end

    test "accepts NaiveDateTime arguments as UTC" do
      assert BusinessTime.business_seconds(
               ~N[2026-01-31 20:00:00],
               ~N[2026-02-02 08:00:00]
             ) == 8 * @hour
    end
  end

  describe "to_utc_datetime/1" do
    test "passes a DateTime through unchanged" do
      dt = ~U[2026-02-03 09:00:00Z]
      assert BusinessTime.to_utc_datetime(dt) == dt
    end

    test "interprets a NaiveDateTime as UTC" do
      assert BusinessTime.to_utc_datetime(~N[2026-02-03 09:00:00]) == ~U[2026-02-03 09:00:00Z]
    end
  end
end
