defmodule PlausibleWeb.CloudflareGeo do
  def get(conn) do
    List.first(Plug.Conn.get_req_header(conn, "cf-ipcountry"))
  end
end
