defmodule DranWeb.ErrorJSONTest do
  # No DB access — ConnCase's sandbox checkout is unnecessary and raced
  # with sync tests running in shared mode.
  use ExUnit.Case, async: true

  test "renders 404" do
    assert DranWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert DranWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
