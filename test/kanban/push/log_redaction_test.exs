defmodule Kanban.Push.LogRedactionTest do
  # The crash test adds a :logger primary filter, which is global, so the
  # module is not async. The filter it adds carries only the fragments of a
  # key generated here and is removed afterwards.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.Push.LogRedaction

  @redacted "[REDACTED push credential]"

  # A real, freshly generated P-256 key in the PKCS#8 PEM shape of an APNs .p8
  # file. It is made in the test and never leaves it.
  defp pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    der = :public_key.der_encode(:PrivateKeyInfo, key)
    :public_key.pem_encode([{:PrivateKeyInfo, der, :not_encrypted}])
  end

  defp event(level, msg), do: %{level: level, msg: msg, meta: %{}}

  describe "fragments/1" do
    test "keeps the key body lines and drops the armour lines" do
      key = pem()
      fragments = LogRedaction.fragments(key)

      assert fragments != []
      refute Enum.any?(fragments, &String.starts_with?(&1, "-----"))
      assert Enum.all?(fragments, &(String.contains?(key, &1) and byte_size(&1) >= 16))
    end

    test "reads a key pasted on one line with \\n" do
      key = pem()

      assert key |> String.replace("\n", "\\n") |> LogRedaction.fragments() ==
               LogRedaction.fragments(key)
    end

    test "is empty for anything that is not a key" do
      assert LogRedaction.fragments(nil) == []
      assert LogRedaction.fragments("short") == []
    end

    test "nothing is configured in test, so nothing would be redacted" do
      assert LogRedaction.configured_fragments() == []
      assert LogRedaction.install() == :ok
    end
  end

  describe "filter/2" do
    setup do
      key = pem()
      %{key: key, fragments: LogRedaction.fragments(key)}
    end

    test "redacts a supervisor report term", %{key: key, fragments: fragments} do
      report = %{
        label: {:supervisor, :child_terminated},
        report: [offender: [mfargs: {Pigeon.DispatcherWorker, :start_link, [[key: key]]}]]
      }

      %{msg: {:report, redacted}} =
        :error |> event({:report, report}) |> LogRedaction.filter(fragments)

      refute inspect(redacted) =~ hd(fragments)
      assert inspect(redacted) =~ @redacted
      assert redacted.label == {:supervisor, :child_terminated}
    end

    test "redacts a string that already holds the inspected key",
         %{key: key, fragments: fragments} do
      message = ["Start Call: ", "Pigeon.Dispatcher.start_link(", inspect(key: key), ")"]

      %{msg: {:string, redacted}} =
        :error |> event({:string, message}) |> LogRedaction.filter(fragments)

      refute redacted =~ hd(fragments)
      assert redacted =~ @redacted
      assert redacted =~ "Start Call: Pigeon.Dispatcher.start_link("
    end

    test "redacts format arguments, structs, charlists and improper lists",
         %{key: key, fragments: fragments} do
      args = [%URI{host: key}, String.to_charlist(key), [key | :tail], {:state, key}]

      %{msg: {_format, redacted}} =
        :warning |> event({~c"~p", args}) |> LogRedaction.filter(fragments)

      refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ hd(fragments)
      assert [%URI{}, charlist, [_ | :tail], {:state, _}] = redacted
      assert is_list(charlist)
    end

    test "leaves info and debug events alone", %{key: key, fragments: fragments} do
      info = event(:info, {:string, key})
      assert LogRedaction.filter(info, fragments) == info
    end
  end

  describe "the installed filter" do
    # With this app's logger config OTP's supervisor reports are not logged
    # (SASL reports are off), so these events stand in for them: each goes
    # through the real :logger pipeline, the translator included, the way a
    # supervisor report or a library's error log would.
    setup do
      key = pem()
      fragments = LogRedaction.fragments(key)
      filter_id = :push_redaction_test

      :ok = LogRedaction.install(filter_id, fragments)
      on_exit(fn -> :logger.remove_primary_filter(filter_id) end)

      %{key: key, fragments: fragments}
    end

    test "an error string carrying the key is logged redacted", %{key: key, fragments: fragments} do
      log =
        capture_log(fn ->
          require Logger
          Logger.error("Start Call: Pigeon.Dispatcher.start_link(#{inspect(key: key)})")
        end)

      assert log =~ "Start Call: Pigeon.Dispatcher.start_link("
      assert log =~ @redacted
      refute Enum.any?(fragments, &(log =~ &1))
    end

    test "an error report carrying the key is logged redacted", %{key: key, fragments: fragments} do
      log =
        capture_log(fn ->
          :logger.error(%{
            offender: [mfargs: {Pigeon.DispatcherWorker, :start_link, [[key: key]]}]
          })
        end)

      assert log =~ "Pigeon.DispatcherWorker"
      assert log =~ @redacted
      refute Enum.any?(fragments, &(log =~ &1))
    end
  end
end
