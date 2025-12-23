defmodule Kanban.Tasks.AIContextFieldsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  describe "security_considerations field (W23)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, column: column}
    end

    test "accepts valid security_considerations array", %{column: column} do
      attrs = %{
        title: "Test task",
        security_considerations: [
          "Store tokens hashed with SHA-256",
          "Never log tokens in telemetry",
          "Validate scopes before allowing operations"
        ]
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert length(task.security_considerations) == 3
      assert "Store tokens hashed with SHA-256" in task.security_considerations
      assert "Never log tokens in telemetry" in task.security_considerations
    end

    test "accepts nil security_considerations", %{column: column} do
      attrs = %{title: "Test task", security_considerations: nil}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.security_considerations == []
    end

    test "accepts empty array for security_considerations", %{column: column} do
      attrs = %{title: "Test task", security_considerations: []}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.security_considerations == []
    end

    test "defaults to empty array when not provided", %{column: column} do
      attrs = %{title: "Test task"}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.security_considerations == []
    end

    test "rejects array with non-string values", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        security_considerations: ["Valid string", 123, :invalid_atom]
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list of strings" in errors_on(changeset).security_considerations
    end

    test "rejects non-list values", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        security_considerations: "not a list"
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a list" in errors_on(changeset).security_considerations
    end

    test "updates security_considerations", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          title: "Test task",
          security_considerations: ["Initial security note"]
        })

      {:ok, updated_task} =
        Tasks.update_task(task, %{
          security_considerations: [
            "Updated security note",
            "Additional security requirement"
          ]
        })

      assert length(updated_task.security_considerations) == 2
      assert "Updated security note" in updated_task.security_considerations
      refute "Initial security note" in updated_task.security_considerations
    end
  end

  describe "testing_strategy field (W23)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, column: column}
    end

    test "accepts valid testing_strategy with all keys", %{column: column} do
      attrs = %{
        title: "Test task",
        testing_strategy: %{
          "unit_tests" => ["Test token generation", "Test token validation"],
          "integration_tests" => ["Test API auth plug"],
          "manual_tests" => ["Create token in UI"]
        }
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.testing_strategy["unit_tests"] == [
               "Test token generation",
               "Test token validation"
             ]

      assert task.testing_strategy["integration_tests"] == ["Test API auth plug"]
      assert task.testing_strategy["manual_tests"] == ["Create token in UI"]
    end

    test "accepts testing_strategy with subset of keys", %{column: column} do
      attrs = %{
        title: "Test task",
        testing_strategy: %{
          "unit_tests" => ["Unit test 1", "Unit test 2"]
        }
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.testing_strategy["unit_tests"] == ["Unit test 1", "Unit test 2"]
      refute Map.has_key?(task.testing_strategy, "integration_tests")
    end

    test "accepts empty map for testing_strategy", %{column: column} do
      attrs = %{title: "Test task", testing_strategy: %{}}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.testing_strategy == %{}
    end

    test "accepts nil testing_strategy", %{column: column} do
      attrs = %{title: "Test task", testing_strategy: nil}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.testing_strategy == %{}
    end

    test "defaults to empty map when not provided", %{column: column} do
      attrs = %{title: "Test task"}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.testing_strategy == %{}
    end

    test "rejects testing_strategy with invalid keys", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        testing_strategy: %{
          "unit_tests" => ["Valid"],
          "invalid_key" => ["Should fail"]
        }
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?

      assert "contains invalid keys: invalid_key. Valid keys: unit_tests, integration_tests, manual_tests" in errors_on(
               changeset
             ).testing_strategy
    end

    test "rejects testing_strategy with non-array values", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        testing_strategy: %{
          "unit_tests" => "not an array"
        }
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "all values must be arrays of strings" in errors_on(changeset).testing_strategy
    end

    test "rejects testing_strategy with array containing non-strings", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        testing_strategy: %{
          "unit_tests" => ["Valid string", 123, :atom]
        }
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "all values must be arrays of strings" in errors_on(changeset).testing_strategy
    end

    test "rejects non-map testing_strategy", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        testing_strategy: "not a map"
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a map" in errors_on(changeset).testing_strategy
    end

    test "updates testing_strategy", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          title: "Test task",
          testing_strategy: %{
            "unit_tests" => ["Initial test"]
          }
        })

      {:ok, updated_task} =
        Tasks.update_task(task, %{
          testing_strategy: %{
            "unit_tests" => ["Updated test 1", "Updated test 2"],
            "integration_tests" => ["New integration test"]
          }
        })

      assert length(updated_task.testing_strategy["unit_tests"]) == 2
      assert updated_task.testing_strategy["integration_tests"] == ["New integration test"]
    end
  end

  describe "integration_points field (W23)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, column: column}
    end

    test "accepts valid integration_points with all keys", %{column: column} do
      attrs = %{
        title: "Test task",
        integration_points: %{
          "telemetry_events" => ["[:kanban, :api, :token_created]"],
          "pubsub_broadcasts" => ["board:updated"],
          "phoenix_channels" => ["user:socket"],
          "external_apis" => ["https://api.example.com"]
        }
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.integration_points["telemetry_events"] == ["[:kanban, :api, :token_created]"]
      assert task.integration_points["pubsub_broadcasts"] == ["board:updated"]
      assert task.integration_points["phoenix_channels"] == ["user:socket"]
      assert task.integration_points["external_apis"] == ["https://api.example.com"]
    end

    test "accepts integration_points with subset of keys", %{column: column} do
      attrs = %{
        title: "Test task",
        integration_points: %{
          "telemetry_events" => ["[:kanban, :task, :completed]"]
        }
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.integration_points["telemetry_events"] == ["[:kanban, :task, :completed]"]
      refute Map.has_key?(task.integration_points, "pubsub_broadcasts")
    end

    test "accepts empty map for integration_points", %{column: column} do
      attrs = %{title: "Test task", integration_points: %{}}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.integration_points == %{}
    end

    test "accepts nil integration_points", %{column: column} do
      attrs = %{title: "Test task", integration_points: nil}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.integration_points == %{}
    end

    test "defaults to empty map when not provided", %{column: column} do
      attrs = %{title: "Test task"}
      {:ok, task} = Tasks.create_task(column, attrs)
      assert task.integration_points == %{}
    end

    test "rejects integration_points with invalid keys", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        integration_points: %{
          "telemetry_events" => ["Valid"],
          "invalid_key" => ["Should fail"]
        }
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?

      assert "contains invalid keys: invalid_key. Valid keys: telemetry_events, pubsub_broadcasts, phoenix_channels, external_apis" in errors_on(
               changeset
             ).integration_points
    end

    test "rejects integration_points with non-array values", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        integration_points: %{
          "telemetry_events" => "not an array"
        }
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "all values must be arrays of strings" in errors_on(changeset).integration_points
    end

    test "rejects integration_points with array containing non-strings", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        integration_points: %{
          "telemetry_events" => ["Valid event", 123, :invalid]
        }
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "all values must be arrays of strings" in errors_on(changeset).integration_points
    end

    test "rejects non-map integration_points", %{column: _column} do
      task = %Task{
        title: "Test task",
        position: 0,
        type: :work,
        priority: :medium,
        status: :open,
        integration_points: "not a map"
      }

      changeset = Task.changeset(task, %{})
      refute changeset.valid?
      assert "must be a map" in errors_on(changeset).integration_points
    end

    test "updates integration_points", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          title: "Test task",
          integration_points: %{
            "telemetry_events" => ["[:kanban, :initial, :event]"]
          }
        })

      {:ok, updated_task} =
        Tasks.update_task(task, %{
          integration_points: %{
            "telemetry_events" => ["[:kanban, :updated, :event]"],
            "pubsub_broadcasts" => ["new:broadcast"]
          }
        })

      assert updated_task.integration_points["telemetry_events"] == [
               "[:kanban, :updated, :event]"
             ]

      assert updated_task.integration_points["pubsub_broadcasts"] == ["new:broadcast"]
    end
  end

  describe "all three AI context fields together (W23)" do
    setup do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)
      {:ok, column: column}
    end

    test "creates task with all three AI context fields populated", %{column: column} do
      attrs = %{
        title: "Comprehensive AI task",
        security_considerations: [
          "Hash all sensitive data",
          "Use parameterized queries to prevent SQL injection"
        ],
        testing_strategy: %{
          "unit_tests" => ["Test hashing function", "Test query builder"],
          "integration_tests" => ["Test end-to-end auth flow"],
          "manual_tests" => ["Verify security headers in browser"]
        },
        integration_points: %{
          "telemetry_events" => ["[:app, :auth, :success]", "[:app, :auth, :failure]"],
          "pubsub_broadcasts" => ["user:authenticated"],
          "phoenix_channels" => [],
          "external_apis" => []
        }
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert length(task.security_considerations) == 2
      assert map_size(task.testing_strategy) == 3
      assert map_size(task.integration_points) == 4
      assert task.security_considerations == attrs.security_considerations
      assert task.testing_strategy == attrs.testing_strategy
      assert task.integration_points == attrs.integration_points
    end

    test "creates task with only some AI context fields populated", %{column: column} do
      attrs = %{
        title: "Partial AI task",
        security_considerations: ["Important security note"],
        testing_strategy: %{},
        integration_points: %{"telemetry_events" => ["[:app, :event]"]}
      }

      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.security_considerations == ["Important security note"]
      assert task.testing_strategy == %{}
      assert task.integration_points == %{"telemetry_events" => ["[:app, :event]"]}
    end

    test "updates all three AI context fields at once", %{column: column} do
      {:ok, task} =
        Tasks.create_task(column, %{
          title: "Test task",
          security_considerations: ["Initial"],
          testing_strategy: %{"unit_tests" => ["Initial test"]},
          integration_points: %{"telemetry_events" => ["[:initial, :event]"]}
        })

      {:ok, updated_task} =
        Tasks.update_task(task, %{
          security_considerations: ["Updated security"],
          testing_strategy: %{"unit_tests" => ["Updated test"]},
          integration_points: %{"pubsub_broadcasts" => ["updated:broadcast"]}
        })

      assert updated_task.security_considerations == ["Updated security"]
      assert updated_task.testing_strategy == %{"unit_tests" => ["Updated test"]}
      assert updated_task.integration_points == %{"pubsub_broadcasts" => ["updated:broadcast"]}
    end

    test "all three fields use defaults when not provided", %{column: column} do
      attrs = %{title: "Minimal task"}
      {:ok, task} = Tasks.create_task(column, attrs)

      assert task.security_considerations == []
      assert task.testing_strategy == %{}
      assert task.integration_points == %{}
    end
  end
end
