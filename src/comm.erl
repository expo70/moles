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

-export([start_link/2]).

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
start_link(NetType, {CommType, CommTarget}) ->
	Args = [NetType, {CommType, CommTarget}],
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
	io:format("comm:init~n",[]),
	% trap_exit flag is required for terminate function to be called
	% when application:stop shuts down the supervision tree.
	process_flag(trap_exit, true),

	{ok, MyAddress} =
	case NetType of
		mainnet -> application:get_env(my_global_address);
		testnet -> application:get_env(my_global_address);
		regtest -> application:get_env(my_local_address)
	end,
	MyProtocolVersion = 70015, %latest version at this time
	MyServices = [node_network, node_witness],
	MyBestHeight = blockchain:get_best_height(),
	StartTime = erlang:system_time(second),
	TimerRef = erlang:send_after(?HANDSHAKE_TIMEOUT,self(),handshake_timeout),

	InitialState = #state{
		net_type=NetType,
		peer_address={0,0,0,0},
		peer_port=0,
		peer_protocol_version=0,
		peer_services=[],
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
		buf= <<>>
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

	%{ok, not_initialized_yet}.
	{ok, InitialState}.


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
			{ok, {_MyAddress, MyPort}} = inet:sockname(Socket),
			S1 = S#state{ socket=Socket, comm_type=outgoing,
				peer_address=PeerAddress, peer_port=PeerPort,
				my_port=MyPort },
			S2 = send_first_version_message(S1),
			{noreply, S2};
		{error, Reason} ->
			stop({connect_failed, Reason}, S#state{peer_address=PeerAddress})
	end;
handle_cast({assync_init_incoming, Socket, S}, _S) ->
	ok = acceptor:request_control(Socket, self()),

	{ok, {PeerAddress, PeerPort}} = inet:peername(Socket),
	{ok, {_MyAddress, MyPort}} = inet:sockname(Socket),
	io:format("connection from ~p:~p...~n",[PeerAddress, PeerPort]),

	S1 = S#state{socket=Socket, comm_type=incoming,
		peer_address=PeerAddress, peer_port=PeerPort, my_port=MyPort},

	case peer_finder:check_now_in_use(PeerAddress) of
		true ->
			stop(peer_duplicated, S1);
		false ->
			inet:setopts(Socket, [{active, once}]),
			{noreply, S1}
	end.


%% TCP related messages
%% received after setting {active, once}
handle_info({tcp, Socket, Packet}, S) ->
	Rest = S#state.buf,
	InBytes = S#state.in_bytes + byte_size(Packet),
	S1 = get_command(S#state{buf = <<Rest/binary,Packet/binary>>, 
		in_bytes=InBytes}),
	inet:setopts(Socket, [{active, once}]),
	{noreply, S1};

handle_info({tcp_closed, _Socket}, S) ->
	stop(tcp_closed, S);

handle_info({tcp_error, _Socket, Reason}, S) ->
	stop({tcp_error, Reason}, S);

