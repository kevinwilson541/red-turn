
-module(redturn_tests).

-include_lib("eunit/include/eunit.hrl").
-include("redturn.hrl").

-define(RESOURCE, <<"REDTURN_TEST_RESOURCE">>).

%%====================================================================
%% Test functions
%%====================================================================

connect_test() ->
    Pid = create_conn(),
    redturn:stop(Pid).

wait_test() ->
    Pid = create_conn(),
    Conn = create_redis_conn(),

    Res = redturn:wait(Pid, ?RESOURCE, 5000),
    ?assertMatch({ok, _}, Res),
    {ok, Id} = Res,

    ?assert(is_binary(Id)),

    check_resource(Conn, ?RESOURCE, [Id]),

    clear_resource(Conn, ?RESOURCE).

wait_async_test() ->
    Pid = create_conn(),
    Conn = create_redis_conn(),

    Ref = redturn:wait_async(Pid, ?RESOURCE, 5000),
    ?assert(is_reference(Ref)),
    
    Id = get_msg(Ref),

    check_resource(Conn, ?RESOURCE, [Id]),
    
    clear_resource(Conn, ?RESOURCE).

wait_signal_test() ->
    Pid = create_conn(),
    Conn = create_redis_conn(),

    Res = redturn:wait(Pid, ?RESOURCE, 5000),
    ?assertMatch({ok, _}, Res),
    {ok, Id} = Res,

    ok = redturn:signal(Pid, ?RESOURCE, Id),

    check_resource(Conn, ?RESOURCE, []).

wait_serialized_test() ->
    Pid = create_conn(),
    Conn = create_redis_conn(),

    Ref1 = redturn:wait_async(Pid, ?RESOURCE, 5000),
    Ref2 = redturn:wait_async(Pid, ?RESOURCE, 5000),
    ?assert(is_reference(Ref1)),
    ?assert(is_reference(Ref2)),
    
    Id1 = get_msg(Ref1),
    check_resource_len(Conn, ?RESOURCE, 2),

    ok = redturn:signal_noreply(Pid, ?RESOURCE, Id1),

    Id2 = get_msg(Ref2),

    check_resource(Conn, ?RESOURCE, [Id2]),

    clear_resource(Conn, ?RESOURCE).


%%====================================================================
%% Internal functions
%%====================================================================

create_conn() ->
    Res = redturn:start_link(),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    Pid.

create_redis_conn() ->
    Res = eredis:start_link(),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    Pid.

clear_resource(C, Resource) ->
    ?assertMatch({ok, _}, eredis:q(C, [<<"DEL">>, Resource])).

check_resource(C, Resource, Ids) ->
    Res = eredis:q(C, [<<"LRANGE">>, Resource, 0, -1]),
    ?assertMatch({ok, _}, Res),
    {ok, L} = Res,

    NL = [hd(binary:split(El, <<":">>, [global])) || El <- L],
    ?assertEqual(NL, Ids).

check_resource_len(C, Resource, Len) ->
    Res = eredis:q(C, [<<"LLEN">>, Resource]),
    ?assertMatch({ok, _}, Res),
    {ok, L} = Res,

    ?assertEqual(binary_to_integer(L), Len).

get_msg(Ref) ->
    receive
        {Ref, Msg} ->
            ?assertMatch({ok, _}, Msg),
            {ok, Id} = Msg,
            ?assert(is_binary(Id)),
            Id
    end.