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

  # The app workflows from section 15.1 of the design (W2775). Each one runs on
  # its own app, the shared files and the API contract, skips its jobs until
  # its project file exists, needs no secrets and pins every action it uses.
  describe "app workflows" do
    test "elixir.yml does not wait on the app workflows" do
      workflow = read!(".github/workflows/elixir.yml")

      for name <- ["ios.yml", "android.yml", "workflow_run", "iOS CI", "Android CI"] do
        refute workflow =~ name, "elixir.yml refers to #{name}"
      end
    end

    for {file, app, project} <- [
          {"ios.yml", "mobile/ios", "mobile/ios/project.yml"},
          {"android.yml", "mobile/android", "mobile/android/settings.gradle.kts"}
        ] do
      @workflow_path ".github/workflows/#{file}"
      @app_dir app
      @project_file project

      test "#{file} runs on #{app}, mobile/shared and the API contract" do
        workflow = read!(@workflow_path)

        for event <- ["push", "pull_request"] do
          paths = trigger_paths(workflow, event)

          for path <- ["#{@app_dir}/**", "mobile/shared/**", "priv/openapi/**", @workflow_path] do
            assert path in paths, "#{@workflow_path} #{event} trigger does not run on #{path}"
          end
        end
      end

      test "#{file} runs pull requests from forks without secrets" do
        workflow = read!(@workflow_path)

        assert workflow =~ "\n  pull_request:\n"
        assert workflow =~ "\npermissions:\n  contents: read\n"
        refute workflow =~ "pull_request_target"
        refute workflow =~ ~r/secrets\./, "#{@workflow_path} reads a secret"
      end

      test "#{file} skips every build job until #{project} exists" do
        workflow = read!(@workflow_path)
        guarded = "    needs: project\n    if: needs.project.outputs.present == 'true'\n"

        assert workflow =~ "present=\"${{ hashFiles('#{@project_file}') != '' }}\""

        jobs = job_names(workflow)
        assert "project" in jobs and length(jobs) > 1

        for job <- jobs, job != "project" do
          assert job_body(workflow, job) =~ guarded,
                 "#{@workflow_path} job #{job} is not skipped when #{@project_file} is missing"
        end
      end

      test "#{file} pins every action to a commit" do
        uses =
          Regex.scan(~r/^\s+(?:- )?uses: (\S+)(.*)$/m, read!(@workflow_path),
            capture: :all_but_first
          )

        assert uses != []

        for [action, comment] <- uses do
          assert action =~ ~r/@[0-9a-f]{40}$/,
                 "#{@workflow_path} does not pin #{action} to a commit"

          assert comment =~ ~r/^ # v\d/,
                 "#{@workflow_path} gives no version comment for #{action}"
        end
      end
    end
  end

  # The quoted list items under one trigger event, which are its `paths`.
  defp trigger_paths(workflow, event) do
    [triggers | _] = String.split(workflow, "\njobs:")
    [_, block] = Regex.run(~r/\n  #{event}:\n((?:    .*\n)*)/, triggers)
    ~r/^      - "([^"]+)"$/m |> Regex.scan(block, capture: :all_but_first) |> List.flatten()
  end

  defp job_names(workflow) do
    [_, jobs] = String.split(workflow, "\njobs:\n", parts: 2)
    ~r/^  ([a-z_-]+):$/m |> Regex.scan(jobs, capture: :all_but_first) |> List.flatten()
  end

  defp job_body(workflow, job) do
    [_, after_job] = String.split(workflow, "\n  #{job}:\n", parts: 2)
    after_job |> String.split(~r/\n  [a-z_-]+:\n/, parts: 2) |> hd()
  end
end
