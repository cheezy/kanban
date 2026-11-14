defmodule Kanban.AuditStreamFixtures do
  @moduledoc """
  Test helpers for `Kanban.AuditStream` destinations: valid attributes for
  each kind, destinations inserted straight through `Repo` (so they write no
  audit row and look up no host), and the fixed DNS table the context uses in
  tests (`config/test.exs`).
  """

  alias Kanban.AuditStream.Cursor
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Gap
  alias Kanban.Repo

  @doc """
  Valid create attributes for `kind`, merged with `overrides`. The name and
  secrets are unique per call, and every secret is long enough to get a hint.
  """
  def destination_attrs(kind, overrides \\ %{})

  def destination_attrs(:splunk_hec, overrides) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        kind: :splunk_hec,
        name: "Splunk #{n}",
        url: "https://collector.example.com/services/collector/event",
        credential: "splunk-hec-token-#{n}-wxyz",
        settings: %{"index" => "main"}
      },
      Map.new(overrides)
    )
  end

  def destination_attrs(:datadog, overrides) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        kind: :datadog,
        name: "Datadog #{n}",
        credential: "datadog-api-key-#{n}-9876",
        settings: %{"site" => "datadoghq.eu"}
      },
      Map.new(overrides)
    )
  end

  def destination_attrs(:https, overrides) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        kind: :https,
        name: "HTTPS #{n}",
        url: "https://siem.example.org/ingest/#{n}?path-token=abcd",
        settings: %{"format" => "ndjson"}
      },
      Map.new(overrides)
    )
  end

  @doc """
  Inserts a destination of `kind` in `organization` with a cursor at the
  start of the log. An HTTPS destination gets a signing secret. No audit row
  is written and no host is looked up.
  """
  def destination_fixture(organization, kind, overrides \\ %{}) do
    changeset =
      %Destination{organization_id: organization.id}
      |> Destination.changeset(destination_attrs(kind, overrides))

    changeset =
      if kind == :https,
        do: Ecto.Changeset.put_change(changeset, :signing_secret, "assec_fixture-#{unique()}"),
        else: changeset

    destination = Repo.insert!(changeset)

    %Cursor{destination_id: destination.id}
    |> Cursor.changeset(%{last_txid: 0, last_event_id: 0})
    |> Repo.insert!()

    destination
  end

  @doc """
  Inserts an open gap for `destination`, straight through `Repo` so no
  `audit_stream_gap` row is written. `audited_at` equals `last_extended_at`,
  so dismissing it records only `audit_stream_gap_dismissed`. `overrides`
  may set any `Kanban.AuditStream.Gap` field, `dismissed_at` included.
  """
  def gap_fixture(%Destination{id: destination_id}, overrides \\ %{}) do
    now = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          destination_id: destination_id,
          reason: :retention,
          events: 12,
          first_occurred_at: ~U[2026-10-01 08:00:00.000000Z],
          last_occurred_at: ~U[2026-10-03 17:30:00.000000Z],
          opened_at: now,
          last_extended_at: now,
          audited_at: now
        },
        Map.new(overrides)
      )

    {dismissed_at, attrs} = Map.pop(attrs, :dismissed_at)

    %Gap{dismissed_at: dismissed_at}
    |> Gap.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Makes `field`'s stored ciphertext undecryptable by flipping its last byte,
  as a lost `ENCRYPTION_KEY` would, so it loads as `:unreadable`.
  """
  def make_unreadable!(%Destination{id: id}, field) do
    true = field in Destination.secret_fields()
    column = Atom.to_string(field)

    %{rows: [[ciphertext]]} =
      Repo.query!("SELECT #{column} FROM audit_stream_destinations WHERE id = $1", [id])

    last = :binary.last(ciphertext)
    tampered = binary_part(ciphertext, 0, byte_size(ciphertext) - 1) <> <<Bitwise.bxor(last, 1)>>

    Repo.query!("UPDATE audit_stream_destinations SET #{column} = $1 WHERE id = $2", [
      tampered,
      id
    ])

    :ok
  end

  @doc """
  The DNS table `Kanban.AuditStream` uses in tests (`config/test.exs`):

    * `collector.example.com` - a public address
    * `siem.example.org` - a public address
    * `internal.example.com` - a private address
    * `metadata.example.com` - the cloud metadata address
    * `http-intake.logs.datadoghq.eu` - a public address, the intake for the
      Datadog fixture's site
    * `raise.example.com` - the lookup raises, and `exit.example.com` - the
      lookup exits, for the form's failure containment tests

  Anything else does not resolve.
  """
  def resolve("collector.example.com"), do: {:ok, [{93, 184, 216, 34}]}
  def resolve("siem.example.org"), do: {:ok, [{93, 184, 216, 35}]}
  def resolve("internal.example.com"), do: {:ok, [{10, 0, 0, 1}]}
  def resolve("metadata.example.com"), do: {:ok, [{169, 254, 169, 254}]}
  def resolve("http-intake.logs.datadoghq.eu"), do: {:ok, [{93, 184, 216, 36}]}
  def resolve("raise.example.com"), do: raise("resolver failed")
  def resolve("exit.example.com"), do: exit(:resolver_down)
  def resolve(_host), do: {:error, :nxdomain}

  defp unique, do: System.unique_integer([:positive])
end
