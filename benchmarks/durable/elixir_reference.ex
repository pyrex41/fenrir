defmodule Fenrir.DurableReference do
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:run, {:tenant, t} = scope, command}, _, state) when t in 0..1,
    do: {:reply, execute(scope, t, command), state}

  def handle_call(_, _, state), do: {:reply, {:refused, :outside_domain}, state}

  defp execute(scope, t, {:submit, k, d, payload})
       when k in 0..9_223_372_036_854_775_807 and d in 0..1 and payload == <<d>> do
    writes = [
      write("StageJob", []),
      write("PutReport", [int(d), {:bytes, payload}]),
      write("RecordKey", [int(k), int(d)])
    ]

    case commit(scope, t, "Once", k, writes) do
      {:reply, {:data, "Reply", "Committed", [receipt]}} ->
        response("Accepted", [receipt])

      {:reply, {:data, "Reply", "Recorded", [{:int, ^d}, receipt]}} ->
        response("Accepted", [receipt])

      {:reply, {:data, "Reply", "Recorded", _}} ->
        response("Conflict", [int(t), int(k)])

      {:reply, _} ->
        response("Refused", [])

      other ->
        failure(other)
    end
  end

  defp execute(scope, t, {:complete, j, ok}) when j in 0..9_223_372_036_854_775_807 and is_boolean(ok) do
    case commit(scope, t, "Pending", j, [write("Finish", [int(j), {:bool, ok}])]) do
      {:reply, _} -> response("Delivered", [])
      other -> failure(other)
    end
  end

  defp execute(_, _, _), do: {:refused, :outside_domain}
  defp int(n), do: {:int, n}
  defp write(name, args), do: {:data, "Write", name, args}

  defp commit(scope, tenant, guard, key, writes) do
    ops =
      List.foldr(writes, {:data, "Writes", "Done", []}, fn op, rest ->
        {:data, "Writes", "Then", [op, rest]}
      end)

    tx =
      {:data, "Tx", "Tx",
       [
         {:data, "Cap", "Tenant", [int(tenant)]},
         {:data, "Guard", guard, [int(key)]},
         ops
       ]}

    case :fenrir_store.commit(scope, tx) do
      {:reply, {:data, "Reply", "Unauthorized", []}} -> {:aborted, :unauthorized_scope}
      result -> result
    end
  end

  defp response(name, fields), do: {:ok, {:data, "Response", name, fields}, %{requests: 1}}
  defp failure(:busy), do: {:busy, :store_busy, %{requests: 1}}

  defp failure({status, why}) when status in [:aborted, :indeterminate],
    do: {status, why, %{requests: 1}}
end
