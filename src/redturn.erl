%%%-------------------------------------------------------------------
%% @doc redturn server.
%% @end
%%%-------------------------------------------------------------------

-module(redturn).

-behaviour(gen_server).

%% API
-export([start_link/1,
         stop/1,
         wait/3,
         wait_async/3,
         wait_async/4,
         signal/3]).

%% gen_server callbacks
-export([init/1,
         terminate/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3]).

-include("redturn.hrl").



%%====================================================================
%% API functions
%%====================================================================

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

stop(Pid) ->
    gen_server:stop(Pid).

wait(Pid, Resource, Timeout) ->
    gen_server:call(Pid, {wait, Resource, Timeout}).

wait_async(Pid, Resource, Timeout) ->
    wait_async(Pid, Resource, Timeout, erlang:self()).

wait_async(Pid, Resource, Timeout, To) ->
    Ref = erlang:make_ref(),
    gen_server:cast(Pid, {wait, Resource, Timeout, Ref, To}),
    Ref.

signal(Pid, Resource, Id) ->
    gen_server:cast(Pid, {signal, Resource, Id}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(#redturn_opts{module=Mod, conn_opts=COpts, subconn_opts=SOpts}) ->
    {ok, Conn} = Mod:start_conn(COpts),
    {ok, SubConn} = Mod:start_sub(SOpts),

    Mod:controlling_process(SubConn),

    Id = to_hex(crypto:strong_rand_bytes(?ID_LEN)),

    State = #redturn_state{ id=Id,
                            module=Mod,
                            conn=Conn,
                            sub_conn=SubConn,
                            queue=queue:new(),
                            waiting=maps:new(),
                            head_track=maps:new(),
                            req_queue=maps:new() },
    
    subscribe_to_channel(State),
    
    State1 = load_scripts(State),

    State2 = reset_msg_gen(State1),

    {ok, State2}.

terminate(_Reason, _State) ->
    ok.

handle_call({wait, Resource, Timeout}, {From, Ref}, State) ->
    NState = add_wait(Resource, Timeout, From, Ref, State),
    {noreply, NState};
handle_call(_Req, _From, State) ->
    {noreply, State}.

handle_cast({wait, Resource, Timeout, Ref, From}, State) ->
    NState = add_wait(Resource, Timeout, From, Ref, State),
    {noreply, NState};
handle_cast({signal, Resource, Id}, State) ->
    NState = signal_done(Resource, Id, State),
    {noreply, NState};
handle_cast(_Req, State) ->
    {noreply, State}.

handle_info(reset_msg_gen, State) ->
    NState = reset_msg_gen(State),
    {noreply, NState};
handle_info({message, Channel, Msg, SConn}, State=#redturn_state{id=Channel, module=Mod, sub_conn=SConn}) ->
    Mod:ack_message(SConn),
    case binary:split(Msg, <<":">>, [global]) of
        [Resource, Id] ->
            NState = notify_wait(Resource, Id, State),
            {noreply, NState};
        _ ->
            {noreply, State}
    end;
handle_info({response, Reply}, State) ->
    NState = handle_redis_reply(Reply, State),
    {noreply, NState};
handle_info({clear_head, Resource, Id}, State=#redturn_state{head_track=Track}) ->
    case maps:get(Resource, Track, undefined) of
        {Id, _Ref} ->
            NState = signal_done(Resource, Id, State),
            NTrack = maps:remove(Resource, Track),
            {noreply, NState#redturn_state{head_track=NTrack}};
        _ ->
            {noreply, State}
    end;
handle_info({subscribed, Id, SConn}, State=#redturn_state{id=Id, module=Mod, sub_conn=SConn}) ->
    Mod:ack_message(SConn),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

to_hex(Bin) ->
    << <<(hex(A)), (hex(B))>> || <<A:4, B:4>> <= Bin>>.

hex(A) when A < 10 ->
    $0 + A;
hex(A) ->
    A + $a - 10.

subscribe_to_channel(#redturn_state{module=Mod, sub_conn=SConn, id=Id}) ->
    Mod:subscribe(SConn, [Id]).

add_script() ->
    <<"
        local list = KEYS[1]
        local channel = ARGV[1]
        local value = ARGV[2]
        local id = ARGV[3]

        if redis.call(\"RPUSH\", list, value) == 1 then
            redis.call(\"PUBLISH\", channel, list .. \":\" .. id)
        end

        return redis.call(\"LINDEX\", list, 0)
    ">>.

remove_script() ->
    <<"
        local list = KEYS[1]
        local id = ARGV[1]

        local value = redis.call(\"LINDEX\", list, 0)
        local val_split = {}
        for w in (value .. \":\"):gmatch(\"([^:]*):\") do
            table.insert(val_split, w)
        end

        local val_id = val_split[1]
        local called = false
        if val_id == id then
            redis.call(\"LPOP\", list)
            called = true
        end

        local next = redis.call(\"LINDEX\", list, 0)
        if next ~= false and called == true then
            local next_split = {}
            for w in (next .. \":\"):gmatch(\"([^:]*):\") do
                table.insert(next_split, w)
            end
            local next_split = string.gmatch(next .. \":\", \"([^:]*):\")
            local next_id = next_split[1]
            local next_channel = next_split[2]
            redis.call(\"PUBLISH\", next_channel, list .. \":\" .. next_id)
        end

        return next
    ">>.

load_scripts(State=#redturn_state{module=Mod, conn=C}) ->
    AddScript = add_script(),
    RemoveScript = remove_script(),
    [{ok, AddSha}, {ok, RemoveSha}] = Mod:qp(C, [[<<"SCRIPT">>, <<"LOAD">>, AddScript], [<<"SCRIPT">>, <<"LOAD">>, RemoveScript]]),
    State#redturn_state{scripts={AddSha, RemoveSha}}.

gen_msg_id(State=#redturn_state{base=Base, inc=Inc}) ->
    Id = <<Base/binary, ".", (integer_to_binary(Inc))/binary>>,
    {Id, State#redturn_state{inc=Inc+1}}.

add_to_req_queue(Ctx=#redturn_ctx{resource=Resource, id=Id}, State=#redturn_state{req_queue=RQ, queue=Q, waiting=W}) ->
    InnerQ = maps:get(Resource, RQ, queue:new()),
    NRQ = maps:put(Resource, queue:in(Id, InnerQ), RQ),
    NQ = queue:in(Ctx, Q),
    NW = maps:put(Id, Ctx, W),
    State#redturn_state{req_queue=NRQ, queue=NQ, waiting=NW}.

%% remove items from queue under resource until we reach Id, responding to waiting contexts with error
remove_from_req_queue(Ctx=#redturn_ctx{resource=Resource, id=Id}, State=#redturn_state{req_queue=RQ, waiting=W}) ->
    Q = maps:get(Resource, RQ, queue:new()),
    case queue:peek(Q) of
        {value, Id} ->
            NW = maps:remove(Id, W),
            safe_reply({ok, Id}, Ctx),
            {_, NQ} = queue:out(Q),
            case queue:len(NQ) of
                0 ->
                    NRQ1 = maps:remove(Resource, RQ),
                    State#redturn_state{req_queue=NRQ1, waiting=NW};
                _ ->
                    NRQ2 = maps:put(Resource, NQ, RQ),
                    State#redturn_state{req_queue=NRQ2, waiting=NW}
            end;
        {value, Other} ->
            Ctx = maps:get(Other, W, #redturn_ctx{}),
            safe_reply({error, missed_ctx}, Ctx),
            {_, NQ} = queue:out(Q),
            NW = maps:remove(Other, W),
            remove_from_req_queue(Ctx, State#redturn_state{req_queue=NQ, waiting=NW});
        empty ->
            State#redturn_state{req_queue=maps:remove(Resource, RQ)}
    end.

add_wait(Resource, Timeout, From, Ref, State=#redturn_state{id=Channel, conn=C, module=Mod, scripts={AddSha, _}}) ->
    {Id, State1} = gen_msg_id(State),
    Val = <<Id/binary, ":", Channel/binary, ":", (integer_to_binary(Timeout))/binary>>,
    ok = Mod:q_async(C, [<<"EVALSHA">>, AddSha, 1, Resource, Channel, Val, Id]),
    Ctx = #redturn_ctx{from=From, ref=Ref, resource=Resource, id=Id, timeout=Timeout},
    add_to_req_queue(Ctx, State1).

signal_done(Resource, Id, State=#redturn_state{conn=C, module=Mod, scripts={_, RemoveSha}, queue=Q}) ->
    ok = Mod:q_async(C, [<<"EVALSHA">>, RemoveSha, 1, Resource, Id]),
    NQ = queue:in(#redturn_ctx{resource=Resource}, Q),
    State#redturn_state{queue=NQ}.

reset_msg_gen(State) ->
    Base = to_hex(crypto:strong_rand_bytes(?ID_LEN)),
    Inc = 0,
    erlang:start_timer(?RESET_INTERVAL, erlang:self(), reset_msg_gen),
    State#redturn_state{base=Base, inc=Inc}.

notify_wait(Resource, Id, State=#redturn_state{waiting=W}) ->
    case maps:get(Id, W, undefined) of
        undefined ->
            signal_done(Resource, Id, State);
        Ctx=#redturn_ctx{id=Id, resource=Resource, timeout=Timeout} ->
            NState = remove_from_req_queue(Ctx, State),
            replace_head_track(Resource, Id, Timeout, NState)
    end.

handle_redis_reply({error, _}, State=#redturn_state{queue=Q}) ->
    {_, NQ} = queue:out(Q),
    State#redturn_state{queue=NQ};
handle_redis_reply({ok, undefined}, State=#redturn_state{queue=Q}) ->
    {_, NQ} = queue:out(Q),
    State#redturn_state{queue=NQ};
handle_redis_reply({ok, Val}, State=#redturn_state{queue=Q}) ->
    case binary:split(Val, <<":">>, [global]) of
        [Id, _Channel, TimeoutStr] ->
            Timeout = binary_to_integer(TimeoutStr),
            case queue:out(Q) of
                {{value, #redturn_ctx{resource=Resource}}, NQ} ->
                    replace_head_track(Resource, Id, Timeout, State#redturn_state{queue=NQ});
                {empty, Q} ->
                    State
            end;
        _ ->
            {_, NQ} = queue:out(Q),
            State#redturn_state{queue=NQ}
    end.

replace_head_track(Resource, Id, Timeout, State=#redturn_state{head_track=Track}) ->
    case maps:get(Resource, Track, undefined) of
        {HeadId, Ref} when HeadId =/= Id ->
            erlang:cancel_timer(Ref, []),
            NRef = erlang:send_after(Timeout, self(), {clear_head, Resource, Id}),
            NTrack = maps:put(Resource, {Id, NRef}, Track),
            State#redturn_state{head_track=NTrack};
        {Id, _Ref} ->
            State;
        _ ->
            NRef = erlang:send_after(Timeout, self(), {clear_head, Resource, Id}),
            NTrack = maps:put(Resource, {Id, NRef}, Track),
            State#redturn_state{head_track=NTrack}
    end.

safe_reply(Res, #redturn_ctx{from=Pid, ref=Ref}) when is_pid(Pid), is_reference(Ref) ->
    try
        gen_server:reply({Pid, Ref}, Res),
        ok
    catch _:_ ->
        ok
    end;
safe_reply(_, _) ->
    ok.