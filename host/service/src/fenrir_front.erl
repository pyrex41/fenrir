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
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Workers, Bindings) -> gen_server:start_link({local, ?MODULE}, ?MODULE, {Workers, Bindings}, []).

submit(Credential, K, D, Payload) ->
    case gen_server:call(?MODULE, {pick_submit, Credential}) of
        {ok, Worker, Scope} -> request(Worker, Scope, {submit, K, D, Payload});
        denied -> {{refused, unauthorized}, #{}}
    end.

%% Internal host API, not part of authenticated submit ingress.
deliver(T, J, Ok) ->
    request(gen_server:call(?MODULE, pick_delivery), {tenant, T}, {complete, J, Ok}).

%% Privileged campaign observations, not a client API.
respond(Event) -> gen_server:call(?MODULE, {respond, Event}).
outbox() -> gen_server:call(?MODULE, outbox).

request(Worker, Scope, Req) ->
    Outcome = try fenrir_worker:run(Worker, Scope, Req) of
                  {ok, V, St} -> {response(V, Scope), St};
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

response({data, <<"Response">>, <<"Accepted">>,
          [{data, <<"Receipt">>, <<"Receipt">>, [{int, T}, {int, K}, {int, D}, {int, R}, {int, J}]}]},
         {tenant, T}) -> {accepted, [T, K, D, R, J]};
response({data, <<"Response">>, <<"Conflict">>, [{int, T}, {int, K}]}, {tenant, T}) -> {conflict, T, K};
response({data, <<"Response">>, <<"Delivered">>, []}, _) -> delivered;
response({data, <<"Response">>, <<"Refused">>, []} = V, _) -> {response, V};
%% Do not expose an unexpected guest value or publish it to the outbox. A
%% commit may already have happened, so do not tell the caller it rolled back.
response(_, _) -> indeterminate.

init({Workers, Bindings}) -> {ok, #{workers => Workers, next => 0, outbox => [], bindings => Bindings}}.

handle_call({pick_submit, Credential}, _From, S = #{bindings := Bindings}) ->
    case fenrir_authority:authenticate(Credential, Bindings) of
        {ok, Scope} ->
            {Worker, S1} = pick(S),
            {reply, {ok, Worker, Scope}, S1};
        denied -> {reply, denied, S}
    end;
handle_call(pick_delivery, _From, S) ->
    {Worker, S1} = pick(S),
    {reply, Worker, S1};
handle_call({add, E}, _From, S = #{outbox := O}) ->
    {reply, ok, S#{outbox := lists:usort([E | O])}};
handle_call({respond, E}, _From, S = #{outbox := O}) ->
    {reply, case lists:member(E, O) of true -> ok; false -> not_in_outbox end, S};
handle_call(outbox, _From, S = #{outbox := O}) -> {reply, O, S}.

pick(S = #{workers := Ws, next := N}) ->
    {lists:nth(N rem length(Ws) + 1, Ws), S#{next := N + 1}}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
