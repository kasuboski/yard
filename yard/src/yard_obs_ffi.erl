-module(yard_obs_ffi).

%% FFI for yard observability:
%% - execute/3: telemetry.execute with string-keyed dicts
%% - system_time/0: millisecond monotonic time
%% - sha256_first8/1: first 8 hex chars of SHA-256

-export([
    execute/3,
    system_time/0,
    sha256_first8/1
]).

%% Execute a telemetry event.
%% Converts string-keyed dicts to atom-keyed maps for :telemetry.
execute(NameStrs, Measurements, Metadata) ->
    NameAtoms = [binary_to_atom(S, utf8) || S <- NameStrs],
    telemetry:execute(NameAtoms, atomize_keys(Measurements), atomize_keys(Metadata)),
    nil.

%% Erlang monotonic time in milliseconds.
system_time() ->
    erlang:system_time(millisecond).

%% SHA-256 of input, first 8 hex characters.
sha256_first8(Input) ->
    Hash = crypto:hash(sha256, Input),
    <<First4:4/binary, _/binary>> = Hash,
    binary:encode_hex(First4).

%% Internal: convert string-keyed map to atom-keyed map.
atomize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        AtomKey = if is_binary(K) -> binary_to_atom(K, utf8); true -> K end,
        Acc#{AtomKey => V}
    end, #{}, Map).
