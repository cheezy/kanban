defmodule Kanban.SCIM.UserMappingTest do
  use ExUnit.Case, async: true

  alias Kanban.Accounts.User
  alias Kanban.SCIM.UserLink
  alias Kanban.SCIM.UserMapping

  describe "from_resource/1" do
    test "reads userName, name, externalId and active" do
      resource = %{
        "schemas" => [UserMapping.schema()],
        "userName" => " Ada@Example.COM ",
        "name" => %{"givenName" => "Ada", "familyName" => "Lovelace"},
        "externalId" => "00u1",
        "active" => "True",
        "emails" => [%{"value" => "ada@example.com", "primary" => true}]
      }

      assert UserMapping.from_resource(resource) ==
               {:ok,
                %{
                  email: "ada@example.com",
                  name: "Ada Lovelace",
                  given_name: "Ada",
                  family_name: "Lovelace",
                  external_id: "00u1",
                  active: true
                }}
    end

    test "defaults active to true and the name to nil" do
      assert {:ok, %{active: true, name: nil, external_id: nil}} =
               UserMapping.from_resource(%{"userName" => "ada@example.com"})
    end

    test "slices a long name" do
      long = String.duplicate("a", 300)

      assert {:ok, %{name: name}} =
               UserMapping.from_resource(%{
                 "userName" => "ada@example.com",
                 "displayName" => long
               })

      assert String.length(name) == 160
    end

    test "refuses a missing or non-email userName and bad values" do
      assert UserMapping.from_resource(%{}) == {:error, :invalid_value}
      assert UserMapping.from_resource(%{"userName" => "ada"}) == {:error, :invalid_value}
      assert UserMapping.from_resource("x") == {:error, :invalid_value}

      assert UserMapping.from_resource(%{"userName" => "a@example.com", "active" => "x"}) ==
               {:error, :invalid_value}

      assert UserMapping.from_resource(%{
               "userName" => "a@example.com",
               "externalId" => String.duplicate("x", 256)
             }) == {:error, :invalid_value}
    end
  end

  test "email/1 drops the trailing dots the domain check ignores" do
    assert UserMapping.email("Ada@Example.com.") == {:ok, "ada@example.com"}
  end

  test "same_user_name?/2 compares case-insensitively" do
    user = %User{email: "ada@example.com"}
    assert UserMapping.same_user_name?(" ADA@example.com", user)
    assert UserMapping.same_user_name?("ada@example.com.", user)
    refute UserMapping.same_user_name?("bob@example.com", user)
  end

  describe "meta.lastModified" do
    test "is the later of the user's and the link's change" do
      user = %User{
        id: 1,
        email: "m@example.com",
        name: "M",
        inserted_at: ~U[2026-01-01 00:00:00Z],
        updated_at: ~U[2026-01-02 00:00:00Z]
      }

      later = %UserLink{updated_at: ~U[2026-03-01 00:00:00Z]}
      earlier = %UserLink{updated_at: ~U[2025-12-01 00:00:00Z]}

      assert UserMapping.to_resource(user, true, later, "loc")["meta"]["lastModified"] ==
               "2026-03-01T00:00:00Z"

      assert UserMapping.to_resource(user, true, earlier, "loc")["meta"]["lastModified"] ==
               "2026-01-02T00:00:00Z"

      assert UserMapping.to_resource(user, true, nil, "loc")["meta"]["lastModified"] ==
               "2026-01-02T00:00:00Z"
    end
  end

  describe "name_parts/2" do
    test "uses the parts on the link while they make up the name" do
      user = %User{name: "Mary Ann Smith"}
      link = %UserLink{given_name: "Mary Ann", family_name: "Smith"}

      assert UserMapping.name_parts(user, link) == %{given: "Mary Ann", family: "Smith"}

      resource =
        UserMapping.to_resource(
          %{
            user
            | id: 1,
              email: "m@example.com",
              inserted_at: ~U[2026-01-01 00:00:00Z],
              updated_at: ~U[2026-01-01 00:00:00Z]
          },
          true,
          link,
          "loc"
        )

      assert resource["name"]["givenName"] == "Mary Ann"
      assert resource["name"]["familyName"] == "Smith"
    end

    test "splits the name when the parts no longer make it up, or there are none" do
      link = %UserLink{given_name: "Mary Ann", family_name: "Smith"}

      assert UserMapping.name_parts(%User{name: "Mae West"}, link) ==
               %{given: "Mae", family: "West"}

      assert UserMapping.name_parts(%User{name: "Mae West"}, nil) ==
               %{given: "Mae", family: "West"}

      assert UserMapping.name_parts(%User{name: nil}, link) == %{given: nil, family: nil}
    end
  end

  describe "to_resource/4" do
    setup do
      now = ~U[2026-10-21 12:00:00Z]

      %{
        user: %User{
          id: 12,
          email: "ada@example.com",
          name: "Ada Lovelace",
          inserted_at: now,
          updated_at: now
        }
      }
    end

    test "round-trips name, emails, active and externalId", %{user: user} do
      resource = UserMapping.to_resource(user, true, %UserLink{external_id: "00u1"}, "loc")

      assert resource["id"] == "12"
      assert resource["userName"] == "ada@example.com"
      assert resource["externalId"] == "00u1"
      assert resource["active"] == true
      assert resource["displayName"] == "Ada Lovelace"

      assert resource["emails"] == [
               %{"value" => "ada@example.com", "type" => "work", "primary" => true}
             ]

      assert resource["meta"]["location"] == "loc"

      assert {:ok,
              %{email: "ada@example.com", name: "Ada Lovelace", external_id: "00u1", active: true}} =
               UserMapping.from_resource(resource)
    end

    test "leaves out what is unknown", %{user: user} do
      resource = UserMapping.to_resource(%{user | name: nil}, false, nil, "loc")

      refute Map.has_key?(resource, "externalId")
      assert resource["displayName"] == "ada@example.com"
      assert resource["name"] == %{"formatted" => nil, "givenName" => nil, "familyName" => nil}
      assert resource["active"] == false
    end

    test "a one-word name is the given name", %{user: user} do
      resource = UserMapping.to_resource(%{user | name: "Ada"}, true, nil, "loc")
      assert resource["name"]["givenName"] == "Ada"
      assert resource["name"]["familyName"] == nil
    end
  end
end
