defmodule Kanban.AuditStream.SecretHintTest do
  use ExUnit.Case, async: true

  alias Kanban.AuditStream.SecretHint

  test "is the last 4 characters of a secret of at least 16" do
    assert SecretHint.hint("abcdefghijklmnop") == "mnop"
    assert SecretHint.hint("8e1b6a3c-hec-token-wxyz") == "wxyz"
  end

  test "is nil for a secret shorter than 16 codepoints, or nil" do
    for short <- ["", "a", "abcd", String.duplicate("x", 15)] do
      assert SecretHint.hint(short) == nil
    end

    assert SecretHint.hint(nil) == nil
  end

  test "takes the last 4 Unicode characters" do
    assert SecretHint.hint("a-long-tokén-ñüéß") == "ñüéß"
  end

  test "never splits a character made of several codepoints" do
    flag = "\u{1F1EB}\u{1F1F7}"
    family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

    assert SecretHint.hint("long-credential-x" <> flag <> flag) == flag <> flag
    assert SecretHint.hint("long-credential-x" <> "a" <> family) == nil
    assert SecretHint.hint("long-credential-xyz" <> "é") == "yzé"
  end
end
