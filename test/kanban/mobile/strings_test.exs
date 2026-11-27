defmodule Kanban.Mobile.StringsTest do
  @moduledoc """
  The native apps' strings: the `mobile` gettext domain and the per-locale
  copies generated from it (W2777).
  """
  use ExUnit.Case, async: true

  alias Expo.Message.Plural
  alias Expo.Message.Singular
  alias Expo.PO
  alias Kanban.Mobile.Strings

  @root Path.expand("../../..", __DIR__)
  @gettext Path.join(@root, "priv/gettext")
  @refresh_hint "is stale. Refresh it with: MIX_ENV=test mix mobile.strings"

  # The strings with no web page that says the same thing. The Sign in button
  # shares the web's "Sign in" msgid, but the web's Spanish and French nav link
  # is in title case and the app's button in sentence case, as iOS buttons are.
  # The shared views' readings and kinds (W2789), the Now tab (W2790) and the
  # Now screen (W2793) and its card actions (W2794) are the app's own words.
  @app_only ~w(
    sign_in_action sign_in_create_account sign_in_failed sign_in_locked_action
    sign_in_locked_message sign_in_locked_title sign_in_network_error sign_in_note
    sign_in_passcode_required sign_in_point_ready sign_in_point_review_face_id
    sign_in_point_review_passcode sign_in_point_review_touch_id sign_in_point_unblock
    sign_in_tagline sign_in_working
    update_required_action update_required_message update_required_title
    decision_kind_claim_expired decision_kind_hook_failed decision_kind_ready_empty
    decision_kind_released diff_line_added diff_line_removed diff_line_unchanged
    goal_hook_failed offline_banner progress_no_tasks verdict_failed verdict_not_assessed
    verdict_passed tab_now
    now_filter_all now_filter_reviews now_filter_problems now_filter_ready now_sorted
    now_empty now_loading now_offline_nothing now_needs_connection now_open_review
    now_move_to_backlog now_open_on_web now_view_attempt now_reply now_claim_expired
    now_hook_failed now_hook_failed_exit now_released_reason now_ready_empty_board
    now_header_summary
    now_moved_to_backlog now_reply_sent now_task_moved now_not_allowed now_action_failed
    now_reply_field now_reply_send now_reply_too_long now_attempt_title
    now_attempt_exit_code now_attempt_duration now_attempt_not_reported now_attempt_loading
    now_attempt_unavailable now_attempt_no_output
  )

  @plural_forms %{
    "de" => "nplurals=2; plural=(n != 1);",
    "en" => "nplurals=2; plural=(n != 1);",
    "es" => "nplurals=2; plural=(n != 1);",
    "fr" => "nplurals=2; plural=(n>1);",
    "ja" => "nplurals=1; plural=0;",
    "pt" => "nplurals=2; plural=(n != 1);",
    "zh" => "nplurals=1; plural=0;"
  }

  # Synthetic domains: a mobile.pot and one mobile.po per locale, written into
  # the test's tmp dir.
  defp header(nil), do: ~s(msgid ""\nmsgstr ""\n\n)
  defp header(plural_forms), do: ~s(msgid ""\nmsgstr ""\n"Plural-Forms: #{plural_forms}\\n"\n\n)

  defp entry(key, msgid, msgstr \\ ""),
    do: ~s(msgctxt "#{key}"\nmsgid "#{msgid}"\nmsgstr "#{msgstr}"\n\n)

  defp plural(key, msgid, msgid_plural, forms) do
    lines =
      forms |> Enum.with_index() |> Enum.map(fn {form, i} -> ~s(msgstr[#{i}] "#{form}"\n) end)

    ~s(msgctxt "#{key}"\nmsgid "#{msgid}"\nmsgid_plural "#{msgid_plural}"\n) <>
      Enum.join(lines) <> "\n"
  end

  defp write_pot!(dir, body),
    do: dir |> Path.join("mobile.pot") |> File.write!(header(nil) <> body)

  defp write_po!(dir, locale, body, plural_forms \\ :default) do
    plural_forms = if plural_forms == :default, do: @plural_forms[locale], else: plural_forms
    folder = Path.join([dir, locale, "LC_MESSAGES"])
    File.mkdir_p!(folder)
    folder |> Path.join("mobile.po") |> File.write!(header(plural_forms) <> body)
  end

  defp domain!(dir, pot_body, po_body) do
    write_pot!(dir, pot_body)
    write_po!(dir, "de", po_body)
    dir
  end

  defp copy_real_domain!(dir) do
    @gettext |> Path.join("mobile.pot") |> File.cp!(Path.join(dir, "mobile.pot"))

    for locale <- Strings.locales() do
      folder = Path.join([dir, locale, "LC_MESSAGES"])
      File.mkdir_p!(folder)

      [@gettext, locale, "LC_MESSAGES", "mobile.po"]
      |> Path.join()
      |> File.cp!(Path.join(folder, "mobile.po"))
    end

    dir
  end

  defp messages(path) do
    path
    |> PO.parse_file!()
    |> Map.fetch!(:messages)
    |> Enum.filter(&match?(%Singular{}, &1))
    |> Enum.map(fn m ->
      {IO.iodata_to_binary(m.msgctxt || ""), IO.iodata_to_binary(m.msgid),
       IO.iodata_to_binary(m.msgstr)}
    end)
  end

  # Every mobile.pot entry as {key, kind, msgid}, the msgid a {msgid,
  # msgid_plural} tuple for a plural, the shape Strings.msgids/0 returns.
  defp pot_entries do
    @gettext
    |> Path.join("mobile.pot")
    |> PO.parse_file!()
    |> Map.fetch!(:messages)
    |> Enum.map(&pot_entry/1)
  end

  defp pot_entry(%Plural{} = m) do
    msgid = {IO.iodata_to_binary(m.msgid), IO.iodata_to_binary(m.msgid_plural)}
    {IO.iodata_to_binary(m.msgctxt), :plural, msgid}
  end

  defp pot_entry(%Singular{} = m),
    do: {IO.iodata_to_binary(m.msgctxt), :string, IO.iodata_to_binary(m.msgid)}

  defp pot_keys(kind), do: for({key, ^kind, _msgid} <- pot_entries(), do: key) |> Enum.sort()

  defp po_messages(locale, domain),
    do: [@gettext, locale, "LC_MESSAGES", domain <> ".po"] |> Path.join() |> messages()

  defp committed(locale), do: @root |> Path.join(Strings.output_path(locale)) |> File.read!()

  defp keys_sorted?(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    keys == Enum.sort(keys) and Enum.all?(values, fn {_key, value} -> keys_sorted?(value) end)
  end

  defp keys_sorted?(_value), do: true

  describe "the committed mobile domain" do
    test "every mobile msgid is translated in all seven locales" do
      built = Strings.build!(@gettext)

      assert built |> Map.keys() |> Enum.sort() == ~w(de en es fr ja pt zh)
      assert length(pot_keys(:string)) == 94
      assert length(pot_keys(:plural)) == 17

      for {locale, strings} <- built do
        assert strings["strings"] |> Map.keys() |> Enum.sort() == pot_keys(:string),
               "#{locale} lacks a string"

        assert strings["plurals"] |> Map.keys() |> Enum.sort() == pot_keys(:plural),
               "#{locale} lacks a plural"

        assert strings["strings"] |> Map.values() |> Enum.all?(&(String.trim(&1) != "")), locale
      end

      assert Enum.sort(Strings.msgids()) == pot_entries() |> Enum.map(&elem(&1, 2)) |> Enum.sort()
    end

    test "the mobile copies read the same as the web's default domain in every locale" do
      for locale <- Strings.locales() do
        web =
          for {"", msgid, msgstr} <- po_messages(locale, "default"),
              into: %{},
              do: {msgid, msgstr}

        compared =
          for {key, msgid, msgstr} <- po_messages(locale, "mobile"), key not in @app_only do
            web_text = if web[msgid] == "", do: msgid, else: web[msgid]

            assert msgstr == web_text,
                   "#{locale} #{key} reads #{inspect(msgstr)} on the apps but #{inspect(web_text)} " <>
                     "on the web. Change both copies, or give the app string its own msgid."

            key
          end

        assert length(compared) == 26, "#{locale} compared only #{length(compared)} strings"
      end
    end

    test "the committed plurals have each locale's categories and keep their count" do
      for {locale, strings} <- Strings.build!(@gettext) do
        categories = if locale in ~w(ja zh), do: ~w(other), else: ~w(one other)

        for {key, forms} <- strings["plurals"] do
          assert forms |> Map.keys() |> Enum.sort() == categories, "#{locale} #{key}"
          assert forms |> Map.values() |> Enum.all?(&(&1 =~ "{count}")), "#{locale} #{key}"
        end
      end

      assert Strings.build!(@gettext)["de"]["plurals"]["target_goal_count"] ==
               %{"one" => "{count} Ziel", "other" => "{count} Ziele"}
    end

    test "the locale list matches priv/gettext and the Gettext backend" do
      dirs =
        @gettext
        |> File.ls!()
        |> Enum.filter(&(@gettext |> Path.join(&1) |> File.dir?()))
        |> Enum.sort()

      assert Strings.locales() == dirs
      assert Strings.locales() == KanbanWeb.Gettext |> Gettext.known_locales() |> Enum.sort()
    end

    test "placeholders are converted and kept in every locale" do
      for {locale, strings} <- Strings.build!(@gettext) do
        slip = strings["strings"]["target_risk_slip"]
        assert slip =~ "{estimate}", locale
        assert slip =~ "{target_date}", locale
        refute slip =~ "%{", locale
      end
    end

    @tag :tmp_dir
    test "a translation that drops or renames a placeholder fails", %{tmp_dir: dir} do
      pot = entry("slip", "Lands %{estimate} after %{target_date}")

      dir =
        domain!(
          dir,
          pot,
          entry("slip", "Lands %{estimate} after %{target_date}", "Am %{estimate}")
        )

      assert_raise ArgumentError,
                   ~r/mobile\.strings: de slip drops placeholders: target_date/,
                   fn ->
                     Strings.parse!(dir, "de")
                   end

      write_po!(
        dir,
        "de",
        entry("slip", "Lands %{estimate} after %{target_date}", "Am %{schaetzung} %{target_date}")
      )

      assert_raise ArgumentError, ~r/de slip has placeholders the msgid lacks: schaetzung/, fn ->
        Strings.parse!(dir, "de")
      end
    end

    test "the committed JSON copies are up to date" do
      for {locale, json} <- Strings.render!(@gettext) do
        assert committed(locale) == json, "#{Strings.output_path(locale)} #{@refresh_hint}"
      end
    end

    @tag :tmp_dir
    test "a changed mobile.po changes the render, so the staleness test catches it", %{
      tmp_dir: dir
    } do
      dir = copy_real_domain!(dir)
      po = Path.join([dir, "de", "LC_MESSAGES", "mobile.po"])
      text = File.read!(po)
      assert text =~ ~s(msgstr "Im Plan")

      File.write!(po, String.replace(text, ~s(msgstr "Im Plan"), ~s(msgstr "Im Zeitplan")))

      refute Strings.render!(dir)["de"] == committed("de")
      assert Strings.render!(dir)["ja"] == committed("ja")
    end

    test "mobile/shared/strings holds only the seven locale files and its README" do
      files = @root |> Path.join(Strings.output_dir()) |> File.ls!() |> Enum.sort()

      assert files == Enum.sort(["README.md" | Enum.map(Strings.locales(), &(&1 <> ".json"))])
    end

    test "the paths are relative to the project root" do
      assert Strings.source_path() == "priv/gettext"
      assert Strings.output_dir() == "mobile/shared/strings"
      assert Strings.output_path("ja") == "mobile/shared/strings/ja.json"
    end
  end

  describe "errors" do
    @tag :tmp_dir
    test "fuzzy entries fail the test", %{tmp_dir: dir} do
      dir =
        domain!(dir, entry("hello", "Hello"), "#, fuzzy\n" <> entry("hello", "Hello", "Hallo"))

      assert_raise ArgumentError, ~r/mobile\.strings: de hello is fuzzy/, fn ->
        Strings.parse!(dir, "de")
      end

      for locale <- Strings.locales() do
        refute [@gettext, locale, "LC_MESSAGES", "mobile.po"] |> Path.join() |> File.read!() =~
                 ~r/^#,.*\bfuzzy\b/m,
               "#{locale} mobile.po has a fuzzy entry"
      end
    end

    @tag :tmp_dir
    test "an empty msgstr fails with the locale", %{tmp_dir: dir} do
      dir = domain!(dir, entry("hello", "Hello"), entry("hello", "Hello", " "))

      assert_raise ArgumentError, ~r/^mobile\.strings: de hello has an empty translation/, fn ->
        Strings.parse!(dir, "de")
      end

      pot = plural("tasks", "One task", "%{count} tasks", ["", ""])
      dir = domain!(dir, pot, plural("tasks", "One task", "%{count} tasks", ["Eine Aufgabe", ""]))

      assert_raise ArgumentError, ~r/^mobile\.strings: de tasks has an empty translation/, fn ->
        Strings.parse!(dir, "de")
      end
    end

    @tag :tmp_dir
    test "every malformed domain fails naming the locale and the key", %{tmp_dir: dir} do
      hello = entry("hello", "Hello", "Hallo")
      tasks_pot = plural("tasks", "One task for %{name}", "%{count} tasks for %{name}", ["", ""])

      cases = [
        {fn d -> write_pot!(d, entry("hello", "Hello")) end, ~r/de mobile\.po is missing at/},
        {fn d -> write_po!(d, "de", hello) end, ~r/de mobile\.pot is missing at/},
        {fn d -> domain!(d, entry("hello", "Hello") <> entry("bye", "Bye"), hello) end,
         ~r/de bye is in mobile\.pot but not in mobile\.po/},
        {fn d -> domain!(d, entry("hello", "Hello"), hello <> entry("bye", "Bye", "Tschüss")) end,
         ~r/de bye is in mobile\.po but not in mobile\.pot/},
        {fn d ->
           domain!(
             d,
             entry("hello", "Hello"),
             hello <> ~s(#~ msgctxt "old"\n#~ msgid "Old"\n#~ msgstr "Alt"\n)
           )
         end, ~r/de old is obsolete/},
        {fn d ->
           domain!(d, ~s(msgid "Hello"\nmsgstr ""\n), ~s(msgid "Hello"\nmsgstr "Hallo"\n))
         end, ~r/de Hello has no msgctxt key/},
        {fn d -> domain!(d, entry("Bad-Key", "Hello"), entry("Bad-Key", "Hello", "Hallo")) end,
         ~r/de Bad-Key is not a snake_case key/},
        {fn d ->
           domain!(
             d,
             entry("hello", "Hello") <> entry("hello", "Hi"),
             hello <> entry("hello", "Hi", "Hi")
           )
         end, ~r/de hello is used by more than one message/},
        {fn d ->
           domain!(
             d,
             entry("hello", "Hello %{name}"),
             entry("hello", "Hello %{name}", "Hallo {name} %{name}")
           )
         end, ~r/de hello has a brace outside a %\{name\} placeholder/},
        {fn d ->
           domain!(
             d,
             tasks_pot,
             plural("tasks", "One task for %{name}", "%{count} tasks for %{name}", [
               "Eine Aufgabe für %{name}",
               "%{count} Aufgaben"
             ])
           )
         end, ~r/de tasks drops placeholders: name/},
        {fn d ->
           domain!(
             d,
             tasks_pot,
             plural("tasks", "One task for %{name}", "%{count} tasks for %{name}", [
               "%{count} Aufgaben für %{name}"
             ])
           )
         end, ~r/de tasks has 1 plural forms, not 2/},
        {fn d ->
           write_pot!(d, entry("hello", "Hello"))

           write_po!(
             d,
             "de",
             hello,
             "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);"
           )
         end, ~r/de Plural-Forms .* is not supported/},
        {fn d ->
           write_pot!(d, entry("hello", "Hello"))
           write_po!(d, "de", hello, nil)
         end, ~r/de Plural-Forms header is missing/}
      ]

      cases
      |> Enum.with_index()
      |> Enum.each(fn {{setup, message}, i} ->
        case_dir = Path.join(dir, "case#{i}")
        File.mkdir_p!(case_dir)
        setup.(case_dir)
        assert_raise ArgumentError, message, fn -> Strings.parse!(case_dir, "de") end
      end)
    end

    test "an unknown locale fails before any file is read" do
      assert_raise ArgumentError,
                   ~r/mobile\.strings: "xx" is not one of de, en, es, fr, ja, pt, zh/,
                   fn ->
                     Strings.parse!(@gettext, "xx")
                   end
    end

    @tag :tmp_dir
    test "a Japanese plural with two forms fails", %{tmp_dir: dir} do
      write_pot!(dir, plural("tasks", "One task", "%{count} tasks", ["", ""]))

      write_po!(
        dir,
        "ja",
        plural("tasks", "One task", "%{count} tasks", ["%{count} 件", "%{count} 件"])
      )

      assert_raise ArgumentError, ~r/ja tasks has 2 plural forms, not 1/, fn ->
        Strings.parse!(dir, "ja")
      end
    end
  end

  describe "plurals" do
    @tag :tmp_dir
    test "plural forms are written per locale", %{tmp_dir: dir} do
      pot = plural("tasks", "One task", "%{count} tasks", ["", ""])
      write_pot!(dir, pot)

      two = plural("tasks", "One task", "%{count} tasks", ["Eine Aufgabe", "%{count} Aufgaben"])
      one = plural("tasks", "One task", "%{count} tasks", ["%{count} 件のタスク"])

      for locale <- ~w(de en es fr pt), do: write_po!(dir, locale, two)
      for locale <- ~w(ja zh), do: write_po!(dir, locale, one)

      for locale <- ~w(de en es fr pt) do
        assert Strings.parse!(dir, locale)["plurals"] == %{
                 "tasks" => %{"one" => "Eine Aufgabe", "other" => "{count} Aufgaben"}
               }
      end

      for locale <- ~w(ja zh) do
        assert Strings.parse!(dir, locale)["plurals"] == %{
                 "tasks" => %{"other" => "{count} 件のタスク"}
               }
      end

      assert Strings.parse!(dir, "de")["strings"] == %{}
    end
  end

  describe "render!/1" do
    @tag :tmp_dir
    test "output is sorted, stable and ends in a newline", %{tmp_dir: dir} do
      dir = copy_real_domain!(dir)
      rendered = Strings.render!(dir)

      assert rendered == Strings.render!(dir)

      for {locale, json} <- rendered do
        assert String.ends_with?(json, "}\n")
        assert json |> Jason.decode!(objects: :ordered_objects) |> keys_sorted?()
        assert Jason.decode!(json) == Strings.build!(dir)[locale]
        assert json =~ ~s("locale": "#{locale}")
      end
    end
  end
end