handle_info(find_job, S) ->
	S1 =
	case jobs:find_job(S#state.peer_address) of
		not_available ->
			S;
		Job ->
			do_job(Job, S)
	end,

	%io:format("comm:find_job finished.~n",[]),
	TimerRefFindJob = erlang:send_after(?FIND_JOB_INTERVAL, self(), find_job),
	{noreply, S1#state{timer_ref_find_job=TimerRefFindJob}};

handle_info(ping, S) ->
	NetType = S#state.net_type,
	S1 =
	case S#state.timer_ref_ping_timeout of
		undefined ->
			Message = protocol:ping(NetType),
			{ok,S0} = send(S#state.socket, Message, S),
			TimerRefPingTimeout =
				erlang:send_after(?PING_TIMEOUT, self(), ping_timeout),
			S0#state{timer_ref_ping_timeout=TimerRefPingTimeout};
		_ -> S % ping has been sent; do nothing
	end,

	io:format("comm:ping finished.~n",[]),
	TimerRefPing = erlang:send_after(?PING_INTERVAL, self(), ping),
	{noreply, S1#state{timer_ref_ping=TimerRefPing}};

handle_info(ping_timeout, S) ->
	stop(ping_timeout, S);

handle_info(handshake_timeout, S) ->
	stop(handshake_timeout, S).


terminate(Reason, S) ->
	case S#state.socket of
		undefined ->
			peer_finder:update_peer_last_error(S#state.peer_address, Reason);
		Socket ->
			ok = gen_tcp:close(Socket),
			PeerAddress = S#state.peer_address,
			case Reason of
				shutdown ->
					% when application:stop, stratey process is shut down before
					% comm process is shut down according to the initilization
					% order in the supervision tree.
					PeerInfo = current_peer_info(S, normal),
					peer_finder:update_peer(PeerInfo);
				peer_duplicated ->
					ok;
				Error ->
					% when an error has been occured
					case handshakeQ(S) of
						true ->
							strategy:remove_peer(PeerAddress),
							PeerInfo = current_peer_info(S, Error),
							peer_finder:update_peer(PeerInfo);
						false -> ok
					end
			end
	end,
	io:format("comm:terminate - Reason = ~p~n",[Reason]),
	ok.



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
	
	erlang:cancel_timer(S#state.timer_ref_ping_timeout),
	
	S#state{timer_ref_ping_timeout=undefined}.


process_addr(Payload, S) ->
	%io:format("Packet (addr) = ~p~n", [protocol:parse_addr(Payload,S#state.my_protocol_version)]),
	Addr = protocol:parse_addr(Payload,S#state.my_protocol_version),
	strategy:got_addr(Addr, S#state.peer_address),
	S.

process_getaddr(<<>> =_Payload, S) ->
	io:format("Pakcet (getaddr)~n",[]),
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
	{N_Headers,_} = protocol:read_var_int(Payload),
	case N_Headers =< ?MAX_HEADERS_COUNT of
		true ->
			_Headers = protocol:parse_headers(Payload), % syntactic check
			strategy:got_headers(Payload, S#state.peer_address);
		false ->
			exit(too_big_headers_count)
	end,
	S.


process_block(Payload, S) ->
	io:format("Packet (block) = ~p~n", [protocol:read_block(Payload)]),
	S.


process_getdata(_Payload, S) ->
	io:format("Pakcet (getdata)~n",[]),
	
	S.


process_inv(Payload, S) ->
	io:format("Packet (inv) = ~p~n", [protocol:parse_inv(Payload)]),
	InvVects = protocol:parse_inv(Payload),
	strategy:got_inv(InvVects, S#state.peer_address),
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
	%io:format("comm:get_command~n",[]),
	cancel_timer_if_not_undefined(S#state.timer_ref_find_job),
	TimerRefFindJob = erlang:send_after(?FIND_JOB_INTERVAL, self(), find_job),
	cancel_timer_if_not_undefined(S#state.timer_ref_ping),
	TimerRefPing = erlang:send_after(?PING_INTERVAL, self(), ping),
	
	Packet = S#state.buf,
	Read = protocol:read_message(Packet),
	S1 =
	case Read of
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
				getaddr ->
					process_getaddr(Payload, S);
				getheaders ->
					process_getheaders(Payload, S);
				sendheaders ->
					process_sendheaders(Payload, S);
				headers ->
					process_headers(Payload, S);
				block ->
					process_block(Payload, S);
				getdata ->
					process_getdata(Payload, S);
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
			%io:format("comm:get_command - incomplete (~w), len=~w~n",
			%	[Rest, byte_size(Rest)]),
			S
	end,
	
	NewState = S1#state{buf=Rest,
		timer_ref_ping=TimerRefPing,
		timer_ref_find_job=TimerRefFindJob},
	
	case Read of
		{error, incomplete, _} -> NewState;
		_ ->
			if
				Rest =/= <<>> -> get_command(NewState);
				Rest =:= <<>> ->
				% wait for the next packet
				NewState
			end
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


current_peer_info(S, ErrorState) ->
	EndTime = erlang:system_time(second),
	Duration = EndTime - S#state.start_time,
	PeerInfo = {S#state.peer_address,
		S#state.peer_user_agent,
		S#state.peer_services,
		S#state.peer_start_height,
		EndTime,
		Duration,
		S#state.in_bytes,
		S#state.out_bytes,
		ErrorState
	},
	PeerInfo.


do_job({_Target, JobSpec, _ExpirationTime, _Stamps}, S) ->
	Socket = S#state.socket,
	NetType = S#state.net_type,
	ProtocolVersion = S#state.my_protocol_version,

	case JobSpec of
		{getheaders, Hashes} ->
			io:format("comm:job getheaders~n",[]),
			%io:format("\t~p~n",[[protocol:parse_hash(H) || H<-Hashes]]),
			HashStrs = [protocol:parse_hash(H) || H <- Hashes],
			Message = protocol:getheaders(NetType,
				{ProtocolVersion, HashStrs, ?HASH256_ZERO_STR}),
			{ok,S1} = send(Socket, Message, S),
			S1;
		{headers, Payload} ->
			io:format("comm:job headers~n",[]),
			Message = protocol:message(NetType,headers,Payload),
			{ok,S1} = send(Socket, Message, S),
			S1;
		Unknown ->
			io:format("Unknown job spec detected: ~w~n",[Unknown]),
			S
	end.


stop(Reason, S) ->
	{stop, Reason, S}.
