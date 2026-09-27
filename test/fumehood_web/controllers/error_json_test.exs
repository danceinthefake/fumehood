defmodule FumehoodWeb.ErrorJSONTest do
  use FumehoodWeb.ConnCase, async: true

  test "renders 404" do
    assert FumehoodWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert FumehoodWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
