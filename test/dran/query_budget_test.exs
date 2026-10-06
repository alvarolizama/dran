defmodule Dran.QueryBudgetTest do
  @moduledoc "P7 (contract auditoria-fixes): presupuesto de queries medido."
  use DranWeb.ConnCase, async: false

  alias Dran.Accounts

  test "GET /api/knowledge-pages — query budget after W2/W7" do
    ws = Dran.DataCase.ensure_workspace!()
    _ = ws

    {:ok, user} =
      Accounts.create_user(%{
        email: "p7-#{System.unique_integer([:positive])}@e.com",
        api_token: "tp7#{System.unique_integer([:positive])}",
        name: "P7"
      })

    self = self()

    :telemetry.attach(
      "p7-probe",
      [:dran, :repo, :query],
      fn _e, _m, metadata, _c -> send(self, {:q, normalize(metadata)}) end,
      nil
    )

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{user.api_token}")
      |> Phoenix.ConnTest.get("/api/knowledge-pages")

    assert conn.status == 200
    Process.sleep(50)
    :telemetry.detach("p7-probe")

    queries =
      collect([])
      |> Enum.reject(&(&1 =~ ~r/BEGIN|COMMIT|ROLLBACK|SAVEPOINT/))

    ws_queries = Enum.count(queries, &(&1 =~ ~r/FROM "?workspaces"?/i))
    users_queries = Enum.count(queries, &(&1 =~ ~r/FROM "?users"?/i))
    uw_queries = Enum.count(queries, &(&1 =~ ~r/user_workspaces/i))

    IO.puts(
      "TOTAL: #{length(queries)} | workspaces: #{ws_queries} | users: #{users_queries} | user_workspaces: #{uw_queries}"
    )

    assert length(queries) <= 9,
           "P7: el GET del API ejecuta #{length(queries)} queries (> 9)"

    # La fila de instancia se lee UNA vez por request (W7): 1 el plug que arma
    # la caché + 1 el setup del test. Más de 2 lecturas de workspaces significa
    # que la caché no está funcionando.
    assert ws_queries <= 2,
           "P7: #{ws_queries} lecturas de workspaces (> 2) — la caché por request no está funcionando"

    # El preload multi-workspace muerto ya no corre en el camino de auth.
    assert uw_queries == 0, "P7: user_workspaces queries = #{uw_queries} (> 0)"
  end

  defp collect(acc) do
    receive do
      {:q, sql} -> collect([sql | acc])
    after
      150 -> Enum.reverse(acc)
    end
  end

  defp normalize(%{query: q}) when is_binary(q), do: String.replace(q, ~r/\s+/, " ")
  defp normalize(_), do: ""
end
