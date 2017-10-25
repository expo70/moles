-module(acceptor).

-export([start_link/1, init/1]).



%% API
start_link(ListenSocket) ->
	proc_lib:spawn_link(?MODULE, init, [ListenSocket]).



%% Internal functions
init(ListenSocket) ->
	{ok, Socket} = gen_tcp:accept(ListenSocket),
	loop(Socket).
	%case gen_tcp:accept(ListenSocket) of
	%	{ok, Socket} -> loop(Socket);
	%	{error, Reason} -> exit({error, Reason})
	%end.

loop(Socket) ->
	{ok, Packet} = gen_tcp:recv(Socket, 0, 2000),
	{NetType, Command, Payload} = protocol:read_message(Packet),
	io:format("Incoming Pakcet = ~p~n", [protocol:read_version(Payload)]),
	loop(Socket).

