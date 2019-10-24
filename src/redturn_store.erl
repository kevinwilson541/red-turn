
-module(redturn_store).

-include("redturn.hrl").

-callback start_conn(Opts :: redturn_conn_opts()) -> {ok, conn()} | {error, term()}.

-callback start_sub(Opts :: redturn_sub_opts()) -> {ok, conn()} | {error, term()}.

-callback q(Conn :: conn(), Query :: query()) -> {ok, Res :: query_result()} | {error, term()}.

-callback qp(Conn :: conn(), Queries :: [query()]) -> [{ok, query_result()} | {error, term()}].

-callback q_async(Conn :: conn(), Query :: query()) -> ok.

-callback subscribe(Conn :: conn(), Channels :: [chan()]) -> ok.

-callback controlling_process(Conn :: conn()) -> ok.

-callback ack_message(Conn :: conn()) -> ok.