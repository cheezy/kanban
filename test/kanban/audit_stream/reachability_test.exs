defmodule Kanban.AuditStream.ReachabilityTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Reachability

  defp changeset(attrs), do: Destination.changeset(%Destination{organization_id: 1}, attrs)

  defp splunk(url) do
    changeset(%{
      kind: :splunk_hec,
      name: "Splunk",
      url: url,
      credential: "splunk-hec-token-0000",
      settings: %{"index" => "main"}
    })
  end

  describe "check/2" do
    test "a URL resolving to a public address passes" do
      changeset = "https://collector.example.com/services" |> splunk() |> Reachability.check([])
      assert changeset.valid?
    end

    test "a URL resolving to a private address is an error on :url" do
      changeset = "https://internal.example.com/services" |> splunk() |> Reachability.check([])
      refute changeset.valid?
      assert [{_message, opts}] = Keyword.get_values(changeset.errors, :url)
      assert opts[:reason]
    end

    test "an explicit resolver overrides the configured one" do
      resolver = fn _host -> {:ok, [{10, 0, 0, 2}]} end

      changeset =
        "https://collector.example.com/x" |> splunk() |> Reachability.check(resolver: resolver)

      refute changeset.valid?
    end

    test "an invalid changeset or one with no URL change is returned as it is" do
      invalid = changeset(%{kind: :splunk_hec, url: "https://internal.example.com/x"})
      assert Reachability.check(invalid, []) == invalid

      no_url = Changeset.change(%Destination{url: "https://internal.example.com/x"}, name: "N")
      assert Reachability.check(no_url, []) == no_url
    end
  end

  describe "lookup/2 and put_result/2" do
    test "lookup/2 checks an atom or string url key and gives nil without one" do
      assert {:error, _reason} = Reachability.lookup(%{url: "https://internal.example.com/x"}, [])
      assert {:ok, _resolved} = Reachability.lookup(%{"url" => "https://siem.example.org/x"}, [])
      assert Reachability.lookup(%{name: "No URL"}, []) == nil
    end

    test "put_result/2 adds a refusal only when the changeset changes the URL" do
      result = Reachability.lookup(%{url: "https://metadata.example.com/x"}, [])
      changed = "https://metadata.example.com/x" |> splunk() |> Reachability.put_result(result)
      refute changed.valid?

      unchanged = Changeset.change(%Destination{url: "https://metadata.example.com/x"}, name: "N")
      assert Reachability.put_result(unchanged, result) == unchanged
      assert Reachability.put_result(unchanged, nil) == unchanged
    end
  end
end
