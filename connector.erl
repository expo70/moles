-module(connector).

-define(HASH0, "0000000000000000000000000000000000000000000000000000000000000000").
-define(REGTEST_GENESIS_BLOCK_HASH, "06226e46111a0b59caaf126043eb5bbf28c34f3a5e332a1fc7b2b73cf188910f").
-define(TESTNET_GENESIS_BLOCK_HASH, "43497fd7f826957108f4a30fd9cec3aeba79972084e90ead01ea330900000000").

-behaviour(gen_server).

-export([start_link/0, stop/0, connect/0]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {net_type, socket, peer_protocol_version, peer_address, peer_port, my_protocol_version, my_address, my_port, buf}).


%% API
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
	gen_server:stop(?MODULE).

connect() ->
	gen_server:cast(?MODULE, connect).


%% callbacks
init([]) ->
	% regtest setups
	%NetType = regtest,
	%PeerAddress = {127,0,0,1},
	%PeerPort = port(NetType)+1, %bitcoind -regtest -port=xxxx -daemon
	%MyAddress = {127,0,0,1},
	%MyPort = port(NetType),
	
	% testnet setups
	NetType = testnet,
	PeerAddress = {0,0,0,0},
	PeerPort = port(NetType),
	MyAddress = {202,218,2,35},
	MyPort = port(NetType),
	
	MyProtocolVersion = 70015,
	
	listener:start_link(MyPort),
	{ok, #state{net_type=NetType, peer_address=PeerAddress, peer_port=PeerPort, peer_protocol_version=0, my_address=MyAddress, my_port=MyPort, my_protocol_version=MyProtocolVersion}}.

handle_call(_Request, _From, S) -> {reply, ok, S}.


handle_cast(connect, S) ->
	%PeerAddress = S#state.peer_address,
	%PeerAddress = {52,29,69,203},
	%PeerAddress = {178,21,118,174},
	PeerAddress = hd(seeder:seeds()),
	PeerPort = S#state.peer_port,
	io:format("connecting to ~p:~p...~n",[PeerAddress, PeerPort]),
	{ok, Socket} = gen_tcp:connect(PeerAddress, PeerPort, [binary, {packet,0}, {active, false}]),
	S1 = S#state{ socket = Socket, buf = [] },
	{ok, S2} = handshake(S1),
	loop(S2).

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	io:format("connector process is terminating...~n", []),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% Internal functions

handshake(S) ->
	NetType = S#state.net_type,
	Socket = S#state.socket,
	PeerAddress = S#state.peer_address,
	PeerPort = S#state.peer_port,
	MyAddress = S#state.my_address,
	MyPort = S#state.my_port,
	MyProtocolVersion = S#state.my_protocol_version,
	PeerProtocolVersion = MyProtocolVersion,

	Message = protocol:version(NetType, {PeerAddress, PeerPort, node_network, PeerProtocolVersion}, {MyAddress, MyPort, node_network, MyProtocolVersion}, "/Moles:0.0.1/", 0, true),
	ok = gen_tcp:send(Socket, Message),
	{ok, Packet } = gen_tcp:recv(Socket, 0, 10*1000),
	
	ok = inet:setopts(Socket, [{active, once}]),
	{ok, S#state{buf=Packet}}.

% command loop
loop(S) ->
	Packet = S#state.buf,
	case protocol:read_message(Packet) of
		{ok, {NetType, Command, Payload, Rest}} ->
			case Command of
				version ->
					io:format("Packet (version) = ~p~n",[protocol:parse_version(Payload)]),
					ok = gen_tcp:send(S#state.socket, protocol:verack(NetType));
					
				verack ->
					io:format("Packet (verack) = ~p~n", [protocol:parse_verack(Payload)]),
ok = gen_tcp:send(S#state.socket, protocol:getheaders(S#state.net_type, {S#state.my_protocol_version, [genesis_block_hash(NetType)], ?HASH0})),
ok = gen_tcp:send(S#state.socket, protocol:mempool(NetType, S#state.my_protocol_version));
%ok = gen_tcp:send(S#state.socket, protocol:getaddr(NetType));
				ping ->
					Nonce = protocol:parse_ping(Payload),
					io:format("Packet (ping) = ~p~n", [Nonce]),
					ok = gen_tcp:send(S#state.socket, protocol:pong(S#state.net_type, Nonce));
				addr ->
					io:format("Packet (addr) = ~p~n", [protocol:parse_addr(Payload,S#state.my_protocol_version)]);
				getheaders ->
					io:format("Packet (getheaders) = ~p~n", [protocol:parse_getheaders(Payload)]),
					{_Version, Hashes, _StopHash} = protocol:parse_getheaders(Payload),
					InvVects = [{msg_block, hd(Hashes)}],
					Message = protocol:getdata(NetType, InvVects), 
					ok = gen_tcp:send(S#state.socket, Message);
				sendheaders ->
					io:format("Packet (sendheaders) = ~p~n", [protocol:parse_sendheaders(Payload)]);
				headers ->
					io:format("Packet (headers) = ~p~n", [protocol:parse_headers(Payload)]);
				block ->
					io:format("Packet (block) = ~p~n", [protocol:read_block(Payload)]);
				inv ->
					io:format("Packet (inv) = ~p~n", [protocol:parse_inv(Payload)]),
InvVects = protocol:parse_inv(Payload),
ok = gen_tcp:send(S#state.socket, protocol:getdata(NetType, InvVects));
				tx ->
					io:format("Packet (tx) = ~p~n", [protocol:read_tx(Payload)]);
				reject ->
					io:format("Packet (reject) = ~p~n", [protocol:parse_reject(Payload)]);
				alert ->
					io:format("Packet (alert) = ~p~n", [Payload]);
				Unknown ->
					io:format("Unknown Pakcet (~p) = ~p~n", [Unknown, Payload])
			end;
		{error, empty} -> Rest = <<>>;
		{error, checksum, {_NetType, Rest}}->
			throw(checksum);
		{error, incomplete, Rest}-> ok
	end,
	if
		Rest =/= <<>> -> loop(S#state{buf=Rest});
		Rest =:= <<>> ->
			receive
				{tcp, Socket, Packet1} ->
					inet:setopts(Socket, [{active, once}]),
					loop(S#state{buf = <<Rest/binary,Packet1/binary>>});
				{tcp_closed, _Socket} ->
					stop(tcp_closed, S#state{buf=Rest});
				{tcp_error, _Socket, Reason} ->
					stop({tcp_error, Reason}, S#state{buf=Rest})
			end
	end.

stop(Reason, S) ->
	gen_tcp:close(S#state.socket),
	{stop, Reason, S}.


port(mainnet) ->  8333;
port(testnet) -> 18333;
port(regtest) -> 18444.

genesis_block_hash(regtest) -> ?REGTEST_GENESIS_BLOCK_HASH;
genesis_block_hash(testnet) -> ?TESTNET_GENESIS_BLOCK_HASH.
