defmodule FumehoodWeb.ChannelCase do
  @moduledoc "Tests for channels (Phoenix.ChannelTest) with the database sandbox."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint FumehoodWeb.Endpoint
    end
  end

  setup tags do
    Fumehood.DataCase.setup_sandbox(tags)
    :ok
  end
end
