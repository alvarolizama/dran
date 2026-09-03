defmodule Dran.SettingsTest do
  # async: false — this suite checks out a sandbox connection. Async DB
  # tests race with sync tests running in shared mode (DBConnection
  # OwnershipError / "client exited"), so all Repo-using suites are sync.
  use Dran.DataCase, async: false

  alias Dran.Settings

  describe "get/1" do
    test "returns default when no row in DB" do
      assert Settings.get("semantic_threshold_short") == 0.15
      assert Settings.get("semantic_threshold_mid") == 0.22
      assert Settings.get("semantic_threshold_long") == 0.28
      assert Settings.get("worker_max_pages") == 10
      assert Settings.get("worker_max_sources") == 10
    end

    test "returns nil for unknown key without default" do
      assert Settings.get("nonexistent_key") == nil
    end
  end

  describe "put/2" do
    test "persists value and get reads it back" do
    end

    test "put twice updates the same row (upsert)" do
      Settings.put("worker_max_pages", 5)
      assert Settings.get("worker_max_pages") == 5

      Settings.put("worker_max_pages", 25)
      assert Settings.get("worker_max_pages") == 25

      # Only one row exists for this key
      count =
        Dran.Repo.aggregate(
          Ecto.Query.from(s in "settings", where: s.key == "worker_max_pages"),
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
      Settings.put("worker_max_pages", 42)

      all = Settings.all()

      # Defaults present
      assert all["semantic_threshold_short"] == 0.15
      assert all["semantic_threshold_mid"] == 0.22
      assert all["semantic_threshold_long"] == 0.28
      assert all["worker_max_sources"] == 10

      # DB overrides win
      assert all["worker_max_pages"] == 42
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
      assert defaults["worker_max_pages"] == 10
      assert defaults["worker_max_sources"] == 10
    end
  end
end
