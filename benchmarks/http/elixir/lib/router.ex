defmodule FenrirHttp.Router do
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    valid =
      conn.method == "GET" and match?([host] when host != "", get_req_header(conn, "host")) and
        get_req_header(conn, "content-length") == [] and
        get_req_header(conn, "transfer-encoding") == []

    if valid do
      {status, type, body} = route(conn.request_path, conn.query_string)
      conn |> put_resp_header("content-type", type) |> send_resp(status, body)
    else
      conn
      |> put_resp_header("connection", "close")
      |> put_resp_header("content-type", "text/plain")
      |> send_resp(400, "")
    end
  end

  defp route("/", ""), do: {200, "text/plain", "fenrir\n"}
  defp route("/status", ""), do: {200, "application/json", ~s({"ok":true}\n)}

  defp route("/items/" <> digits, "") do
    if digits != "" and decimal?(digits), do: {200, "text/plain", digits}, else: missing()
  end

  defp route(_, _), do: missing()
  defp missing, do: {404, "text/plain", ""}

  defp decimal?(<<digit, rest::binary>>) when digit in ?0..?9, do: decimal?(rest)
  defp decimal?(<<>>), do: true
  defp decimal?(_), do: false
end
