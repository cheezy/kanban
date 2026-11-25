defmodule Mix.Ios.SimulatorTest do
  use ExUnit.Case, async: true

  import Kanban.IosTools

  alias Mix.Ios.Simulator

  describe "parse/1" do
    test "keeps the simulators that run iOS, with their version and state" do
      assert [
               %Simulator{name: "iPhone 17", udid: "NEW-17", version: {27, 2}, booted?: false},
               %Simulator{name: "iPad (A16)", udid: "NEW-IPAD", version: {27, 2}, booted?: false},
               %Simulator{name: "iPhone 17", udid: "OLD-17", version: {26, 4}, booted?: true}
             ] = simulators() |> Simulator.parse() |> Enum.sort_by(& &1.udid)
    end

    test "reads a runtime that also names a device" do
      runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-10-iPhone19-4"
      devices = %{runtime => [%{"name" => "iPhone Duo", "udid" => "D", "state" => "Shutdown"}]}

      assert [%Simulator{version: {27, 10}}] = Simulator.parse(devices)
    end
  end

  describe "pick/2" do
    test "takes the newest iOS of several with the same name, booted or not" do
      assert %{udid: "NEW-17"} = simulators() |> Simulator.parse() |> Simulator.pick("iPhone 17")
    end

    test "takes a booted one of two with the same iOS" do
      off = %Simulator{name: "iPhone", udid: "A", version: {27, 2}, booted?: false}
      on = %{off | udid: "B", booted?: true}

      assert Simulator.pick([off, on], "iPhone") == on
      assert Simulator.pick([on, off], "iPhone") == on
    end

    test "takes a UDID in either case" do
      parsed = Simulator.parse(simulators())

      assert %{udid: "OLD-17"} = Simulator.pick(parsed, "OLD-17")
      assert %{udid: "OLD-17"} = Simulator.pick(parsed, "old-17")
    end

    test "is nil for an unknown name, and when there are no simulators" do
      assert simulators() |> Simulator.parse() |> Simulator.pick("iPhone 3G") == nil
      assert Simulator.pick([], "iPhone 17") == nil
    end
  end

  describe "find!/2" do
    @describetag :tmp_dir

    test "asks simctl for the available simulators, whatever it warns of", %{tmp_dir: dir} do
      assert %{udid: "NEW-IPAD"} = Simulator.find!("iPad (A16)", stub_tools!(dir))
      assert calls(dir) == ["xcrun simctl list devices available -j"]
    end

    test "names the simulators there are when there is no such one", %{tmp_dir: dir} do
      assert_raise Mix.Error,
                   ~r/No simulator is named iPhone 3G.*: iPad \(A16\), iPhone 17$/,
                   fn -> Simulator.find!("iPhone 3G", stub_tools!(dir)) end
    end

    test "raises when simctl fails or prints something else", %{tmp_dir: dir} do
      for body <- ["exit 1", "echo nonsense", "echo '{}'"] do
        opts = stub_tools!(dir, %{"xcrun" => body})

        assert_raise Mix.Error, ~r/could not list the simulators/, fn ->
          Simulator.find!("iPhone 17", opts)
        end
      end
    end
  end

  @tag :tmp_dir
  test "from_flags!/2 takes the one --simulator names", %{tmp_dir: dir} do
    assert %{udid: "NEW-IPAD"} =
             Simulator.from_flags!([simulator: "iPad (A16)"], stub_tools!(dir))
  end

  test "destination/1 and label/1 name the simulator to xcodebuild and to a person" do
    simulator = %Simulator{name: "iPhone 17", udid: "U", version: {27, 2}, booted?: false}

    assert Simulator.destination(simulator) == "platform=iOS Simulator,id=U"
    assert Simulator.label(simulator) == "iPhone 17 (iOS 27.2)"
  end
end
