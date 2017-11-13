%% Module for connecting/listening network nodes
%% Each process communicates exactly one other network node.
%%
%% comm processes are started by comm_sup.
%% Sockets are opened via explict connect call (outgoing), or by
%% accepting requests to our listen port from the other nodes (incoming).
%%
%% outgoing:
%% Port(??????) => Port(18333?) of the other nodes
%% 
%% incoming:
%% Port(18333?) <= internet
%% 
%% Once sockets are estabilished, threre are no essential differences 
%% in the communication.
-module(comm).
-include("../include/constants.hrl").

-behaviour(gen_server).

-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, 
	{
		net_type, % mainnet | testnet | regtest
		socket,
		comm_type, % incoming | outgoing
		peer_protocol_version,
		peer_address,
		peer_port,
		peer_services,
		peer_start_height,
		peer_readyQ,
		peer_user_agent,
		my_protocol_version,
		my_address,
		my_port,
		my_services,
		my_best_height,
		my_readyQ,
		version_nonce,
		%last_ping_nonce,
		start_time,
		timer_ref_handshake_timeout,
		timer_ref_ping,
		timer_ref_ping_timeout,
		timer_ref_find_job,
		in_bytes,
		out_bytes,
		buf
	}).

-define(FIRST_RESPONSE_TIMEOUT, 10*1000). % = 10 sec
-define(HANDSHAKE_TIMEOUT,      10*1000).
-define(PING_INTERVAL,          60*1000). % =  1 min
-define(PING_TIMEOUT,        20*60*1000). % = 20 min
-define(FIND_JOB_INTERVAL,       5*1000).


%%-----------------------------------------------------------------------------
%% API
%%-----------------------------------------------------------------------------
start_link([_NetType, {_CommType, _CommTarget}]=Args) ->
	Opts = [],
	%NOTE, we do not register the name
	gen_server:start_link(?MODULE, Args, Opts).




%%-----------------------------------------------------------------------------
%% callbacks
%%-----------------------------------------------------------------------------

%%
%% Asynchronous initialization of gen_server is a bit tricky.
%% Threre are some known ways of doing it:
%% * use 'self() ! Message' or cast in init(), then handle_info/cast
%% * use timeout in init()
%% and threre are some related methods:
%% * use proc_lib (special process)
%% * use gen_statem's next_event 
%% ref: https://stackoverflow.com/questions/6052954/is-it-bad-to-send-a-message-to-self-in-init
%% 
%% The first two ways are not completely safe, but you can use gen_server.
%% We use the first method here.
%%
%% @param
%% {incoming, Socket} | {outgoing, {Address, Port}}
%%
%% NOTE: don't use incoming socket in this function
init([NetType, {CommType, CommTarget}]) ->
	MyAddress =
	case NetType of
		mainnet -> application:get_env(my_global_address);
		testnet -> application:get_env(my_global_address);
		regtest -> application:get_env(my_local_address)
	end,
	MyProtocolVersion = 70015, %latest version at this time
	MyServices = protocol:services([node_witness]),
	MyBestHeight = strategy:get_best_height(),
	StartTime = erlang:system_time(second),
	TimerRef = erlang:send_after(?HANDSHAKE_TIMEOUT,self(),handshake_timeout),

	InitialState = #state{
		net_type=NetType,
		peer_address={0,0,0,0},
		peer_port=0,
		peer_protocol_version=0,
		peer_services=0,
		peer_readyQ=false,
		my_address=MyAddress,
		my_port=0,
		my_protocol_version=MyProtocolVersion,
		my_services=MyServices,
		my_best_height=MyBestHeight,
		my_readyQ=false,
		start_time=StartTime,
		timer_ref_handshake_timeout=TimerRef,
		in_bytes =0,
		out_bytes=0,
		buf=[]
	},
	
	%% asynchronous init
	case CommType of
		outgoing ->
			gen_server:cast(self(), {assync_init_outgoing,
				CommTarget, InitialState});
		incoming ->
			gen_server:cast(self(), {assync_init_incoming,
				CommTarget, InitialState})
	end,

	{ok, not_initialized_yet}.


handle_call(_Request, _From, S) ->
	{reply, ok, S}.


