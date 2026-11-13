defmodule Kanban.AuditStream.SigningSecrets do
  @moduledoc """
  An HTTPS destination's signing secrets
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §9.2): how a new one is made,
  what a rotation keeps of the old one, and how the plaintext is kept out of
  everything `Kanban.AuditStream` returns except the one reveal on create and
  rotate.
  """

  alias Ecto.Changeset
  alias Kanban.AuditStream.Destination

  @prefix "assec_"

  @rotation_overlap_seconds 86_400

  @fields [:signing_secret, :previous_signing_secret]

  @doc "A new signing secret: `assec_` and 32 random bytes, base64url."
  @spec generate() :: String.t()
  def generate,
    do: @prefix <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  @doc """
  What a rotation keeps of the current secret. A readable one becomes the
  previous secret, still valid for 24 hours; one that can't be read can't
  sign, so it is dropped with no overlap, along with any previous secret.
  """
  @spec previous(String.t() | :unreadable | nil) :: map()
  def previous(current) when is_binary(current) do
    expires_at = :second |> DateTime.utc_now() |> DateTime.add(@rotation_overlap_seconds, :second)
    %{previous_signing_secret: current, previous_secret_expires_at: expires_at}
  end

  def previous(_unreadable_or_nil),
    do: %{previous_signing_secret: nil, previous_secret_expires_at: nil}

  @doc """
  Whether `destination` still has a readable previous secret whose 24 hours
  have not ended at `now`. A rotation then would overwrite that secret while
  receivers may still verify with it. An expiry at exactly `now` has ended,
  as it has for signing. An unreadable previous secret can't verify anything,
  so it is never in its overlap.
  """
  @spec in_overlap?(Destination.t(), DateTime.t()) :: boolean()
  def in_overlap?(
        %Destination{
          previous_signing_secret: previous,
          previous_secret_expires_at: %DateTime{} = expires_at
        },
        %DateTime{} = now
      )
      when is_binary(previous),
      do: DateTime.after?(expires_at, now)

  def in_overlap?(%Destination{}, %DateTime{}), do: false

  @doc """
  Hides a destination's signing secrets. Takes a destination, a list of
  them, or an `{:ok, _}` or `{:error, changeset}` result, whose data, changes
  and params lose the secrets too. A secret that can't be read stays
  `:unreadable`, so a caller can still tell that it needs rotating (D17).
  """
  @spec conceal(term()) :: term()
  def conceal(%Destination{} = destination) do
    Enum.reduce(@fields, destination, fn field, acc ->
      if is_binary(Map.fetch!(acc, field)), do: Map.put(acc, field, nil), else: acc
    end)
  end

  def conceal(destinations) when is_list(destinations), do: Enum.map(destinations, &conceal/1)
  def conceal({:ok, result}), do: {:ok, conceal(result)}

  def conceal({:error, %Changeset{} = changeset}) do
    {:error,
     %{
       changeset
       | data: conceal(changeset.data),
         changes: Map.drop(changeset.changes, @fields),
         params: drop_params(changeset.params)
     }}
  end

  def conceal(other), do: other

  @doc """
  Turns a successful save into `{:ok, {destination, signing_secret}}`: the
  plaintext once, beside a destination that no longer carries it. Any other
  result is concealed.
  """
  @spec reveal(term()) :: {:ok, {Destination.t(), String.t() | nil}} | term()
  def reveal({:ok, %Destination{signing_secret: secret} = destination}),
    do: {:ok, {conceal(destination), secret}}

  def reveal(other), do: conceal(other)

  defp drop_params(nil), do: nil
  defp drop_params(params), do: Map.drop(params, @fields ++ Enum.map(@fields, &Atom.to_string/1))
end
