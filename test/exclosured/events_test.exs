defmodule Exclosured.EventsTest do
  use ExUnit.Case

  alias Exclosured.Events.Parser

  # Fixture file: test/fixtures/test_events.rs (checked into repo)
  @test_rs_path "test/fixtures/test_events.rs"

  describe "Parser.parse/1" do
    test "parses annotated structs" do
      source = File.read!(@test_rs_path)
      events = Parser.parse(source)

      assert length(events) == 3
      assert Enum.map(events, & &1.name) == ["ProgressEvent", "CollisionEvent", "SimpleFlag"]
    end

    test "extracts fields with types" do
      source = File.read!(@test_rs_path)
      [progress | _] = Parser.parse(source)

      assert progress.name == "ProgressEvent"
      assert length(progress.fields) == 2
      assert Enum.at(progress.fields, 0) == %{name: "percent", type: "u32"}
      assert Enum.at(progress.fields, 1) == %{name: "stage", type: "String"}
    end

    test "handles multiple field types" do
      source = File.read!(@test_rs_path)
      events = Parser.parse(source)
      simple = Enum.find(events, &(&1.name == "SimpleFlag"))

      assert %{name: "active", type: "bool"} in simple.fields
      assert %{name: "label", type: "String"} in simple.fields
      assert %{name: "tags", type: "Vec<String>"} in simple.fields
      assert %{name: "score", type: "Option<f64>"} in simple.fields
    end

    test "ignores non-annotated structs" do
      source = File.read!(@test_rs_path)
      events = Parser.parse(source)
      names = Enum.map(events, & &1.name)

      refute "InternalState" in names
    end

    test "handles empty source" do
      assert Parser.parse("") == []
    end

    test "handles source with no events" do
      source = """
      pub struct NotAnEvent {
          pub x: i32,
      }
      """

      assert Parser.parse(source) == []
    end
  end

  describe "use Exclosured.Events" do
    defmodule TestEvents do
      use Exclosured.Events, source: "test/fixtures/test_events.rs"
    end

    test "generates struct modules" do
      assert Code.ensure_loaded?(TestEvents.ProgressEvent)
      assert Code.ensure_loaded?(TestEvents.CollisionEvent)
      assert Code.ensure_loaded?(TestEvents.SimpleFlag)
    end

    test "struct has correct fields" do
      event = %TestEvents.ProgressEvent{}
      assert Map.has_key?(event, :percent)
      assert Map.has_key?(event, :stage)
    end

    test "from_payload converts string-key map to struct" do
      payload = %{"percent" => 75, "stage" => "processing"}
      event = TestEvents.ProgressEvent.from_payload(payload)

      assert %TestEvents.ProgressEvent{} = event
      assert event.percent == 75
      assert event.stage == "processing"
    end

    test "from_payload handles extra keys gracefully" do
      payload = %{"percent" => 100, "stage" => "done", "extra" => "ignored"}
      event = TestEvents.ProgressEvent.from_payload(payload)

      assert event.percent == 100
      assert event.stage == "done"
    end

    test "fields/0 returns field name strings" do
      assert TestEvents.ProgressEvent.fields() == ["percent", "stage"]
    end

    test "__events__/0 lists all generated modules" do
      events = TestEvents.__events__()
      assert TestEvents.ProgressEvent in events
      assert TestEvents.CollisionEvent in events
      assert TestEvents.SimpleFlag in events
      assert length(events) == 3
    end

    test "collision event has correct fields" do
      event =
        TestEvents.CollisionEvent.from_payload(%{
          "npc_id" => 42,
          "player_lane" => 1,
          "speed" => 3.14
        })

      assert event.npc_id == 42
      assert event.player_lane == 1
      assert event.speed == 3.14
    end
  end
end
