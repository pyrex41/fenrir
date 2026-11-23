%% A3: the service's front API, in the shape of the A1 labels
%% (spec/service/ACCEPTED_JOB.md section 2):
%%   submit(Credential, K, D, Payload)  authenticates and runs the handler in the
%%                             bound tenant's scope; an Accepted or Conflict
%%                             response is put in the (volatile) outbox and returned
%%   deliver(T, J, Ok)         a trusted host runner delivery of job J's result
%%   respond(Event)            a computed response reaches the client: enabled only
%%                             when Event is in the outbox; the outbox keeps it
%% The outbox lives in this process and is lost with the node (A1: a crash empties the
%% outbox). Requests run in the CALLER's process on a worker chosen round-robin, so two
%% callers use two workers at once; only the outbox update goes through this server.
%%
%% Outcomes of submit/complete as the client sees them:
%%   {accepted, [T,K,D,R,J]} | {conflict, T, K} | delivered | {response, Other}
%%   busy            the store was busy; nothing applied; retry
%%   aborted         definitely not applied; retry
%%   indeterminate   a commit may have happened and no response exists; retry with the
%%                   same key returns the recorded receipt (never reported as rollback)
%%   {refused, Why}  the request is outside the image's domain; nothing ran
-module(fenrir_front).
-behaviour(gen_server).
-export([start_link/2, submit/4, deliver/3, respond/1, outbox/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(Workers, Bindings) -> gen_server:start_link({local, ?MODULE}, ?MODULE, {Workers, Bindings}, []).

submit(Credential, K, D, Payload) ->
    case gen_server:call(?MODULE, {pick_submit, Credential}) of
        {ok, Worker, Scope} -> request(Worker, Scope, {submit, K, D, Payload});
        unavailable -> {unavailable, #{}};
        denied -> {{refused, unauthorized}, #{}}
    end.

%% Internal host API, not part of authenticated submit ingress.
deliver(T, J, Ok) ->
    case gen_server:call(?MODULE, pick_delivery) of
        unavailable -> {unavailable, #{}};
        Worker -> request(Worker, {tenant, T}, {complete, J, Ok})
    end.

%% Privileged campaign observations, not a client API.
respond(Event) -> gen_server:call(?MODULE, {respond, Event}).
outbox() -> gen_server:call(?MODULE, outbox).

request(Worker, Scope, Req) ->
    Outcome = try fenrir_worker:run(Worker, Scope, Req) of
                  {ok, V, St} -> {response_for_worker(V, Scope, Req, St), St};
                  {refused, version_not_in_force} -> {unavailable, #{}};
                  {aborted, version_not_in_force, St} -> {unavailable, St};
                  {refused, Why} -> {{refused, Why}, #{}};
                  {failed, Why, St} -> {aborted, St#{why => Why}};
                  {O, Why, St} -> {O, St#{why => Why}}
              catch
                  %% The request never reached a worker (one is being restarted): nothing ran.
                  exit:{noproc, _} -> {aborted, #{worker_exit => noproc}};
                  exit:Why -> {indeterminate, #{worker_exit => element(1, Why)}}
              end,
    {Out, Stats} = Outcome,
    case Out of
        {accepted, _} -> gen_server:call(?MODULE, {add, Out});
        {conflict, _, _} -> gen_server:call(?MODULE, {add, Out});
        _ -> ok
    end,
    {Out, Stats#{worker => Worker}}.

response_for_worker({data, <<"Response">>, <<"Accepted">>,
        [{data, <<"Receipt">>, <<"Receipt2">>, [{int, T}, {int, K}, {int, D}, {int, R}, {int, J}]}]},
        {tenant, T}, {submit, K, D, _}, #{contract_version := 2}) ->
    {accepted, [T, K, D, R, J, 2]};
response_for_worker(V, Scope, Req, _) -> response(V, Scope, Req).

response({data, <<"Response">>, <<"Accepted">>,
          [{data, <<"Receipt">>, <<"Receipt">>, [{int, T}, {int, K}, {int, D}, {int, R}, {int, J}]}]},
         {tenant, T}, {submit, K, D, _}) -> {accepted, [T, K, D, R, J]};
response({data, <<"Response">>, <<"Conflict">>, [{int, T}, {int, K}]},
         {tenant, T}, {submit, K, _, _}) -> {conflict, T, K};
response({data, <<"Response">>, <<"Delivered">>, []}, _, {complete, _, _}) -> delivered;
response({data, <<"Response">>, <<"Refused">>, []} = V, _, {submit, _, _, _}) -> {response, V};
%% Do not expose an unexpected guest value or publish it to the outbox. A
%% commit may already have happened, so do not tell the caller it rolled back.
response(_, _, _) -> indeterminate.

init({Workers, Bindings}) -> {ok, #{workers => Workers, next => 0, outbox => #{}, bindings => Bindings}}.

handle_call({pick_submit, Credential}, _From, S = #{bindings := Bindings}) ->
    case fenrir_authority:authenticate(Credential, Bindings) of
        {ok, Scope} ->
            {Worker, S1} = pick(S),
            {reply, case Worker of unavailable -> unavailable; _ -> {ok, Worker, Scope} end, S1};
        denied -> {reply, denied, S}
    end;
handle_call(pick_delivery, _From, S) ->
    {Worker, S1} = pick(S),
    {reply, Worker, S1};
handle_call({add, E}, _From, S = #{outbox := O}) ->
    {reply, ok, S#{outbox := O#{E => true}}};
handle_call({respond, E}, _From, S = #{outbox := O}) ->
    {reply, case maps:is_key(E, O) of true -> ok; false -> not_in_outbox end, S};
handle_call(outbox, _From, S = #{outbox := O}) -> {reply, lists:sort(maps:keys(O)), S}.

pick(S = #{workers := #{v1 := V1, v2 := V2}, next := N}) ->
    Ws = case fenrir_store:routing_phase() of
        {ok, v1} -> V1;
        {ok, {prepared, _}} -> V1;
        {ok, {v2, _}} -> V2;
        _ -> []
    end,
    %% Use the exact instance, not a registered name that could be rebound
    %% after the choice. No fallback to the other contract or bank.
    Live = [P || W <- Ws, P <- [whereis(W)], is_pid(P)],
    case Live of
        [] -> {unavailable, S};
        _ -> {lists:nth(N rem length(Live) + 1, Live), S#{next := N + 1}}
    end;
pick(S = #{workers := Ws, next := N}) ->
    {lists:nth(N rem length(Ws) + 1, Ws), S#{next := N + 1}}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.

code_change(_, S = #{outbox := Events}, _) when is_list(Events) ->
    {ok, S#{outbox := maps:from_keys(Events, true)}};
code_change(_, S, _) -> {ok, S}.
