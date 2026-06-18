defmodule Kanban.Accounts.OIDCTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Accounts.UserIdentity

  @issuer "https://auth.example.com/application/o/stride/"

  defp oidc_attrs(claim_overrides \\ %{}, attr_overrides \\ %{}) do
    claims =
      Map.merge(
        %{
          "sub" => "authentik-user-1",
          "email" => unique_user_email(),
          "email_verified" => true,
          "name" => "SSO User",
          "groups" => []
        },
        claim_overrides
      )

    Map.merge(
      %{
        issuer: @issuer,
        claims: claims,
        require_verified_email: true,
        admin_group_claim: "groups",
        admin_groups: []
      },
      attr_overrides
    )
  end

  describe "authenticate_oidc/1" do
    test "creates a confirmed user from valid OIDC claims" do
      attrs = oidc_attrs(%{"email" => unique_user_email()})

      assert {:ok, %User{} = user} = Accounts.authenticate_oidc(attrs)
      assert user.email == attrs.claims["email"]
      assert user.name == "SSO User"
      assert user.confirmed_at
      refute user.hashed_password

      assert %UserIdentity{} =
               Repo.get_by(UserIdentity,
                 issuer: @issuer,
                 subject: "authentik-user-1",
                 user_id: user.id
               )
    end

    test "links a new OIDC identity to an existing user by verified email" do
      user = user_fixture()
      attrs = oidc_attrs(%{"email" => user.email, "sub" => "new-subject"})

      assert {:ok, linked} = Accounts.authenticate_oidc(attrs)
      assert linked.id == user.id

      assert %UserIdentity{user_id: user_id} =
               Repo.get_by(UserIdentity, issuer: @issuer, subject: "new-subject")

      assert user_id == user.id
    end

    test "confirms an existing unconfirmed user when linking by verified email" do
      user = unconfirmed_user_fixture()
      attrs = oidc_attrs(%{"email" => user.email, "sub" => "new-subject"})

      assert {:ok, linked} = Accounts.authenticate_oidc(attrs)
      assert linked.id == user.id
      assert linked.confirmed_at
    end

    test "reuses an existing identity on later login" do
      attrs = oidc_attrs()

      assert {:ok, first_user} = Accounts.authenticate_oidc(attrs)

      second_attrs =
        attrs
        |> put_in([:claims, "email"], unique_user_email())
        |> put_in([:claims, "name"], "Changed Name")

      assert {:ok, second_user} = Accounts.authenticate_oidc(second_attrs)
      assert second_user.id == first_user.id

      assert Repo.aggregate(UserIdentity, :count) == 1
      assert Repo.get!(User, first_user.id).name == first_user.name
    end

    test "rejects missing subject" do
      attrs = oidc_attrs(%{"sub" => nil})

      assert {:error, :missing_subject} = Accounts.authenticate_oidc(attrs)
    end

    test "rejects missing email" do
      attrs = oidc_attrs(%{"email" => nil})

      assert {:error, :missing_email} = Accounts.authenticate_oidc(attrs)
    end

    test "rejects unverified email when configured to require verification" do
      attrs = oidc_attrs(%{"email_verified" => false})

      assert {:error, :email_not_verified} = Accounts.authenticate_oidc(attrs)
    end

    test "allows unverified email when verification is not required" do
      attrs = oidc_attrs(%{"email_verified" => false}, %{require_verified_email: false})

      assert {:ok, %User{}} = Accounts.authenticate_oidc(attrs)
    end

    test "authoritatively promotes and demotes admins from OIDC groups" do
      attrs =
        oidc_attrs(
          %{"groups" => ["stride-admins"]},
          %{admin_groups: ["stride-admins"]}
        )

      assert {:ok, admin_user} = Accounts.authenticate_oidc(attrs)
      assert admin_user.type == :admin

      demoted_attrs = put_in(attrs, [:claims, "groups"], [])

      assert {:ok, normal_user} = Accounts.authenticate_oidc(demoted_attrs)
      assert normal_user.id == admin_user.id
      assert normal_user.type == :user
    end
  end
end
