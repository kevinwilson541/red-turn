
-record(redturn_conn_opts, { host, port, database, password, reconnect, connect_timeout }).

-record(redturn_sub_opts, { host, port, database, password, reconnect, max_queue_size, queue_behavior }).

-record(redturn_opts, { module=redturn_eredis, conn_opts, subconn_opts }).

-record(redturn_state, { id, queue, conn, sub_conn, module, base, inc, waiting, req_queue, head_track, scripts }).

-record(redturn_ctx, { from, ref, resource, id, timeout }).


-type redturn_conn_opts() :: #redturn_conn_opts{}.

-type redturn_sub_opts() :: #redturn_sub_opts{}.

-type redturn_opts() :: #redturn_opts{}.

-type redturn_state() :: #redturn_state{}.

-type redturn_ctx() :: #redturn_ctx{}.

-type conn() :: pid().

-type query() :: [binary () | integer()].

-type query_result() :: undefined | binary() | [binary()].

-type chan() :: binary().


-define(ID_LEN, 16).
-define(ID_HEX_LEN, 32).
-define(RESET_INTERVAL, 60*60*1000).