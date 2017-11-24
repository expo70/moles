%%
-module(strategy).

-behaviour(gen_server).

-include("../include/constants.hrl").

-record(state,
	{
		net_type,
		mode,
		target_n_peers,
		n_peers,
		best_height
	}).

%% API
-export([start_link/1, add_peer/1, remove_peer/1,
	got_headers/2, got_getheaders/2, got_addr/2, got_inv/2, got_tx/2]).

%% gen_server callbak
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHECK_N_PEERS_INTERVAL, 30*1000).


%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	gen_server:start_link({local,?MODULE}, ?MODULE, [NetType], []).

add_peer(IP_Address) ->
	gen_server:cast(?MODULE, {add_peer, IP_Address}).

remove_peer(IP_Address) ->
	gen_server:cast(?MODULE, {remove_peer, IP_Address}).

got_headers(Payload, Origin) ->
	gen_server:cast(?MODULE, {got_headers, Payload, Origin}).

got_getheaders(GetHeaders, Origin) ->
	gen_server:cast(?MODULE, {got_getheaders, GetHeaders, Origin}).

got_addr(Addr, Origin) ->
	gen_server:cast(?MODULE, {got_addr, Addr, Origin}).

got_inv(InvVects, Origin) ->
	gen_server:cast(?MODULE, {got_inv, InvVects, Origin}).

got_tx(Payload, Origin) ->
	gen_server:cast(?MODULE, {got_tx, Payload, Origin}).


%% ----------------------------------------------------------------------------
%% gen_server callback
%% ----------------------------------------------------------------------------
init([NetType]) ->
	BestHeight = blockchain:get_best_height(),
	
	InitialState = #state{
		net_type = NetType,
		mode = header_first,
		target_n_peers = 2,
		n_peers = 0,
		best_height = BestHeight
	},
	
	erlang:send_after(200, self(), check_n_peers), % start accessing peers
	{ok, InitialState}.


handle_call(_Request, _From, S) ->
	{reply, ok, S}.


