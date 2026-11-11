defmodule Kanban.OpenSSL3Test do
  use ExUnit.Case, async: true

  alias Kanban.OpenSSL3

  describe "openssl3?/1" do
    test "accepts OpenSSL 3.0 and later" do
      assert OpenSSL3.openssl3?(
               "OpenSSL 3.0.2 15 Mar 2022 (Library: OpenSSL 3.0.2 15 Mar 2022)\n"
             )

      assert OpenSSL3.openssl3?("OpenSSL 3.6.4 1 Oct 2026\n")
      assert OpenSSL3.openssl3?("OpenSSL 4.0.0 1 Jan 2027\n")
      assert OpenSSL3.openssl3?("OpenSSL 10.1.0 1 Jan 2030\n")
    end

    test "refuses LibreSSL, whatever its version number, and older OpenSSL" do
      refute OpenSSL3.openssl3?("LibreSSL 3.3.6\n")
      refute OpenSSL3.openssl3?("LibreSSL 4.0.0\n")
      refute OpenSSL3.openssl3?("OpenSSL 1.1.1w  11 Sep 2023\n")
      refute OpenSSL3.openssl3?("OpenSSL 0.9.8zh 14 Jan 2016\n")
    end

    test "refuses output that is not a version line" do
      refute OpenSSL3.openssl3?("")
      refute OpenSSL3.openssl3?("command not found")
      refute OpenSSL3.openssl3?("Not OpenSSL 3.0.0")
    end
  end

  describe "executable/0 and exclusions/0" do
    test "agree: the tag is excluded exactly when there is no OpenSSL 3" do
      case OpenSSL3.executable() do
        nil ->
          assert OpenSSL3.exclusions() == [:openssl3]

        path ->
          assert OpenSSL3.exclusions() == []
          assert {version, 0} = System.cmd(path, ["version"])
          assert OpenSSL3.openssl3?(version)
      end
    end
  end
end
