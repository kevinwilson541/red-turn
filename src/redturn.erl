%%%-------------------------------------------------------------------
%% @doc redturn server.
%% @end
%%%-------------------------------------------------------------------

-module(redturn).

-behaviour(gen_server).

%% API
-ifdef(TEST).
-compile(export_all).
-endif.

-export([start_link/0,
         start_link/1,
         stop/1,
         wait/3,
         wait/4,
         wait_async/3,
         wait_async/4,
         signal/3,
         signal/4,
         signal_noreply/3]).


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

start_link() ->
    start_link(#redturn_opts{conn_opts=#redturn_conn_opts{}, subconn_opts=#redturn_sub_opts{}}).

-spec start_link(Opts :: redturn_opts()) -> {ok, pid()} | {error, term()}.
%% @doc Starts an instance of redturn, linking the calling process with the created server returned.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec stop(Pid :: pid()) -> ok.
%% @doc Stops redturn server `Pid'.
stop(Pid) ->
    gen_server:stop(Pid).

-spec wait(Pid :: pid(), Resource :: binary(), Timeout :: non_neg_integer()) -> {ok, binary()} | {error, term()}.
% @doc Calls redturn server `Pid' to acquire a lock on resource `Resource', holding the lock for `Timeout' milliseconds once the lock is acquired. Returns
% the ID associated with the holder of the lock.
wait(Pid, Resource, Timeout) ->
    gen_server:call(Pid, {wait, Resource, Timeout}).

-spec wait(Pid :: pid(), Resource :: binary(), Timeout :: non_neg_integer(), STimeout :: non_neg_integer()) -> {ok, binary()} | {error, term()}.
% @doc Calls redturn server `Pid' to acquire a lock on resource `Resource', holding the lock for `Timeout' milliseconds once the lock is acquired. Returns
% the ID associated with the holder of the lock. Will error if request for wait takes longer than `STimeout' milliseconds.
wait(Pid, Resource, Timeout, STimeout) ->
    gen_server:call(Pid, {wait, Resource, Timeout}, STimeout).

-spec wait_async(Pid :: pid(), Resource :: binary(), Timeout :: non_neg_integer()) -> reference().
% @doc Asynchronously calls redturn server `Pid' to acquire a lock on resource `Resource', holding the lock for `Timeout' milliseconds once the lock is acquired.
% Returns a reference `Ref'; the currently running process will receive a message of the form `{Ref, {ok, Id}} | {Ref, {error, Err}}' in response to this request.
wait_async(Pid, Resource, Timeout) ->
    wait_async(Pid, Resource, Timeout, erlang:self()).

-spec wait_async(Pid :: pid(), Resource :: binary(), Timeout :: non_neg_integer(), To :: pid()) -> reference().
% @doc Asynchronously calls redturn server `Pid' to acquire a lock on resource `Resource', holding the lock for `Timeout' milliseconds once the lock is acquired.
% Returns a reference `Ref'; process `To' will receive a message of the form `{Ref, {ok, Id}} | {Ref, {error, Err}}' in response to this request.
wait_async(Pid, Resource, Timeout, To) ->
    Ref = erlang:make_ref(),
    gen_server:cast(Pid, {wait, Resource, Timeout, Ref, To}),
    Ref.

-spec signal(Pid :: pid(), Resource :: binary(), Id :: binary()) -> ok.
% @doc Synchronously signals to redturn server `Pid' that holder `Id' of resource `Resource' is ready to release it's lock.
signal(Pid, Resource, Id) ->
    gen_server:call(Pid, {signal, Resource, Id}).

-spec signal(Pid :: pid(), Resource :: binary(), Id :: binary(), STImeout :: non_neg_integer()) -> ok.
% @doc Synchronously signals to redturn server `Pid' that holder `Id' of resource `Resource' is ready to release it's lock. Will error if request for signal takes
% longer than `STimeout' milliseconds.
signal(Pid, Resource, Id, STimeout) ->
    gen_server:call(Pid, {signal, Resource, Id}, STimeout).

-spec signal_noreply(Pid :: pid(), Resource :: binary(), Id :: binary()) -> ok.
% @doc Asynchronously signals to redturn server `Pid' that holder `Id' of resource `Resource' is ready to release it's lock.
signal_noreply(Pid, Resource, Id) ->
    gen_server:cast(Pid, {signal, Resource, Id}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init(Opts :: redturn_opts()) -> {ok, redturn_state()}.
init(#redturn_opts{id=Id, module=Mod, conn_opts=COpts, subconn_opts=SOpts}) ->
    {ok, Conn} = Mod:start_conn(COpts),
    {ok, SubConn} = Mod:start_sub(SOpts),

    Mod:controlling_process(SubConn),

    NId = case is_binary(Id) of
              true -> Id;
              false -> to_hex(crypto:strong_rand_bytes(?ID_LEN))
          end,

    State = #redturn_state{ id=NId,
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

-spec terminate(Reason :: term(), State :: redturn_state()) -> ok.
terminate(_Reason, State=#redturn_state{req_queue=RQ}) ->
    [terminate_resource(Resource, Q, State) || {Resource, Q} <- maps:to_list(RQ)],
    ok.

-spec handle_call(Msg :: redturn_call_msg(), From :: {pid(), reference()}, State :: redturn_state()) -> {noreply, redturn_state()}.
handle_call({wait, Resource, Timeout}, {From, Ref}, State) when
    is_binary(Resource),
    is_integer(Timeout) andalso Timeout > 0 ->
    NState = add_wait(Resource, Timeout, From, Ref, State),
    {noreply, NState};
handle_call({signal, Resource, Id}, {From, Ref}, State) when
    is_binary(Resource),
    is_binary(Id) ->
    NState = signal_done_sync(Resource, Id, From, Ref, State),
    {noreply, NState};
handle_call(_Req, _From, State) ->
    {noreply, State}.

-spec handle_cast(Msg :: redturn_cast_msg(), State :: redturn_state()) -> {noreply, redturn_state()}.
handle_cast({wait, Resource, Timeout, Ref, From}, State) when
    is_binary(Resource),
    is_integer(Timeout) andalso Timeout > 0 ->
    NState = add_wait(Resource, Timeout, From, Ref, State),
    {noreply, NState};
handle_cast({signal, Resource, Id}, State) when
    is_binary(Resource),
    is_binary(Id) ->
    NState = signal_done(Resource, Id, State),
    {noreply, NState};
handle_cast(_Req, State) ->
    {noreply, State}.

-spec handle_info(Msg :: redturn_info_msg(), State :: redturn_state()) -> {noreply, redturn_state()}.
handle_info(reset_msg_gen, State) ->
    NState = reset_msg_gen(State),
    {noreply, NState};
handle_info({message, Channel, Msg, SConn}, State=#redturn_state{id=Channel, module=Mod, sub_conn=SConn}) when
    is_binary(Channel),
    is_binary(Msg) ->
    Mod:ack_message(SConn),
    case binary:split(Msg, <<":">>) of
        [Id, Resource] ->
            NState = notify_wait(Resource, Id, State),
            {noreply, NState};
        _ ->
            {noreply, State}
    end;
handle_info({response, Reply}, State) ->
    NState = handle_redis_reply(Reply, State),
    {noreply, NState};
handle_info({clear_head, Resource, Id}, State=#redturn_state{head_track=Track}) when
    is_binary(Resource),
    is_binary(Id) ->
    case maps:get(Resource, Track, undefined) of
        {Id, _Ref} ->
            NState = signal_done(Resource, Id, State),
            NTrack = maps:remove(Resource, Track),
            {noreply, NState#redturn_state{head_track=NTrack}};
        _ ->
            {noreply, State}
    end;
handle_info({subscribed, Id, SConn}, State=#redturn_state{id=Id, module=Mod, sub_conn=SConn}) when
    is_binary(Id) ->
    Mod:ack_message(SConn),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

-spec to_hex(Bin :: binary()) -> binary().
to_hex(Bin) ->
    << <<(hex(A)), (hex(B))>> || <<A:4, B:4>> <= Bin>>.

-spec hex(B :: binary()) -> integer().
hex(A) when A < 10 ->
    $0 + A;
hex(A) ->
    A + $a - 10.

-spec subscribe_to_channel(State :: redturn_state()) -> ok.
subscribe_to_channel(#redturn_state{module=Mod, sub_conn=SConn, id=Id}) ->
    Mod:subscribe(SConn, [Id]).

-spec add_script() -> binary().
add_script() ->
    <<"
        local list = KEYS[1]
        local channel = ARGV[1]
        local value = ARGV[2]
        local id = ARGV[3]

        if redis.call(\"RPUSH\", list, value) == 1 then
            redis.call(\"PUBLISH\", channel, id .. \":\" .. list)
        end

        return redis.call(\"LINDEX\", list, 0)
    ">>.

-spec remove_script() -> binary().
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
            local next_id = next_split[1]
            local next_channel = next_split[2]
            redis.call(\"PUBLISH\", next_channel, next_id .. \":\" .. list)
        end

        return next
    ">>.

-spec load_scripts(State :: redturn_state()) -> redturn_state().
load_scripts(State=#redturn_state{module=Mod, conn=C}) ->
    AddScript = add_script(),
    RemoveScript = remove_script(),
    [{ok, AddSha}, {ok, RemoveSha}] = Mod:qp(C, [[<<"SCRIPT">>, <<"LOAD">>, AddScript], [<<"SCRIPT">>, <<"LOAD">>, RemoveScript]]),
    State#redturn_state{scripts={AddSha, RemoveSha}}.

-spec gen_msg_id(State :: redturn_state()) -> {binary(), redturn_state()}.
gen_msg_id(State=#redturn_state{base=Base, inc=Inc}) ->
    Id = <<Base/binary, ".", (integer_to_binary(Inc))/binary>>,
    {Id, State#redturn_state{inc=Inc+1}}.

-spec add_to_req_queue(Ctx :: redturn_ctx(), State :: redturn_state()) -> redturn_state().
add_to_req_queue(Ctx=#redturn_ctx{resource=Resource, id=Id}, State=#redturn_state{req_queue=RQ, queue=Q, waiting=W}) ->
    InnerQ = maps:get(Resource, RQ, queue:new()),
    NRQ = maps:put(Resource, queue:in(Id, InnerQ), RQ),
    NQ = queue:in(Ctx, Q),
    NW = maps:put(Id, Ctx, W),
    State#redturn_state{req_queue=NRQ, queue=NQ, waiting=NW}.

%% remove items from queue under resource until we reach Id, responding to waiting contexts with error
-spec remove_from_req_queue(Ctx :: redturn_ctx(), Res :: {ok, binary()} | {error, term()}, State :: redturn_state()) -> redturn_state().
remove_from_req_queue(Ctx=#redturn_ctx{resource=Resource, id=Id}, Res, State=#redturn_state{req_queue=RQ, waiting=W}) ->
    Q = maps:get(Resource, RQ, queue:new()),
    case queue:peek(Q) of
        {value, Id} ->
            NW = maps:remove(Id, W),
            safe_reply(Res, Ctx),
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
            OCtx = maps:get(Other, W, #redturn_ctx{}),
            safe_reply({error, missed_ctx}, OCtx),
            {_, NQ} = queue:out(Q),
            NW = maps:remove(Other, W),
            remove_from_req_queue(Ctx, Res, State#redturn_state{req_queue=NQ, waiting=NW});
        empty ->
            State#redturn_state{req_queue=maps:remove(Resource, RQ)}
    end.

-spec add_wait(Resource :: binary(), Timeout :: non_neg_integer(), From :: pid(), Ref :: reference(), State :: redturn_state()) -> redturn_state().
add_wait(Resource, Timeout, From, Ref, State=#redturn_state{id=Channel, conn=C, module=Mod, scripts={AddSha, _}}) ->
    {Id, State1} = gen_msg_id(State),
    Val = <<Id/binary, ":", Channel/binary, ":", (integer_to_binary(Timeout))/binary>>,
    ok = Mod:q_async(C, [<<"EVALSHA">>, AddSha, 1, Resource, Channel, Val, Id]),
    Ctx = #redturn_ctx{command=wait, from=From, ref=Ref, resource=Resource, id=Id, timeout=Timeout},
    add_to_req_queue(Ctx, State1).

-spec signal_done(Resource :: binary(), Id :: binary(), State :: redturn_state()) -> redturn_state().
signal_done(Resource, Id, State=#redturn_state{conn=C, module=Mod, scripts={_, RemoveSha}, queue=Q}) ->
    ok = Mod:q_async(C, [<<"EVALSHA">>, RemoveSha, 1, Resource, Id]),
    NQ = queue:in(#redturn_ctx{command=signal, resource=Resource}, Q),
    State#redturn_state{queue=NQ}.

-spec signal_done_sync(Resource :: binary(), Id :: binary(), From :: pid(), Ref :: reference(), State :: redturn_state()) -> redturn_state().
signal_done_sync(Resource, Id, From, Ref, State=#redturn_state{conn=C, module=Mod, scripts={_, RemoveSha}, queue=Q}) ->
    ok = Mod:q_async(C, [<<"EVALSHA">>, RemoveSha, 1, Resource, Id]),
    NQ = queue:in(#redturn_ctx{command=signal, resource=Resource, from=From, ref=Ref, id=Id}, Q),
    State#redturn_state{queue=NQ}.

-spec reset_msg_gen(State :: redturn_state()) -> redturn_state().
reset_msg_gen(State) ->
    Base = to_hex(crypto:strong_rand_bytes(?ID_LEN)),
    Inc = 0,
    erlang:start_timer(?RESET_INTERVAL, erlang:self(), reset_msg_gen),
    State#redturn_state{base=Base, inc=Inc}.

-spec notify_wait(Resource :: binary(), Id :: binary(), State :: redturn_state()) -> redturn_state().
notify_wait(Resource, Id, State=#redturn_state{waiting=W}) ->
    case maps:get(Id, W, undefined) of
        undefined ->
            signal_done(Resource, Id, State);
        Ctx=#redturn_ctx{id=Id, resource=Resource, timeout=Timeout} ->
            NState = remove_from_req_queue(Ctx, {ok, Id}, State),
            replace_head_track(Resource, Id, Timeout, NState)
    end.

-spec handle_redis_reply(Res :: {ok, binary()} | {error, term()}, State :: redturn_state()) -> redturn_state().
handle_redis_reply({error, Err}, State=#redturn_state{queue=Q, waiting=W}) ->
    case queue:out(Q) of
        {empty, Q} ->
            State;
        {{value, Ctx=#redturn_ctx{id=Id}}, NQ} ->
            case maps:get(Id, W, undefined) of
                undefined ->
                    State;
                Ctx ->
                    % leave context in the request queue for resource of this context, so we don't remove currently
                    % waiting requests
                    safe_reply({error, Err}, Ctx),
                    State#redturn_state{queue=NQ, waiting=maps:remove(Id, W)}
            end
    end;
handle_redis_reply({ok, Val}, State=#redturn_state{queue=Q}) when
    is_binary(Val) ->
    case binary:split(Val, <<":">>, [global]) of
        [Id, _Channel, TimeoutStr] ->
            Timeout = binary_to_integer(TimeoutStr),
            case queue:out(Q) of
                {{value, Ctx=#redturn_ctx{command=signal, resource=Resource}}, NQ} ->
                    safe_reply(ok, Ctx),
                    replace_head_track(Resource, Id, Timeout, State#redturn_state{queue=NQ});
                {{value, #redturn_ctx{command=wait, resource=Resource}}, NQ} ->
                    replace_head_track(Resource, Id, Timeout, State#redturn_state{queue=NQ});
                {empty, Q} ->
                    State
            end;
        _ ->
            {_, NQ} = queue:out(Q),
            State#redturn_state{queue=NQ}
    end;
handle_redis_reply({ok, _}, State=#redturn_state{queue=Q}) ->
    {Val, NQ} = queue:out(Q),
    case Val of
        {value, Ctx=#redturn_ctx{command=signal}} ->
            safe_reply(ok, Ctx);
        _ ->
            ok
    end,
    State#redturn_state{queue=NQ}.

-spec replace_head_track(Resource :: binary(), Id :: binary(), Timeout :: non_neg_integer(), State :: redturn_state()) -> redturn_state().
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

-spec safe_reply(Res :: {ok, binary()} | {error, term()}, Ctx :: redturn_ctx()) -> ok.
safe_reply(Res, #redturn_ctx{from=Pid, ref=Ref}) when is_pid(Pid), is_reference(Ref) ->
    try
        gen_server:reply({Pid, Ref}, Res),
        ok
    catch _:_ ->
        ok
    end;
safe_reply(_, _) ->
    ok.

-spec terminate_resource(Resource :: binary(), Q :: queue:queue(), State :: redturn_state()) -> redturn_state().
terminate_resource(Resource, Q, State=#redturn_state{waiting=W}) ->
    case queue:out(Q) of
        {{value, Id}, NQ} ->
            Ctx = maps:get(Id, W),
            safe_reply({error, closed}, Ctx),
            terminate_resource(Resource, NQ, State);
        {empty, Q} ->
            State
    end.