defmodule KanbanWeb.LocalTimeTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.LocalTime
  alias KanbanWeb.LocalTime.Names

  @dt ~U[2026-11-10 23:56:00Z]

  defp in_locale(locale, fun), do: Gettext.with_locale(KanbanWeb.Gettext, locale, fun)

  describe "put_timezone/1 and timezone/0" do
    test "defaults to Etc/UTC and returns the zone that was put" do
      assert LocalTime.timezone() == "Etc/UTC"
      assert LocalTime.put_timezone("Asia/Tokyo") == :ok
      assert LocalTime.timezone() == "Asia/Tokyo"
    end
  end

  describe "format/2" do
    test "formats a UTC datetime in the viewer's zone" do
      LocalTime.put_timezone("America/Toronto")

      in_locale("en", fn ->
        assert LocalTime.format(@dt, :datetime) == "November 10, 2026 at 6:56 PM"
      end)
    end

    test "handles a DST transition" do
      LocalTime.put_timezone("America/Toronto")
      before_fall_back = ~U[2026-11-01 05:30:00Z]
      after_fall_back = ~U[2026-11-01 06:30:00Z]

      in_locale("en", fn ->
        assert LocalTime.format(before_fall_back, :time) == "1:30 AM"
        assert LocalTime.format(after_fall_back, :time) == "1:30 AM"
        assert LocalTime.format_full(before_fall_back) == "November 1, 2026 at 1:30 AM EDT"
        assert LocalTime.format_full(after_fall_back) == "November 1, 2026 at 1:30 AM EST"
      end)
    end

    test "falls back to UTC for an unknown zone" do
      in_locale("en", fn ->
        assert LocalTime.format(@dt, :time, "Nope/Zone") == "11:56 PM"
        assert LocalTime.format(@dt, :time, String.duplicate("A", 65)) == "11:56 PM"
        assert LocalTime.format(@dt, :time, nil) == "11:56 PM"
        assert LocalTime.format(@dt, :time, 42) == "11:56 PM"

        LocalTime.put_timezone("Not/AZone")
        assert LocalTime.format(@dt, :time) == "11:56 PM"
        assert LocalTime.format_full(@dt) == "November 10, 2026 at 11:56 PM UTC"
      end)
    end

    test "returns empty for nil" do
      for style <- LocalTime.styles() do
        assert LocalTime.format(nil, style) == ""
        assert LocalTime.format(nil, style, "Asia/Tokyo") == ""
      end

      assert LocalTime.format_full(nil) == ""
      assert LocalTime.utc_iso8601(nil) == ""
    end

    test "uses the process zone with no zone set as UTC" do
      in_locale("en", fn ->
        assert LocalTime.format(@dt, :datetime) == "November 10, 2026 at 11:56 PM"
      end)
    end

    test "renders midnight and noon on the 12-hour clock" do
      in_locale("en", fn ->
        assert LocalTime.format(~U[2026-11-10 00:05:00Z], :time) == "12:05 AM"
        assert LocalTime.format(~U[2026-11-10 12:05:00Z], :time) == "12:05 PM"
      end)
    end

    test "raises for an unknown style" do
      # Read at runtime so the type checker does not flag the deliberate misuse.
      style = Application.get_env(:kanban, :local_time_test_unknown_style, :nope)

      assert_raise FunctionClauseError, fn -> LocalTime.format(@dt, style) end
      assert_raise FunctionClauseError, fn -> LocalTime.format(nil, style) end
    end
  end

  describe "styles in every locale" do
    @expected %{
      "en" => %{
        datetime: "November 10, 2026 at 6:56 PM",
        date: "November 10, 2026",
        short_date: "Nov 10, 2026",
        short_datetime: "Nov 10, 6:56 PM",
        month_day: "Nov 10",
        time: "6:56 PM",
        month_year: "November 2026",
        weekday_date: "Tue, Nov 10"
      },
      "de" => %{
        datetime: "10. November 2026, 18:56",
        date: "10. November 2026",
        short_date: "10. Nov. 2026",
        short_datetime: "10. Nov., 18:56",
        month_day: "10. Nov.",
        time: "18:56",
        month_year: "November 2026",
        weekday_date: "Di., 10. Nov."
      },
      "es" => %{
        datetime: "10 de noviembre de 2026, 18:56",
        date: "10 de noviembre de 2026",
        short_date: "10 nov 2026",
        short_datetime: "10 nov, 18:56",
        month_day: "10 nov",
        time: "18:56",
        month_year: "noviembre de 2026",
        weekday_date: "mar 10 nov"
      },
      "fr" => %{
        datetime: "10 novembre 2026 à 18:56",
        date: "10 novembre 2026",
        short_date: "10 nov. 2026",
        short_datetime: "10 nov. à 18:56",
        month_day: "10 nov.",
        time: "18:56",
        month_year: "novembre 2026",
        weekday_date: "mar. 10 nov."
      },
      "pt" => %{
        datetime: "10 de novembro de 2026 às 18:56",
        date: "10 de novembro de 2026",
        short_date: "10 de nov. de 2026",
        short_datetime: "10 de nov., 18:56",
        month_day: "10 de nov.",
        time: "18:56",
        month_year: "novembro de 2026",
        weekday_date: "ter., 10 nov."
      },
      "ja" => %{
        datetime: "2026年11月10日 18:56",
        date: "2026年11月10日",
        short_date: "2026/11/10",
        short_datetime: "11月10日 18:56",
        month_day: "11月10日",
        time: "18:56",
        month_year: "2026年11月",
        weekday_date: "11月10日 (火)"
      },
      "zh" => %{
        datetime: "2026年11月10日 18:56",
        date: "2026年11月10日",
        short_date: "2026/11/10",
        short_datetime: "11月10日 18:56",
        month_day: "11月10日",
        time: "18:56",
        month_year: "2026年11月",
        weekday_date: "11月10日 (周二)"
      }
    }

    test "every known locale has an expectation" do
      assert @expected |> Map.keys() |> Enum.sort() ==
               KanbanWeb.Gettext |> Gettext.known_locales() |> Enum.sort()
    end

    for {locale, styles} <- @expected, {style, text} <- styles do
      @locale locale
      @style style
      @text text
      test "#{locale} renders #{style}" do
        LocalTime.put_timezone("America/Toronto")
        in_locale(@locale, fn -> assert LocalTime.format(@dt, @style) == @text end)
      end
    end

    test "Spanish, French and Portuguese month names are lower case" do
      for locale <- ["es", "fr", "pt"] do
        in_locale(locale, fn ->
          for month <- 1..12 do
            name = Names.month(month)
            assert name == String.downcase(name), "#{locale} month #{month}: #{name}"
          end

          for day <- 1..7 do
            name = Names.weekday(day)
            assert name == String.downcase(name), "#{locale} weekday #{day}: #{name}"
          end
        end)
      end
    end

    test "ja zero-pads the short date and zh does not" do
      march = ~D[2026-03-05]
      in_locale("ja", fn -> assert LocalTime.format(march, :short_date) == "2026/03/05" end)
      in_locale("zh", fn -> assert LocalTime.format(march, :short_date) == "2026/3/5" end)
    end

    test "an unsupported locale falls back to en patterns" do
      LocalTime.put_timezone("America/Toronto")

      in_locale("xx", fn ->
        assert LocalTime.format(@dt, :datetime) == "November 10, 2026 at 6:56 PM"
        assert LocalTime.format(@dt, :weekday_date) == "Tue, Nov 10"
      end)
    end
  end

  describe "Names" do
    test "every name is translated in every locale" do
      for locale <- Gettext.known_locales(KanbanWeb.Gettext) do
        in_locale(locale, fn ->
          names =
            Enum.map(1..12, &Names.month/1) ++
              Enum.map(1..12, &Names.month_abbr/1) ++
              Enum.map(1..7, &Names.weekday/1) ++
              Enum.map(1..7, &Names.weekday_abbr/1) ++
              [Names.am_pm(:am), Names.am_pm(:pm)]

          assert Enum.all?(names, &(is_binary(&1) and &1 != "")), locale
          assert 1..12 |> Enum.map(&Names.month/1) |> Enum.uniq() |> length() == 12, locale
          assert 1..7 |> Enum.map(&Names.weekday/1) |> Enum.uniq() |> length() == 7, locale
        end)
      end
    end

    test "weekday and abbreviated month names are translated away from English" do
      names = fn ->
        Enum.map(1..7, &Names.weekday/1) ++
          Enum.map(1..7, &Names.weekday_abbr/1) ++ Enum.map(1..12, &Names.month_abbr/1)
      end

      english = in_locale("en", names)

      for locale <- Gettext.known_locales(KanbanWeb.Gettext) -- ["en"] do
        translated = in_locale(locale, names)

        for {en, tr} <- Enum.zip(english, translated) do
          assert en != tr, "#{locale} left #{en} untranslated"
        end
      end
    end

    test "English names fall back to the msgids" do
      in_locale("en", fn ->
        assert Enum.map(1..12, &Names.month/1) ==
                 ~w(January February March April May June July August September October November December)

        assert Enum.map(1..12, &Names.month_abbr/1) ==
                 ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

        assert Enum.map(1..7, &Names.weekday/1) ==
                 ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

        assert Enum.map(1..7, &Names.weekday_abbr/1) == ~w(Mon Tue Wed Thu Fri Sat Sun)
        assert {Names.am_pm(:am), Names.am_pm(:pm)} == {"AM", "PM"}
      end)
    end

    test "samples of translated names" do
      in_locale("de", fn ->
        assert Names.month(3) == "März"
        assert Names.month_abbr(5) == "Mai"
        assert Names.weekday(7) == "Sonntag"
      end)

      in_locale("es", fn -> assert Names.am_pm(:pm) == "p. m." end)
      in_locale("fr", fn -> assert Names.month(8) == "août" end)
      in_locale("pt", fn -> assert Names.weekday_abbr(2) == "ter." end)

      in_locale("ja", fn ->
        assert Names.am_pm(:am) == "午前"
        assert Names.am_pm(:pm) == "午後"
        assert Names.weekday(1) == "月曜日"
      end)

      in_locale("zh", fn ->
        assert Names.month(5) == "五月"
        assert Names.am_pm(:pm) == "下午"
        assert Names.weekday_abbr(7) == "周日"
      end)
    end
  end

  describe "value types" do
    test "a Date is formatted without a zone shift" do
      LocalTime.put_timezone("Pacific/Kiritimati")

      in_locale("en", fn ->
        assert LocalTime.format(~D[2026-11-10], :date) == "November 10, 2026"
        assert LocalTime.format(~D[2026-11-10], :weekday_date) == "Tue, Nov 10"
        assert LocalTime.format(~D[2026-11-10], :datetime) == "November 10, 2026"
        assert LocalTime.format(~D[2026-11-10], :time) == "November 10, 2026"
        assert LocalTime.format(~D[2026-11-10], :short_datetime) == "Nov 10, 2026"
        assert LocalTime.format(~D[2026-11-10], :month_day) == "Nov 10"
        assert LocalTime.format_full(~D[2026-11-10]) == "November 10, 2026"
      end)
    end

    test "a NaiveDateTime is treated as UTC" do
      LocalTime.put_timezone("America/Toronto")

      in_locale("en", fn ->
        assert LocalTime.format(~N[2026-11-10 23:56:00], :datetime) ==
                 "November 10, 2026 at 6:56 PM"

        assert LocalTime.format_full(~N[2026-11-10 23:56:00]) ==
                 "November 10, 2026 at 6:56 PM EST"
      end)
    end

    test "format/3 with an explicit zone ignores the process-level zone" do
      LocalTime.put_timezone("America/Toronto")

      in_locale("en", fn ->
        assert LocalTime.format(@dt, :datetime, "Asia/Tokyo") == "November 11, 2026 at 8:56 AM"
        assert LocalTime.format_full(@dt, "Asia/Tokyo") == "November 11, 2026 at 8:56 AM JST"
      end)
    end

    test "a non-UTC DateTime is shifted from its own offset" do
      tokyo = DateTime.shift_zone!(@dt, "Asia/Tokyo")
      LocalTime.put_timezone("America/Toronto")
      in_locale("en", fn -> assert LocalTime.format(tokyo, :time) == "6:56 PM" end)
    end

    test "dates before 1970 and after 2100" do
      LocalTime.put_timezone("America/Toronto")

      in_locale("en", fn ->
        assert LocalTime.format(~U[1969-07-20 20:17:00Z], :datetime) ==
                 "July 20, 1969 at 4:17 PM"

        assert LocalTime.format(~U[2150-07-01 12:00:00Z], :datetime) ==
                 "July 1, 2150 at 8:00 AM"

        assert LocalTime.format(~D[1901-01-01], :date) == "January 1, 1901"
        assert LocalTime.format(~D[2150-01-01], :short_date) == "Jan 1, 2150"
      end)
    end
  end

  describe "utc_iso8601/1" do
    test "renders ISO 8601 UTC whatever the locale or zone" do
      LocalTime.put_timezone("Asia/Tokyo")

      in_locale("ja", fn ->
        assert LocalTime.utc_iso8601(@dt) == "2026-11-10T23:56:00Z"

        assert @dt |> DateTime.shift_zone!("Asia/Tokyo") |> LocalTime.utc_iso8601() ==
                 "2026-11-10T23:56:00Z"

        assert LocalTime.utc_iso8601(~N[2026-11-10 23:56:00]) == "2026-11-10T23:56:00Z"
        assert LocalTime.utc_iso8601(~D[2026-11-10]) == "2026-11-10"
      end)
    end
  end
end
