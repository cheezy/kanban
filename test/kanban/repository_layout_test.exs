defmodule Kanban.RepositoryLayoutTest do
  @moduledoc """
  Guards the repository layout for the native apps (W2774,
  `docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md` section 14).

  The Phoenix app stays at the root and the apps live in `mobile/`. These tests
  pin the ignore rules that keep build output and signing material out of git,
  the Docker and CI exclusions for `mobile/`, and the agreement between
  `AGENTS.md` and the `mobile/` instruction files.

  Ignore rules are checked with `git check-ignore --no-index` on paths that
  need not exist, under both `core.ignorecase` settings: macOS checkouts ignore
  case and Linux CI does not, and an unanchored rule such as `stride/` once
  swallowed the iOS source folder `mobile/ios/Stride/` on macOS only.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @ignored [
    "node_modules/x",
    "package.json",
    "assets/node_modules/x",
    "tools/dark-mode-audit/node_modules/x",
    "tools/dark-mode-audit/package.json",
    "mobile/android/local.properties",
    "mobile/android/keystore.properties",
    "mobile/android/app/upload.jks",
    "mobile/android/app/upload.JKS",
    "mobile/android/app/release.keystore",
    "mobile/ios/AuthKey_X.p8",
    "mobile/ios/AuthKey_X.P8",
    "mobile/ios/dist.p12",
    "mobile/ios/Dev.mobileprovision",
    "mobile/ios/fastlane/.env",
    "mobile/ios/fastlane/api_key.json",
    "mobile/ios/Stride.xcodeproj/project.pbxproj",
    "mobile/ios/build/x",
    "mobile/ios/DerivedData/x",
    "mobile/ios/Stride.ipa",
    "mobile/android/build/x",
    "mobile/android/app/build/x",
    "mobile/android/.gradle/x",
    "mobile/android/app/release/app-release.aab",
    "mobile/shared/tokens/TOKENS"
  ]

  @committable [
    "mobile/CLAUDE.md",
    "mobile/ios/CLAUDE.md",
    "mobile/android/CLAUDE.md",
    "mobile/shared/README.md",
    "mobile/shared/tokens/README.md",
    "mobile/shared/tokens/tokens.json",
    "mobile/shared/strings/de.json",
    "mobile/shared/fixtures/me.json",
    "mobile/package.json",
    "mobile/ios/project.yml",
    "mobile/ios/Stride/App/StrideApp.swift",
    "mobile/ios/Stride/DesignSystem/Tokens/Colors.swift",
    "mobile/ios/Stride/Features/Build/BuildView.swift",
    "mobile/ios/StrideKit/Package.swift",
    "mobile/ios/fastlane/Fastfile",
    "mobile/android/settings.gradle.kts",
    "mobile/android/gradle/libs.versions.toml",
    "mobile/android/app/src/main/AndroidManifest.xml"
  ]

  @rule_headings [
    "Support both themes",
    "Ship all seven locales",
    "Label everything for accessibility",
    "Keep business logic out of views",
    "Regenerate after changing a source"
  ]

  @claude_files ["mobile/CLAUDE.md", "mobile/ios/CLAUDE.md", "mobile/android/CLAUDE.md"]

  defp ignored?(path, ignorecase) do
    {_out, status} =
      System.cmd(
        "git",
        ["-c", "core.ignorecase=#{ignorecase}", "check-ignore", "-q", "--no-index", path],
        cd: @root,
        stderr_to_stdout: true
      )

    case status do
      0 -> true
      1 -> false
      other -> flunk("git check-ignore exited #{other} for #{path}")
    end
  end

  defp read!(path), do: @root |> Path.join(path) |> File.read!()

  describe ".gitignore" do
    for ignorecase <- [true, false] do
      test "ignores build output and signing material with core.ignorecase=#{ignorecase}" do
        wrongly_committable = Enum.reject(@ignored, &ignored?(&1, unquote(ignorecase)))
        assert wrongly_committable == []
      end

      test "keeps app sources and instruction files committable with core.ignorecase=#{ignorecase}" do
        wrongly_ignored = Enum.filter(@committable, &ignored?(&1, unquote(ignorecase)))
        assert wrongly_ignored == []
      end
    end
  end

  describe "build and CI exclusions" do
    test ".dockerignore keeps mobile/ out of the Docker build context" do
      lines = ".dockerignore" |> read!() |> String.split("\n") |> Enum.map(&String.trim/1)
      assert "/mobile/" in lines
    end

    test "elixir.yml skips pushes and pull requests that change only mobile/" do
      workflow = read!(".github/workflows/elixir.yml")
      [triggers | _] = String.split(workflow, "\njobs:")

      for event <- ["push", "pull_request"] do
        assert triggers =~ ~r/\n  #{event}:\n(    .*\n)*    paths-ignore: \[ "mobile\/\*\*" \]\n/,
               "#{event} trigger has no paths-ignore for mobile/**"
      end
    end
  end

  describe "agent instructions" do
    test "AGENTS.md names every mobile instruction file, and each exists" do
      agents = read!("AGENTS.md")

      for path <- @claude_files do
        assert agents =~ "`#{path}`", "AGENTS.md does not name #{path}"
        assert @root |> Path.join(path) |> File.regular?(), "#{path} is missing"
      end
    end

    test "every mobile instruction file carries the five app rules" do
      for path <- @claude_files, heading <- @rule_headings do
        assert read!(path) =~ "**#{heading}.**", "#{path} lacks the rule: #{heading}"
      end
    end
  end
end
