-module(yard_obs_session_ffi).

-export([iso_timestamp/0]).

iso_timestamp() ->
    {{Year, Month, Day}, {Hour, Min, Sec}} = calendar:system_time_to_local_time(
        erlang:system_time(second), second
    ),
    Milli = erlang:system_time(millisecond) rem 1000,
    unicode:characters_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0B",
        [Year, Month, Day, Hour, Min, Sec, Milli])).
