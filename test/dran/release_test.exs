defmodule Dran.ReleaseTest do
  @moduledoc """
  The seeding contract: a release seeds the **instance row** and nothing else.

  There is no env-driven bootstrap account any more — the owner is born in the
  first-run `/setup` screen (`DranWeb.SessionController.setup/2`), so no
  credential ever travels through an environment variable. The demo dataset
  (`priv/repo/seeds.exs`, content only, no accounts) stays behind
  `seed_demo/0`, which refuses to run inside a release.
  """

  # It mutates MIX_ENV, which is global state.
  use ExUnit.Case, async: false

  test "there is no env-driven production seed any more" do
    # Not a style check: this is the guard against the bootstrap account coming
    # back through an env var (it left with priv/repo/seeds_prod.exs). The owner
    # is created by DranWeb.SessionController.setup/2 on the first-run screen.
    refute function_exported?(Dran.Release, :seed, 0)
    refute function_exported?(Dran.Release, :seeds_file, 0)
    refute File.exists?(Application.app_dir(:dran, "priv/repo/seeds_prod.exs"))
  end

  test "seed_demo/0 refuses to run inside a release" do
    previous = System.get_env("MIX_ENV")

    on_exit(fn ->
      if previous do
        System.put_env("MIX_ENV", previous)
      else
        System.delete_env("MIX_ENV")
      end
    end)

    # A release runs with no MIX_ENV and its config is :prod.
    System.delete_env("MIX_ENV")

    assert_raise RuntimeError, ~r/refusing to run the demo seed/, fn ->
      Dran.Release.seed_demo()
    end

    # `bin/dran eval` from an image built with MIX_ENV=prod reports "prod".
    System.put_env("MIX_ENV", "prod")

    assert_raise RuntimeError, ~r/refusing to run the demo seed/, fn ->
      Dran.Release.seed_demo()
    end
  end
end
