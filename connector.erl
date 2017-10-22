-module(connector).

-behaviour(gen_server).

-export([start_link/0, stop/0, connect/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {peer_infos, socket, port}).


%% API
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
	gen_server:stop(?MODULE).

connect() ->
	gen_server:call(?MODULE, connect).


%% callbacks
init([]) ->
	Port = port(testnet),
	listener:start_link(Port),
	{ok, #state{peer_infos=[], port=Port}}.

% version(NetType, {PeerAddress, PeerPort, PeerServicesType, PeerProtocolVersion}, {MyAddress, MyPort, MyServicesType, MyProtocolVersion}, StrUserAgent, StartBlockHeight, RelayQ)
handle_call(connect, _From, S) ->
	PeerInfos = if
		S#state.peer_infos =:= [] -> seeder:seeds();
		S#state.peer_infos =/= [] -> S#state.peer_infos
	end,
	PeerAddress = hd(PeerInfos),
	Port = S#state.port,
	io:format("connecting to ~p:~p...~n",[PeerAddress, Port]),
	Message = protocol:version(testnet, {PeerAddress, Port, node_network, 60002}, {{202,218,2,35}, Port, node_network, 60002}, "/Moles:0.0.1/", 0, false),
	{ok, Socket} = gen_tcp:connect(PeerAddress, Port, [binary, {packet,0}, {active, false}]),
	ok = gen_tcp:send(Socket, Message),
	R = case gen_tcp:recv(Socket, 0, 2000) of
		{ok, Pakcet} -> Pakcet;
		{error, Reason} -> io:format("error ~p~n",[Reason]),<<>>
	end,
	io:format("Packet = ~p~n",[R]),
	ok = gen_tcp:close(),
	% TODO: update S
	{reply, ok, S};
handle_call(_Request, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	io:format("connector process is terminating...~n", []),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal functions
port(testnet) -> 18333.