handle_cast({assync_init_outgoing, {PeerAddress, PeerPort}, S}, _S) ->
	io:format("connecting to ~p:~p...~n",[PeerAddress, PeerPort]),
	NetType = S#state.net_type,
	MyAddress = S#state.my_address,
	if
		(PeerAddress =:= MyAddress) andalso (NetType =/= regtest) ->
			stop(connection_to_itself, S);
		true -> ok
	end,
	
	% start with {active, false}
	% after the first recv, chenage to {active, once}
	case gen_tcp:connect(PeerAddress, PeerPort,
		[binary, {packet,0}, {active, false}]) of
		{ok, Socket} ->
			{_MyAddress, MyPort} = inet:sockname(Socket),
			S1 = S#state{ socket=Socket, my_port=MyPort },
			S2 = send_first_version_message(S1),
			{noreply, S2};
		{error, Reason} ->
			stop({connect_failed, Reason}, S)
	end;
handle_cast({assync_init_incoming, Socket, S}, _S) ->
	{PeerAddress, PeerPort} = inet:peername(Socket),
	io:format("connection from ~p:~p...~n",[PeerAddress, PeerPort]),

	ok = acceptor:request_control(Socket, self()),

	inet:setopts(Socket, [{active, once}]),

	{noreply, S#state{socket=Socket, 
		peer_address=PeerAddress, peer_port=PeerPort}}.


