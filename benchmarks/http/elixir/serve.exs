[port] = System.argv()

{:ok, server} =
  Bandit.start_link(
    plug: FenrirHttp.Router,
    ip: {127, 0, 0, 1},
    port: String.to_integer(port),
    startup_log: false,
    http_1_options: [
      max_request_line_length: 8192,
      max_header_length: 8192,
      max_header_count: 2048
    ],
    http_2_options: [enabled: false],
    thousand_island_options: [num_acceptors: 1, num_connections: 64, read_timeout: 5000]
  )

{:ok, {_address, bound}} = ThousandIsland.listener_info(server)
IO.puts(:stderr, "127.0.0.1:#{bound}")
Process.sleep(:infinity)
