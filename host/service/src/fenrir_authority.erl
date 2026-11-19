%% Bounded A3 ingress: an operator provisions SHA-256 fingerprints of random
%% 32-byte bearer credentials, each bound to one configured tenant.
-module(fenrir_authority).
-export([validate/1, authenticate/2, campaign_credentials/1]).

validate(#{tenants := N} = Config) when is_integer(N), N > 0, N =< 64 ->
    Bindings = maps:get(submit_credentials, Config, #{}),
    case is_map(Bindings) andalso maps:fold(
        fun(Fingerprint, T, Valid) ->
                Valid andalso is_binary(Fingerprint) andalso byte_size(Fingerprint) =:= 32
                    andalso is_integer(T) andalso T >= 0 andalso T < N
        end, true, Bindings) of
        true -> {ok, Bindings};
        false -> {error, invalid_submit_credentials}
    end;
validate(_) -> {error, invalid_tenant_domain}.

authenticate(Credential, Bindings) when is_binary(Credential), byte_size(Credential) =:= 32 ->
    case maps:find(fingerprint(Credential), Bindings) of
        {ok, T} -> {ok, {tenant, T}};
        error -> denied
    end;
authenticate(_, _) -> denied.

%% The privileged campaign controller impersonates its fixture principals. No
%% fixture credential is sent over the controller or guest pipes or written to disk.
campaign_credentials(N) ->
    Tokens = maps:from_list([{T, crypto:strong_rand_bytes(32)} || T <- lists:seq(0, N - 1)]),
    {Tokens, maps:from_list([{fingerprint(Token), T} || {T, Token} <- maps:to_list(Tokens)])}.

fingerprint(Token) -> crypto:hash(sha256, Token).
