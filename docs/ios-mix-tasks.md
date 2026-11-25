# iOS Mix Tasks

This document is for contributors who work on the native iOS and iPadOS app in
`mobile/ios`. Two Mix tasks build, test and start it from the repository root.
Both need a Mac with Xcode and XcodeGen.

| Task | What it does |
|---|---|
| `mix ios.test` | Runs the `Stride` scheme's tests on a simulator and shows each result as it arrives |
| `mix ios.deploy` | Builds the app, installs it and starts it on a simulator or a connected device |

Each one first generates `Stride.xcodeproj` from `mobile/ios/project.yml`, so a
change to `project.yml` is always picked up. `mix help ios.test` and
`mix help ios.deploy` list every option.

Mix compiles the Phoenix app before it runs a task. While a development server is
running, put `MIX_ENV=test` in front so that the compile does not touch the
server's build. Agents and the hooks always do.

## Running the tests

```bash
mix ios.test
```

```bash
mix ios.test StrideKitTests/AuthStoreTests
```

With no names it runs the whole scheme. A name is what
`xcodebuild -only-testing:` takes: a test target, a suite in it, or a test in
that. You can give several.

It prints each target as its build starts, every test's result, and every error
and compiler warning. When a run fails it repeats the failures at the end, so
they are the last thing on the screen. It fails when:

- `xcodegen` or `xcodebuild` fails.
- No Swift Testing test ran, so a scheme that lost its tests does not pass. When
  you named tests, an XCTest counts too.

`--verbose` prints every line of `xcodebuild` output instead.

## Starting the app

```bash
mix ios.deploy
```

It boots the simulator when it is off, installs the app and starts it, stopping a
copy that is already running. It does not open a window, because the simulator
may be on screen already, for example in Claude's simulator panel. To see it in
Apple's own app, add `--open`:

```bash
mix ios.deploy --open
```

That app is Simulator, or Device Hub from Xcode 27. Quitting Device Hub also
shuts down the simulators that are running, even one that Claude's panel shows.

`mix ios.deploy` does not upload to TestFlight or the App Store.

### On a connected iPhone or iPad

```bash
DEVELOPMENT_TEAM=<team id> mix ios.deploy --device "My iPhone"
```

`xcrun devicectl list devices` shows the names and UDIDs. A build for a device
must be signed, and the repository holds no signing team, so the task reads the
ten-character team id from `DEVELOPMENT_TEAM` and stops without it. Keep the id
out of the repository. Before the first run, add your Apple account to Xcode and
turn on Developer Mode on the device.

If Xcode says that signing needs something from your developer account, such as
registering the device, let it do that with
`mix ios.deploy --device "My iPhone" -- -allowProvisioningUpdates`. The task never
passes that option itself.

## Choosing the simulator

Both tasks use an iPhone 17. Choose another one for a run with `--simulator`, or
for every run with `IOS_SIMULATOR`. Either takes a name or a UDID:

```bash
mix ios.test --simulator "iPad (A16)"
```

Of several simulators with the same name, the one with the newest iOS is used.
`xcrun simctl list devices available` lists what is installed.

## Passing options to xcodebuild

Anything after `--` goes to `xcodebuild` unchanged:

```bash
mix ios.test -- -retry-tests-on-failure
```

## Logs and stopping

The complete `xcodebuild` output of the last run is in
`mobile/ios/build/ios.test.log` or `mobile/ios/build/ios.deploy.log`, which git
ignores.

When the task is stopped, by you or by a hook's time limit, `xcodebuild` is
stopped with it. It does not go on running in the background.

## How it is built

- `Mix.Ios` ([`lib/mix/ios.ex`](../lib/mix/ios.ex)) finds and runs the
  command-line tools. Its streaming call starts them through a small shell
  wrapper, because a program started from an Erlang port otherwise outlives the
  VM.
- `Mix.Ios.Simulator` ([`lib/mix/ios/simulator.ex`](../lib/mix/ios/simulator.ex))
  picks the simulator from what `xcrun simctl` lists.
- `Mix.Ios.Output` ([`lib/mix/ios/output.ex`](../lib/mix/ios/output.ex)) decides
  which lines to show, counts the tests and keeps the failures. Change
  `classify/1` when a new Xcode words its output differently, and add the line to
  the list in `test/mix/ios/output_test.exs`.

The tests use stub tools from
[`test/support/ios_tools.ex`](../test/support/ios_tools.ex), so they run without
Xcode, in CI too.

The iOS hook set runs `mix ios.test` before each task commit. See
[the iOS hook set](hook-time-budget.md#the-ios-hook-set). CI does not use these
tasks: `.github/workflows/ios.yml` calls `xcodebuild` in separate build and test
steps.
