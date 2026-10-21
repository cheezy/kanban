defmodule Kanban.SCIM.FilterTest do
  use ExUnit.Case, async: true

  alias Kanban.SCIM.Filter

  doctest Kanban.SCIM.Filter

  describe "parse/2" do
    test "accepts the userName equality form in its spellings" do
      for filter <- [
            ~s(userName eq "ada@example.com"),
            ~s(USERNAME EQ "ada@example.com"),
            ~s(  userName   eq   "ada@example.com"  ),
            ~s(urn:ietf:params:scim:schemas:core:2.0:User:userName eq "ada@example.com")
          ] do
        assert Filter.parse(filter, ["userName"]) == {:ok, {"userName", "ada@example.com"}}
      end
    end

    test "unescapes quotes and backslashes in the value" do
      assert Filter.parse(~s(displayName eq "A \\"B\\" \\\\ C"), ["displayName"]) ==
               {:ok, {"displayName", ~s(A "B" \\ C)}}
    end

    test "an empty quoted value is allowed" do
      assert Filter.parse(~s(userName eq ""), ["userName"]) == {:ok, {"userName", ""}}
    end

    test "absent and blank filters are no filter" do
      assert Filter.parse(nil, ["userName"]) == :none
      assert Filter.parse("   ", ["userName"]) == :none
    end

    test "rejects every other form" do
      for filter <- [
            ~s(userName co "ada"),
            ~s(userName sw "ada"),
            ~s(userName pr),
            ~s(userName eq "a" and active eq "true"),
            ~s(userName eq "a" or userName eq "b"),
            ~s[not (userName eq "a")],
            ~s(userName eq ada@example.com),
            ~s(emails eq "ada@example.com"),
            ~s(eq "ada"),
            ~s(userName eq "unterminated)
          ] do
        assert Filter.parse(filter, ["userName"]) == {:error, :invalid_filter}, filter
      end

      assert Filter.parse(42, ["userName"]) == {:error, :invalid_filter}
    end

    test "rejects an attribute the caller does not allow" do
      assert Filter.parse(~s(displayName eq "x"), ["userName"]) == {:error, :invalid_filter}
    end

    test "rejects an over-long value" do
      value = String.duplicate("a", 321)
      assert Filter.parse(~s(userName eq "#{value}"), ["userName"]) == {:error, :invalid_filter}
    end
  end

  describe "member_path/1" do
    test "reads the id from a members value filter" do
      assert Filter.member_path(~s(members[value eq "12"])) == {:ok, "12"}
      assert Filter.member_path(~s(Members[ value EQ "12" ])) == {:ok, "12"}
    end

    test "rejects anything else" do
      assert Filter.member_path("members") == :error
      assert Filter.member_path(~s(members[display eq "12"])) == :error
    end
  end

  test "normalize_attribute/1 lowercases and strips the core URN" do
    assert Filter.normalize_attribute("urn:ietf:params:scim:schemas:core:2.0:Group:displayName") ==
             "displayname"

    assert Filter.normalize_attribute(" Active ") == "active"
  end
end
