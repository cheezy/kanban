defmodule KanbanWeb.API.SkillsVersionTest do
  use ExUnit.Case, async: true

  alias KanbanWeb.API.SkillsVersion

  doctest KanbanWeb.API.SkillsVersion

  describe "stale?/2 — the four cases D267 was filed for" do
    test "a strictly older version is stale" do
      assert SkillsVersion.stale?("0.1", "1.0")
    end

    test "an equal version is not stale" do
      refute SkillsVersion.stale?("1.0", "1.0")
    end

    test "a NEWER version is not stale" do
      # The headline defect: a plugin shipping ahead of the server, or a server
      # rollback, was told its skills were outdated on every poll.
      refute SkillsVersion.stale?("2.0", "1.0")
      refute SkillsVersion.stale?("99.0", "1.0")
    end

    test "a whitespace-padded current version is not stale" do
      # A quoting artifact must not read as a different version.
      refute SkillsVersion.stale?("1.0 ", "1.0")
      refute SkillsVersion.stale?(" 1.0", "1.0")
      refute SkillsVersion.stale?("\t1.0\n", "1.0")
    end

    test "an unparsable version is not stale, because it is not strictly older" do
      refute SkillsVersion.stale?("abc", "1.0")
      refute SkillsVersion.stale?("1.x", "1.0")
      refute SkillsVersion.stale?("v1.0", "1.0")
      refute SkillsVersion.stale?("1..0", "1.0")
      refute SkillsVersion.stale?("-1", "1.0")
    end
  end

  describe "stale?/2 — absent and blank stay exempt" do
    # D267 explicitly required preserving today's behaviour for these two.
    test "nil is not stale" do
      refute SkillsVersion.stale?(nil, "1.0")
    end

    test "an empty string is not stale" do
      refute SkillsVersion.stale?("", "1.0")
    end

    test "a whitespace-only string is not stale" do
      refute SkillsVersion.stale?("   ", "1.0")
    end

    test "a non-binary reported version is not stale" do
      refute SkillsVersion.stale?(:not_a_version, "1.0")
      refute SkillsVersion.stale?(10, "1.0")
    end
  end

  describe "stale?/2 — comparison is numeric, not lexicographic" do
    test "1.9 is older than 1.10" do
      # A string compare puts "1.10" below "1.9" and would call a NEWER agent
      # stale. This is the case that makes component-wise parsing necessary
      # rather than merely tidy.
      assert SkillsVersion.stale?("1.9", "1.10")
      refute SkillsVersion.stale?("1.10", "1.9")
    end

    test "2.0 is newer than 10.0 is false — the leading component still governs" do
      assert SkillsVersion.stale?("2.0", "10.0")
      refute SkillsVersion.stale?("10.0", "2.0")
    end
  end

  describe "stale?/2 — missing trailing components are zero" do
    test "1, 1.0 and 1.0.0 are the same version" do
      refute SkillsVersion.stale?("1", "1.0")
      refute SkillsVersion.stale?("1.0", "1")
      refute SkillsVersion.stale?("1.0.0", "1.0")
      refute SkillsVersion.stale?("1.0", "1.0.0")
    end

    test "a trailing non-zero component still orders" do
      assert SkillsVersion.stale?("1.0", "1.0.1")
      refute SkillsVersion.stale?("1.0.1", "1.0")
    end
  end

  describe "stale?/2 — pre-release and build suffixes order on their numeric core" do
    test "a pre-release of an older version is stale" do
      # This shape is live in the suite: a completion test sends
      # "0.0.1-stale". Treating it as unorderable would discard a leading 0
      # that orders it against a server on 1.0 perfectly well.
      assert SkillsVersion.stale?("0.0.1-stale", "1.0")
      assert SkillsVersion.stale?("0.9.0-rc.1", "1.0")
    end

    test "a build-metadata suffix orders on the core too" do
      assert SkillsVersion.stale?("0.1.0+build.7", "1.0")
      refute SkillsVersion.stale?("2.0.0+build.7", "1.0")
    end

    test "a pre-release compares EQUAL to its release, so it draws no directive" do
      # Deliberate and conservative: the rule admits only strictly older, and
      # an agent one pre-release step from current has nothing useful to be
      # told. Note this is looser than SemVer, which orders a pre-release
      # BELOW its release.
      refute SkillsVersion.stale?("1.0.0-alpha", "1.0.0")
      refute SkillsVersion.stale?("1.0-rc1", "1.0")
    end

    test "a suffix cannot rescue an otherwise unparsable core" do
      refute SkillsVersion.stale?("abc-1", "1.0")
      refute SkillsVersion.stale?("-1", "1.0")
    end
  end

  describe "stale?/2 — a port that pins its constant never goes stale" do
    test "a pinned constant equal to the server's is current" do
      # Per fleet convention skills_version is not a totally-ordered space
      # across runtimes: some ports ship "1.0" forever. Such a port must never
      # be told to update, or the directive is unsatisfiable for its lifetime.
      refute SkillsVersion.stale?("1.0", "1.0")
    end

    test "a pinned constant the parser would reject is still current when it matches" do
      # The exact-match short-circuit runs before parsing, so an unparsable but
      # IDENTICAL constant on both sides reads as current rather than unknown.
      refute SkillsVersion.stale?("2024-06-01", "2024-06-01")
      refute SkillsVersion.stale?("stable", "stable")
    end
  end
end
