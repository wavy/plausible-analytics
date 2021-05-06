defmodule PlausibleWeb.Api.Helpers do
  import Plug.Conn

  def unauthorized(conn, msg) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{error: msg})
    |> halt()
  end

  def bad_request(conn, msg) do
    conn
    |> put_status(400)
    |> Phoenix.Controller.json(%{error: msg})
    |> halt()
  end

  def not_found(conn, msg) do
    conn
    |> put_status(404)
    |> Phoenix.Controller.json(%{error: msg})
    |> halt()
  end
end
