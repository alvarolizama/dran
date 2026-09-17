defmodule DranWeb.NotFoundError do
  @moduledoc """
  Raised when a request matches a route but resolves to no resource — a URL
  path segment the registry no longer knows, for example. Carries
  `plug_status: 404`, so the endpoint renders the not-found page instead of a
  generic 500.
  """

  defexception message: "Not Found", plug_status: 404
end
