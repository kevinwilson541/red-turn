
-module(redturn_eredis).

-behavior(redturn_store).

-include("redturn.hrl").

-export([start_conn/1,
         start_sub/1,
         q/2,
         qp/2,
         q_async/2,
         subscribe/2,
         controlling_process/1,
         ack_message/1]).

start_conn(#redturn_conn_opts{host=Host,
                              port=Port,
                              database=DB,
                              password=PW,
                              reconnect=Reconnect,
                              connect_timeout=CTimeout}) ->
    Opts = [{host, Host},
            {port, Port},
            {database, DB},
            {password, PW},
            {reconnect_sleep, Reconnect},
            {connect_timeout, CTimeout}],
    
    Filtered = [{Key, Val} || {Key, Val} <- Opts, Val =/= undefined],
    eredis:start_link(Filtered).

start_sub(#redturn_sub_opts{host=Host,
                            port=Port,
                            database=DB,
                            password=PW,
                            reconnect=Reconnect,
                            max_queue_size=MaxSize,
                            queue_behavior=QBehavior}) ->
    Opts = [{host, Host},
            {port, Port},
            {database, DB},
            {password, PW},
            {reconnect_timeout, Reconnect},
            {max_queue_size, MaxSize},
            {queue_behavior, QBehavior}],
    
    Filtered = [{Key, Val} || {Key, Val} <- Opts, Val =/= undefined],
    eredis_sub:start_link(Filtered).

q(Conn, Query) ->
    eredis:q(Conn, Query).

qp(Conn, Queries) ->
    eredis:qp(Conn, Queries).

q_async(Conn, Query) ->
    eredis:q_async(Conn, Query).

subscribe(Conn, Channels) ->
    eredis_sub:subscribe(Conn, Channels).

controlling_process(Conn) ->
    eredis_sub:controlling_process(Conn).

ack_message(Conn) ->
    eredis_sub:ack_message(Conn).