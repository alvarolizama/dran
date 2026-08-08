defmodule DranWeb.ControllerHelpers do
  @moduledoc """
  Shared helpers for API controllers.

  Imported automatically by every controller via `use DranWeb, :controller`.
  """

  @doc """
  Format an `Ecto.Changeset`'s errors as a plain map of strings, interpolating
  `%{key}` placeholders with their values — the JSON shape the API returns in
  `%{errors: ...}` responses.
  """
  @spec format_errors(Ecto.Changeset.t()) :: map()
  def format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
  end
end