%% TCP related messages
%% received after setting {active, once}
handle_info({tcp, Socket, Packet}, S) ->
	Rest = S#state.buf,
	InBytes = S#state.in_bytes + byte_size(Packet),
	get_command(S#state{buf = <<Rest/binary,Packet/binary>>, in_bytes=InBytes}),
	inet:setopts(Socket, [{active, once}]),
	{noreply, S};
handle_info({tcp_closed, _Socket}, S) ->
	stop(tcp_closed, S);
handle_info({tcp_error, _Socket, Reason}, S) ->
	stop({tcp_error, Reason}, S);
handle_info(find_job, S) ->
	S1 =
	case jobs:find_job(S#state.peer_address) of
		not_available -> S;
		Job ->
			do_job(Job, S)
	end,

	TimerRefFindJob = erlang:send_after(?FIND_JOB_INTERVAL, self(), find_job),
	{noreply, S1#state{timer_ref_find_job=TimerRefFindJob}};
handle_info(ping, S) ->
	S1 =
	case S#state.timer_ref_ping_timeout of
		undefined ->
			Message = protocol:ping(),
			S0 = send(S#state.socket, Message, S),
			TimerRefPingTimeout =
				erlang:send_after(?PING_TIMEOUT, self(), ping_timeout),
			S0#state{timer_ref_ping_timeout=TimerRefPingTimeout};
		_ -> S % ping has been sent; do nothing
	end,

	TimerRefPing = erlang:send_after(?PING_INTERVAL, self(), ping),
	{noreply, S1#state{timer_ref_ping=TimerRefPing}};
handle_info(ping_timeout, S) ->
	stop(ping_timeout, S);
handle_info(handshake_timeout, S) ->
	stop(handshake_timeout, S).


terminate(Reason, S) ->
	case S#state.socket of
		undefined -> ok;
		Socket ->
			%gen_tcp:shutdown(Socket, write),
			ok = gen_tcp:close(Socket),
			case handshakeQ(S) of
				true ->
					EndTime = erlang:system_time(second),
					Duration = S#state.start_time - EndTime,
					PeerInfo = {S#state.peer_address,
						S#state.peer_user_agent,
						S#state.peer_services,
						S#state.peer_start_height,
						EndTime,
						Duration,
						S#state.in_bytes,
						S#state.out_bytes
						},

					strategy:remove_peer(PeerInfo);
				false -> ok
			end
	end,
	io:format("terminating at state = ~w~nReason = ~p~n",[S,Reason]).



%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------
create_version_message(S) ->
	NetType = S#state.net_type,
	PeerAddress = S#state.peer_address,
	PeerPort = S#state.peer_port,
	PeerServices = S#state.peer_services,
	MyAddress = S#state.my_address,
	MyPort = S#state.my_port,
	MyProtocolVersion = S#state.my_protocol_version,
	MyServices = S#state.my_services,
	PeerProtocolVersion = MyProtocolVersion,
	MyBestHeight = S#state.my_best_height,
	RelayQ = true,

	VersionNonce = protocol:nonce64(),
	
	% the first message
	Message = protocol:version(
		NetType,
		{PeerAddress, PeerPort, PeerServices, PeerProtocolVersion},
		{MyAddress, MyPort, MyServices, MyProtocolVersion},
		VersionNonce,
		"/Moles:0.1.0/", MyBestHeight, RelayQ
	),
	
	{Message, S#state{version_nonce=VersionNonce}}.


%% returns NewState
%% 
send_first_version_message(S) ->
	Socket = S#state.socket,

	{Message, S1} = create_version_message(S),
	{ok,S2} = send(Socket, Message, S1),
	Timeout = ?FIRST_RESPONSE_TIMEOUT,
	case gen_tcp:recv(Socket, 0, Timeout) of
		{ok, Packet} ->
			InBytes = S2#state.in_bytes + byte_size(Packet),
			NewState = get_command(S2#state{buf=Packet, in_bytes=InBytes}),
			ok = inet:setopts(Socket, [{active, once}]),
			NewState;
		{error, Reason} -> stop({version_message_failed, Reason}, S2)
	end.


process_version(Payload, S) ->
	io:format("Packet (version) = ~p~n",[protocol:parse_version(Payload)]),

	S1 =
	case protocol:parse_version(Payload) of
		{B1,{},{}} ->
			{{MyServicesType, MyProtocolVersion}, _Timestamp,
				{_PeerAddress, _PeerPort}, _PeerServicesType, _Time} = B1,
			VersionNonce = 0,
			S#state{peer_services=MyServicesType,
				peer_protocol_version=MyProtocolVersion};
		{B1,B2,_RelayQ} ->
			{{MyServicesType, MyProtocolVersion}, _Timestamp,
				{_PeerAddress, _PeerPort}, _PeerServicesType, _Time} = B1,
			{{_MyAddress, _MyPort}, _MyServicesType, _Time, VersionNonce,
				StrUserAgent, StartBlockHeight} = B2,
			S#state{peer_services=MyServicesType,
				peer_protocol_version=MyProtocolVersion,
				peer_start_height=StartBlockHeight,
				peer_user_agent=StrUserAgent}
	end,

	NetType = S1#state.net_type,
	Socket = S1#state.socket,

	case S1#state.comm_type of
		incoming ->
			{VersionMessage,S2} = create_version_message(S1),
			{ok,S3} = send(Socket, VersionMessage, S2);
		outgoing ->
			MyVersionNonce = S1#state.version_nonce,
			S3 = S1,
			case VersionNonce of
				MyVersionNonce -> exit(echo_detected);
				_Others -> ok
			end
	end,
	
	Reply = protocol:verack(NetType),
	{ok,S4} = send(Socket, Reply, S3),
	
	case S4#state.peer_readyQ of
		true -> on_handshake(S4);
		false -> ok
	end,
	S4#state{my_readyQ = true}.


process_verack(Payload, S) ->
	io:format("Packet (verack) = ~p~n", [protocol:parse_verack(Payload)]),

	case S#state.my_readyQ of
		true -> on_handshake(S);
		false -> ok
	end,
	S#state{peer_readyQ = true}.


process_ping(Payload, S) ->
	Nonce = protocol:parse_ping(Payload),
	io:format("Packet (ping) = ~p~n", [Nonce]),

	Reply = protocol:pong(S#state.net_type, Nonce),
	{ok,S1} = send(S#state.socket, Reply, S),

	S1.


process_pong(Payload, S) ->
	Nonce = protocol:parse_pong(Payload),
	io:format("Packet (pong) = ~p~n", [Nonce]),
	
	erlang:cencel_timer(S#state.timer_ref_ping_timeout),
	
	S#state{timer_ref_ping_timeout=undefined}.


process_addr(Payload, S) ->
	%io:format("Packet (addr) = ~p~n", [protocol:parse_addr(Payload,S#state.my_protocol_version)]),
	Addr = protocol:parse_addr(Payload,S#state.my_protocol_version),
	strategy:got_addr(Addr, S#state.peer_address),
	S.


process_getheaders(Payload, S) ->
	%io:format("Packet (getheaders) = ~p~n", [protocol:parse_getheaders(Payload)]),
	GetHeaders = protocol:parse_getheaders(Payload),
	strategy:got_getheaders(GetHeaders, S#state.peer_address),
	S.

process_sendheaders(Payload, S) ->
	io:format("Packet (sendheaders) = ~p~n", [protocol:parse_sendheaders(Payload)]),
	S.


process_headers(Payload, S) ->
	%io:format("Packet (headers) = ~p~n", [protocol:parse_headers(Payload)]),
	_Headers = protocol:parse_headers(Payload), % syntactic check
	strategy:got_headers(Payload, S#state.peer_address),
	S.


process_block(Payload, S) ->
	io:format("Packet (block) = ~p~n", [protocol:read_block(Payload)]),
	S.


process_inv(Payload, S) ->
	io:format("Packet (inv) = ~p~n", [protocol:parse_inv(Payload)]),
	S.


process_tx(Payload, S) ->
	io:format("Packet (tx) = ~p~n", [protocol:read_tx(Payload)]),
	S.


process_reject(Payload, S) ->
	io:format("Packet (reject) = ~p~n", [protocol:parse_reject(Payload)]),
	S.


process_alert(Payload, S) ->
	io:format("Packet (alert) = ~p~n", [Payload]),
	S.


process_unknown_message(Unknown, Payload, S) ->
	io:format("Unknown Pakcet (~p) = ~p~n", [Unknown, Payload]),
	S.

%%
%% returns NewState
%% 
get_command(S) ->
	cancel_timer_if_not_undefined(S#state.timer_ref_find_job),
	TimerRefFindJob = erlang:send_after(?FIND_JOB_INTERVAL, self(), find_job),
	cancel_timer_if_not_undefined(S#state.timer_ref_ping),
	TimerRefPing = erlang:send_after(?PING_INTERVAL, self(), ping),
	
	Packet = S#state.buf,
	S1 =
	case protocol:read_message(Packet) of
		{ok, {_NetType, Command, Payload, Rest}} ->
			case Command of
				version ->
					process_version(Payload, S);
				verack ->
					process_verack(Payload, S);
				ping ->
					process_ping(Payload, S);
				pong ->
					process_pong(Payload, S);
				addr ->
					process_addr(Payload, S);
				getheaders ->
					process_getheaders(Payload, S);
				sendheaders ->
					process_sendheaders(Payload, S);
				headers ->
					process_headers(Payload, S);
				block ->
					process_block(Payload, S);
				inv ->
					process_inv(Payload, S);
				tx ->
					process_tx(Payload, S);
				reject ->
					process_reject(Payload, S);
				alert ->
					process_alert(Payload, S);
				Unknown ->
					process_unknown_message(Unknown, Payload, S)
			end;
		{error, empty} ->
			Rest = <<>>,
			S;
		{error, checksum, {_NetType, Rest}}->
			exit(checksum);
		{error, incomplete, Rest}->
			S
	end,
	NewState = S1#state{buf=Rest,
		timer_ref_ping=TimerRefPing,
		timer_ref_find_job=TimerRefFindJob},
	if
		Rest =/= <<>> -> get_command(NewState);
		Rest =:= <<>> ->
			% wait for the next packet
			NewState
	end.


send(Socket, Message, S) ->
	%Command = protocol:command_type_of_message(Message),
	OutBytes = S#state.out_bytes + byte_size(Message),

	{gen_tcp:send(Socket, Message), S#state{out_bytes=OutBytes}}.


cancel_timer_if_not_undefined(TimerRef) ->
	case TimerRef of
		undefined -> false;
		_ -> erlang:cancel_timer(TimerRef)
	end.


handshakeQ(S) -> S#state.peer_readyQ andalso S#state.my_readyQ.


on_handshake(S) ->
	erlang:cancel_timer(S#state.timer_ref_handshake_timeout),
	strategy:add_peer(S#state.peer_address).


do_job({_Target, JobSpec, _ExpirationTime, _Stamps}, S) ->
	Socket = S#state.socket,
	NetType = S#state.net_type,

	case JobSpec of
		{getheaders, Hashes} ->
			HashStrs = [protocol:parse_hash(H) || H <- Hashes],
			Message = protocol:getheaders(NetType,HashStrs,?HASH256_ZERO_STR),
			S1 = send(Socket, Message, S),
			S1;
		{headers, Payload} ->
			Message = protocol:message(NetType,headers,Payload),
			S1 = send(Socket, Message, S),
			S1;
		Unknown ->
			io:format("Unknown job spec detected: ~w~n",[Unknown]),
			S
	end.


stop(Reason, S) ->
	{stop, Reason, S}.
