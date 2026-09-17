defmodule DranWeb.Plugs.ClientIp do
  @moduledoc """
  Rewrites `conn.remote_ip` from the `x-forwarded-for` header.

  Production runs behind a TLS-terminating reverse proxy (`force_ssl` with
  `rewrite_on: [:x_forwarded_proto]`), so the socket peer is the PROXY: without
  this plug `conn.remote_ip` is the same address for every request, and any
  IP-keyed control (the login throttle) would share one counter across all
  clients — useless against a single attacker and able to lock everyone out.

  ## Trust assumption — read before relying on this

  `x-forwarded-for` is a client-settable header. This plug trusts it
  UNCONDITIONALLY, which is only sound while the app is **not directly
  reachable** and the proxy in front SETS (or appends) the header on every
  request, discarding whatever the client sent. If the proxy forwards
  client-supplied values untouched, an attacker can forge the header and
  defeat any IP-keyed control.

  The rightmost entry is used: it is the one appended by the proxy closest to
  us, i.e. the peer that proxy actually saw.

  An unparsable or absent header leaves `remote_ip` untouched (the peer
  address), so behaviour degrades to the previous one rather than to nil.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case client_ip(conn) do
      nil -> conn
      ip -> %{conn | remote_ip: ip}
    end
  end

  defp client_ip(conn) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> parse()
  end

  defp parse(nil), do: nil

  defp parse(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end
end
