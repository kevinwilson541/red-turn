redturn
=====

An OTP library for event-based queueing redis locks. Algorithm described below.

Build
-----

    $ rebar3 compile

Test
-----

    $ rebar3 eunit

Algorithm
-----

#### Acquire Lock Script
```lua
local list = KEYS[1]
local channel = ARGV[1]
local value = ARGV[2]
local id = ARGV[3]

if redis.call("RPUSH", list, value) == 1 then
    redis.call("PUBLISH", channel, list .. ":" .. id)
end

return redis.call("LINDEX", list, 0)
```

The requester will push a request context, formatted as `<req_id>:<req_channel>:<req_timeout>`, onto the resource list. If our request is the first to enter
the resource lock queue, we notify the requester that they have the lock and can continue processing. Finally, we return the first element so that a requester
knows the head context of the resource lock queue (for monitoring that context's lock timeout).

#### Release Lock Script
```lua
local list = KEYS[1]
local id = ARGV[1]

local value = redis.call("LINDEX", list, 0)
local val_split = {}
for w in (value .. ":"):gmatch("([^:]*):") do
    table.insert(val_split, w)
end

local val_id = val_split[1]
local called = false
if val_id == id then
    redis.call("LPOP", list)
    called = true
end

local next = redis.call("LINDEX", list, 0)
if next ~= false and called == true then
    local next_split = {}
    for w in (next .. ":"):gmatch("([^:]*):") do
        table.insert(next_split, w)
    end
    local next_id = next_split[1]
    local next_channel = next_split[2]
    redis.call("PUBLISH", next_channel, list .. ":" .. next_id)
end

return next
```

The signaler (lock releaser) will check if the head of the resource lock queue for `KEYS[1]` contains the same id to be removed as passed into
`ARGV[1]`. If not, we just return the head of the resource lock queue so the requester can monitor the head context's lock timeout. Otherwise,
we remove the head of the list, grab the next head of the resource lock queue, and notify the new context that it has acquired a lock.

Usage
-------

Start a redturn server:
```erlang
ConnOpts = #redturn_conn_opts{host=<<"localhost">>, port=6379, database=0, password=<<"">>},
SubConnOpts = #redturn_sub_opts{host=<<"localhost">>, port=6379, database=0, password=<<"">>}
Opts = #{id=<<"server_id">>, module=redturn_eredis, conn_opts=ConnOpts, subconn_opts=SubConnOpts},
% start server
{ok, Pid} = redturn:start_link(Opts),
```

Acquire and release lock:
```erlang
% acquire lock on resource_name, valid for 5000 milliseconds, returns context id to release lock with
{ok, Id} = redturn:wait(Pid, <<"resource_name">>, 5000)

% do work while holding lock

% release lock
ok = redturn:signal(Pid, <<"resource_name">>, Id)
```

Acquire lock asynchronously and release lock:
```erlang
% acquire lock on resource_name, valid for 5000 milliseconds, returns context id to release lock with
Ref = redturn:wait_async(Pid, <<"resource_name">>, 5000),
receive
    {Ref, {ok, Id}} ->
        % do work while holding lock

        % release lock
        ok = redturn:signal(Pid, <<"resource_name">>, Id)
end
```

redturn_store behavior
------
This library uses a generic behavior for a backend store, with the default implementation being `redturn_store.erl`. Different
implementations can be used for different redis clients, or on top of another backend store that fits the API usage of the behavior
(pubsub, script evaluation, command pipelining).