defmodule Dran.SettingsTest do
  use Dran.DataCase, async: true

  alias Dran.Settings

  describe "get/1" do
    test "returns default when no row in DB" do
      assert Settings.get("semantic_threshold_short") == 0.15
      assert Settings.get("semantic_threshold_mid") == 0.22
      assert Settings.get("semantic_threshold_long") == 0.28
      assert Settings.get("agent_max_pages") == 10
      assert Settings.get("agent_max_sources") == 10
      assert Settings.get("daily_note_enabled") == true
    end

    test "returns nil for unknown key without default" do
      assert Settings.get("nonexistent_key") == nil
    end
  end

  describe "put/2" do
    test "persists value and get reads it back" do

    end

    test "put twice updates the same row (upsert)" do
      Settings.put("agent_max_pages", 5)
      assert Settings.get("agent_max_pages") == 5

      Settings.put("agent_max_pages", 25)
      assert Settings.get("agent_max_pages") == 25

      # Only one row exists for this key
      count =
        Dran.Repo.aggregate(
          Ecto.Query.from(s in "settings", where: s.key == "agent_max_pages"),
          :count
        )

      assert count == 1
    end

    test "persists complex values (maps, lists)" do
      Settings.put("custom_config", %{"nested" => [1, 2, 3], "enabled" => true})
      assert Settings.get("custom_config") == %{"nested" => [1, 2, 3], "enabled" => true}
    end
  end

  describe "all/0" do
    test "merges defaults with DB overrides" do
      Settings.put("agent_max_pages", 42)

      all = Settings.all()

      # Defaults present
      assert all["semantic_threshold_short"] == 0.15
      assert all["semantic_threshold_mid"] == 0.22
      assert all["semantic_threshold_long"] == 0.28
      assert all["agent_max_sources"] == 10
      assert all["daily_note_enabled"] == true

      # DB overrides win
      assert all["agent_max_pages"] == 42
    end

    test "returns defaults when DB empty" do
      all = Settings.all()
      assert all == Settings.defaults()
    end
  end

  describe "defaults/0" do
    test "returns the full defaults map" do
      defaults = Settings.defaults()

      assert defaults["semantic_threshold_short"] == 0.15
      assert defaults["semantic_threshold_mid"] == 0.22
      assert defaults["semantic_threshold_long"] == 0.28
      assert defaults["agent_max_pages"] == 10
      assert defaults["agent_max_sources"] == 10
      assert defaults["daily_note_enabled"] == true
    end
  end
end