handle_cast({add_peer, IP_Address}, S) ->
	Mode = S#state.mode,
	N_Peers = S#state.n_peers,
	
	case Mode of
		header_first1 ->
			MaxDepth = 5,
			case blockchain:collect_getheaders_hashes(MaxDepth) of
				not_ready -> ok;
				ListOfList ->
					io:format("getheaders hashes were proposed: ~p~n",
						[ListOfList]),
					[jobs:add_job(
					{IP_Address, {getheaders,Hashes}, 300})
					|| Hashes <- ListOfList]
			end;
		header_first ->
			{A,P} = {0.75,0.08},
			case blockchain:collect_getheaders_hashes_exponential({A,P}) of
				not_ready -> ok;
				Hashes ->
					Hashes1 = lists:sublist(Hashes,?MAX_HEADERS_COUNT),
					jobs:add_job({IP_Address, {getheaders,Hashes1}, 300})
			end
	end,
	
	peer_finder:on_added_peer(IP_Address),

	io:format("strategy:add_peer~n",[]),
	{noreply, S#state{n_peers=N_Peers+1}};

handle_cast({remove_peer, IP_Address}, S) ->
	N_Peers = S#state.n_peers,
	
	peer_finder:on_removed_peer(IP_Address),

	io:format("strategy:remove_peer~n",[]),
	{noreply, S#state{n_peers=N_Peers-1}};

handle_cast({got_headers, Payload, Origin}, S) ->
	
	{N_Headers, _Rest} = protocol:read_var_int(Payload),
	io:format("~w headers comming from ~w~n",[N_Headers, Origin]),
	%{Header, _} = protocol:read_block_header(Rest),
	%io:format("\tthe first one is ~p~n",[Header]),

	blockchain:got_headers(Payload, Origin),
	% new headers are not incorporetad into the tree until the next update_tree

	if
		N_Headers == ?MAX_HEADERS_COUNT ->
			% try to obtain more headers
			blockchain:create_getheaders_job_on_update(
				tips,
				Origin
				);
		N_Headers <  ?MAX_HEADERS_COUNT ->
			% peer seems to send all the headers available
			% now we annouce the current view of the tree to the other peers
			blockchain:create_getheaders_job_on_update(
				exponential_sampling,
				{except, Origin}
				)
	end,

	{noreply, S};

handle_cast({got_getheaders, {_Version, HashStrs, StopHashStr}, Origin}, S) ->
	PeerTreeHashes = [protocol:hash(H) || H <- HashStrs],
	StopHash = protocol:hash(StopHashStr),
	Payload = blockchain:get_proposed_headers(PeerTreeHashes, 
		StopHash),
	
	case Payload of
		<<>> -> ok;
		_ -> jobs:add_job({Origin, {headers, Payload}, 60})
	end,
	{noreply, S};

handle_cast({got_addr, NetAddrs, Origin}, S) ->
	NetType = S#state.net_type,

	% When using local regtest mode, bitcoind sometimes returns addr message
	% that contains the host's global IP address. We convert it to the local
	% IP address.
	NetAddrs1 =
	case NetType of
		regtest ->
			{ok,Global} = application:get_env(my_global_address),
			{ok,Local } = application:get_env(my_local_address),
			lists:filtermap(fun({Time, Services, IP_Address, Port}) ->
				case IP_Address of
					Global -> {true, {Time, Services, Local, Port}};
					_ -> true
				end end, NetAddrs);
		_ -> NetAddrs
	end,
	
	lists:foreach(fun(N) -> peer_finder:update_peer(N) end, NetAddrs1),
	JobSpecs = [
		begin
			% always found
			{IP_Address, _UserAgent, ServicesFlag, _BestHeight,
				LastUseTime, _TotalUseDuration, _TotalInBytes, _TotalOutBytes,
				_LastError}
				= peer_finder:get_peer_info(IP_Address),
			AdvertisedTime =
			case LastUseTime of
				{new, Time} -> Time;
				Time -> Time
			end,
			Port =
			case NetType of
				regtest -> rules:default_port(S#state.net_type)+1;
				_ -> rules:default_port(S#state.net_type)
			end,
			{addr, {AdvertisedTime, ServicesFlag, IP_Address, Port}}
		end
		|| {_,_,IP_Address,_} <- NetAddrs1],
	lists:foreach(fun(J) -> jobs:add_job({{except,Origin},J,60*10}) end,
		JobSpecs),

	{noreply, S};

handle_cast({got_inv, InvVects, Origin}, S) ->
	_Mode = S#state.mode,

	InvVectsTx = [IV || {msg_tx, _HashStr}=IV <- InvVects],
	jobs:add_job({Origin, {getdata, InvVectsTx}, 5*60}),

	{noreply, S};

handle_cast({got_tx, Payload, Origin}, S) ->
	tx:add_to_mempool({tx, Payload}, Origin),
	
	{noreply, S}.


handle_info(check_n_peers, S) ->
	N_Peers = S#state.n_peers,
	Target_N_Peers = S#state.target_n_peers,

	if
		N_Peers < Target_N_Peers ->
			request_peer(S);
		true ->
			erlang:send_after(?CHECK_N_PEERS_INTERVAL, self(), check_n_peers),
			{noreply, S}
	end.


%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------
request_peer(S) ->
	io:format("strategy: request_peer~n",[]),
	NetType = S#state.net_type,

	case peer_finder:request_peer(new) of
		not_available ->
			io:format("not available~n",[]),
			ok;
		IP_Address ->
			Port = 
			case NetType of
				% for regtest we assign modified port number to bitcoind
				% The default port number is used by Moles.
				regtest -> rules:default_port(NetType)+1;
				_ -> rules:default_port(NetType)
			end,
			io:format("~w port=~w~n",[IP_Address,Port]),
			Ret = comm_sup:add_comm(NetType, {outgoing, {IP_Address,Port}}),
			io:format("comm_sup:add_comm returns ~p~n",[Ret])
	end,
	
	io:format("strategy:check_peer finished.~n",[]),
	erlang:send_after(?CHECK_N_PEERS_INTERVAL, self(), check_n_peers),
	{noreply, S}.


