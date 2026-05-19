defmodule SymphonyElixirWeb.LegacyRedirectController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  @spec codex_dashboard(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def codex_dashboard(conn, _params) do
    redirect(conn, to: "/cursor")
  end
end
