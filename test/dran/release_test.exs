defmodule Dran.ReleaseTest do
  @moduledoc """
  The production-seed contract: `seed/0` evaluates the production seed, never
  the demo dataset.

  Pointing `seed/0` at `priv/repo/seeds.exs` is the mistake that sows demo data
  — accounts whose passwords are published in this repository — into a
  production deploy. The path is pinned here, and the demo entry point refuses
  to run inside a release.

  Family standard: `BOOTSTRAP.md` (the production seed does not exist in the
  scaffold) and `SPEC-docker.md` §Entrypoint.
  """

  # It mutates MIX_ENV, which is global state.
  use ExUnit.Case, async: false

  test "seed/0 evaluates the production seed, never the demo dataset" do
    seeds_file = Dran.Release.seeds_file()

    assert seeds_file =~ "seeds_prod.exs"
    refute seeds_file =~ ~r{/seeds\.exs$}
    assert File.exists?(seeds_file), "#{seeds_file} does not exist"
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
