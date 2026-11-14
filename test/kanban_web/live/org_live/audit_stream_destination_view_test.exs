defmodule KanbanWeb.OrgLive.AuditStreamDestinationViewTest do
  @moduledoc """
  The Settings rows `AuditStreamDestinationView.to_view/2` builds for an
  HTTPS destination (D443): the format by the name the form offers it under,
  and `header_name` as the authorization header name, never a signature.
  """
  use ExUnit.Case, async: true

  alias Kanban.AuditStream.Destination
  alias KanbanWeb.OrgLive.AuditStreamDestinationView
  alias KanbanWeb.OrgLive.AuditStreamKinds

  defp https(settings),
    do: %Destination{
      id: 1,
      kind: :https,
      name: "HTTPS",
      enabled: true,
      settings: settings,
      credential: "Bearer never-shown-1234",
      credential_hint: "1234",
      excluded_actions: []
    }

  defp settings(settings),
    do: settings |> https() |> AuditStreamDestinationView.to_view() |> Map.fetch!(:settings)

  test "to_view shows json as JSON batch and ndjson as NDJSON" do
    assert settings(%{"format" => "json"}) == [{"Format", "JSON batch"}]
    assert settings(%{"format" => "ndjson"}) == [{"Format", "NDJSON"}]
  end

  test "to_view labels header_name as the authorization header name" do
    rows = settings(%{"format" => "json", "header_name" => "X-goog-api-key"})

    assert rows == [{"Format", "JSON batch"}, {"Authorization header name", "X-goog-api-key"}]
    refute Enum.any?(rows, fn {label, _} -> label =~ "Signature" end)
  end

  test "to_view leaves out a blank format and a blank header name" do
    assert settings(%{}) == []
    assert settings(nil) == []
    assert settings(%{"format" => "", "header_name" => ""}) == []

    assert settings(%{"header_name" => "Authorization"}) == [
             {"Authorization header name", "Authorization"}
           ]
  end

  test "Splunk and Datadog destinations never show the header row" do
    header_label = AuditStreamKinds.header_name_label()

    for {kind, settings} <- [
          splunk_hec: %{"index" => "security", "header_name" => "Authorization"},
          datadog: %{"site" => "datadoghq.eu", "header_name" => "Authorization"}
        ] do
      rows =
        %{https(settings) | kind: kind}
        |> AuditStreamDestinationView.to_view()
        |> Map.fetch!(:settings)

      refute Enum.any?(rows, fn {label, _} -> label == header_label end), "#{kind} shows it"
      refute Enum.any?(rows, fn {_, value} -> value == "Authorization" end), "#{kind} shows it"
      assert rows != []
    end
  end

  test "an unknown stored format value is shown as it is rather than crashing" do
    assert settings(%{"format" => "xml"}) == [{"Format", "xml"}]
    assert AuditStreamKinds.format_label("xml") == "xml"
  end

  test "the page's format names are the form's format_options labels" do
    for {label, value} <- AuditStreamKinds.format_options() do
      assert AuditStreamKinds.format_label(value) == label
      assert settings(%{"format" => value}) == [{"Format", label}]
    end
  end

  test "the format names and header label follow the locale" do
    Gettext.with_locale(KanbanWeb.Gettext, "fr", fn ->
      assert AuditStreamKinds.format_label("json") ==
               Gettext.gettext(KanbanWeb.Gettext, "JSON batch")

      refute AuditStreamKinds.format_label("json") == "JSON batch"

      assert AuditStreamKinds.header_name_label() ==
               Gettext.gettext(KanbanWeb.Gettext, "Authorization header name")

      refute AuditStreamKinds.header_name_label() == "Authorization header name"
    end)
  end

  test "the credential never reaches the view" do
    view = %{"header_name" => "Authorization"} |> https() |> AuditStreamDestinationView.to_view()

    refute inspect(view) =~ "never-shown"
    assert view.hint == "•••• 1234"
  end
end
