%% A3: the service's front API, in the shape of the A1 labels
%% (spec/service/ACCEPTED_JOB.md section 2):
%%   submit(T, K, D, Payload)  runs the handler on a worker; an Accepted or Conflict
%%                             response is put in the (volatile) outbox and returned
%%   complete(T, J, Ok)        a worker delivery of job J's result
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
%%   unavailable     A4: no version is in force (between migrate and cut-over) or the
%%                   run's commit was fenced (its version is no longer in force);
%%                   nothing applied; retry
-module(fenrir_front).
-behaviour(gen_server).
-export([start_link/1, submit/4, complete/3, respond/1, outbox/0, request_on/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Workers) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Workers, []).

submit(T, K, D, Payload) -> request({submit, T, K, D, Payload}).
complete(T, J, Ok) -> request({complete, T, J, Ok}).
respond(Event) -> gen_server:call(?MODULE, {respond, Event}).
outbox() -> gen_server:call(?MODULE, outbox).

request(Req) -> request_on(gen_server:call(?MODULE, pick), Req).

%% A4: a request on a given worker (the campaigns' detached stale worker).
request_on(Worker, Req) ->
    Outcome = try fenrir_worker:run(Worker, Req) of
                  {ok, V, St} -> {response(V), St};
                  %% A4 (UPGRADE.md sections 3, 4.3): no version in force (migrated), or
                  %% the commit's version is not in force (a stale run): nothing applied.
                  {refused, no_version_in_force} -> {unavailable, #{why => no_version_in_force}};
                  {stale, Why, St} -> {unavailable, St#{why => {stale, Why}}};
                  {failed, version_in_force_changed, St} -> {unavailable, St#{why => version_in_force_changed}};
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

response({data, <<"Response">>, <<"Accepted">>, [{data, <<"Receipt">>, <<"Receipt">>, Fs}]}) ->
    {accepted, [N || {int, N} <- Fs]};
%% A4: a receipt made under contract 2 carries its version (UPGRADE.md section 2.1).
response({data, <<"Response">>, <<"Accepted">>, [{data, <<"Receipt">>, <<"Receipt2">>, Fs}]}) ->
    {accepted, [N || {int, N} <- Fs] ++ [2]};
response({data, <<"Response">>, <<"Conflict">>, [{int, T}, {int, K}]}) -> {conflict, T, K};
response({data, <<"Response">>, <<"Delivered">>, []}) -> delivered;
response(V) -> {response, V}.

init(Workers) -> {ok, #{workers => Workers, next => 0, outbox => []}}.

handle_call(pick, _From, S = #{workers := Ws, next := N}) ->
    {reply, lists:nth(N rem length(Ws) + 1, Ws), S#{next := N + 1}};
handle_call({add, E}, _From, S = #{outbox := O}) ->
    {reply, ok, S#{outbox := lists:usort([E | O])}};
handle_call({respond, E}, _From, S = #{outbox := O}) ->
    {reply, case lists:member(E, O) of true -> ok; false -> not_in_outbox end, S};
handle_call(outbox, _From, S = #{outbox := O}) -> {reply, O, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
