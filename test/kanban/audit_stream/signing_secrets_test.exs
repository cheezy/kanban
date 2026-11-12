defmodule Kanban.AuditStream.SigningSecretsTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.SigningSecrets

  test "generate/0 makes a distinct assec_ secret from 32 random bytes" do
    secret = SigningSecrets.generate()
    assert "assec_" <> encoded = secret
    assert {:ok, bytes} = Base.url_decode64(encoded, padding: false)
    assert byte_size(bytes) == 32
    refute SigningSecrets.generate() == secret
  end

  describe "previous/1" do
    test "a readable secret stays valid for 24 hours" do
      assert %{previous_signing_secret: "assec_old", previous_secret_expires_at: expires_at} =
               SigningSecrets.previous("assec_old")

      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 86_400, 5
    end

    test "an unreadable or missing secret leaves no previous secret" do
      none = %{previous_signing_secret: nil, previous_secret_expires_at: nil}
      assert SigningSecrets.previous(:unreadable) == none
      assert SigningSecrets.previous(nil) == none
    end
  end

  describe "conceal/1 and reveal/1" do
    setup do
      %{
        destination: %Destination{
          signing_secret: "assec_now",
          previous_signing_secret: "assec_old"
        }
      }
    end

    test "a destination, a list and an ok result lose both secrets", %{
      destination: %Destination{} = destination
    } do
      hidden = %Destination{destination | signing_secret: nil, previous_signing_secret: nil}
      assert SigningSecrets.conceal(destination) == hidden
      assert SigningSecrets.conceal([destination]) == [hidden]
      assert SigningSecrets.conceal({:ok, destination}) == {:ok, hidden}
    end

    test "an unreadable secret stays unreadable", %{destination: %Destination{} = destination} do
      unreadable = %Destination{destination | signing_secret: :unreadable}
      assert SigningSecrets.conceal(unreadable).signing_secret == :unreadable
      assert SigningSecrets.conceal(unreadable).previous_signing_secret == nil
    end

    test "an error changeset loses the secrets from its data, changes and params",
         %{destination: %Destination{} = destination} do
      changeset =
        Destination.signing_secret_changeset(destination, %{
          "signing_secret" => "assec_new",
          "previous_signing_secret" => "assec_now"
        })

      assert {:error, hidden} = SigningSecrets.conceal({:error, changeset})
      assert {hidden.data.signing_secret, hidden.data.previous_signing_secret} == {nil, nil}
      assert Map.take(hidden.changes, [:signing_secret, :previous_signing_secret]) == %{}
      refute Map.has_key?(hidden.params, "signing_secret")
      refute Map.has_key?(hidden.params, "previous_signing_secret")
    end

    test "reveal/1 returns the plaintext once, beside a concealed destination",
         %{destination: %Destination{} = destination} do
      assert {:ok, {hidden, "assec_now"}} = SigningSecrets.reveal({:ok, destination})
      assert {hidden.signing_secret, hidden.previous_signing_secret} == {nil, nil}
      assert SigningSecrets.reveal({:error, :not_https}) == {:error, :not_https}
    end

    test "an error changeset with no params keeps none", %{
      destination: %Destination{} = destination
    } do
      changeset = Changeset.change(destination, signing_secret: "assec_new")

      assert {:error, %Changeset{params: nil, changes: changes}} =
               SigningSecrets.conceal({:error, changeset})

      assert changes == %{}
    end
  end
end
