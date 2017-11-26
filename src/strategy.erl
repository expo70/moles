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
		n_peers_reached_tip,
		best_height
	}).

%% API
-export([start_link/1,
	get_n_peers/0,
	add_peer/1, remove_peer/1,
	got_headers/2, got_getheaders/2, got_addr/2, got_inv/2, got_tx/2]).

%% gen_server callbak
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHECK_N_PEERS_INTERVAL, 30*1000).
-define(ADVERTISE_TIP_INTERVAL, 60*1000).


%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	gen_server:start_link({local,?MODULE}, ?MODULE, [NetType], []).

get_n_peers() ->
	gen_server:call(?MODULE, get_n_peers).

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
		n_peers_reached_tip = 0,
		best_height = BestHeight
	},
	
	erlang:send_after(200, self(), check_n_peers), % start accessing peers
	{ok, InitialState}.


handle_call(get_n_peers, _From, S) ->
	Target_N_Peers = S#state.target_n_peers,
	       N_Peers = S#state.n_peers,
	
	Reply = {N_Peers, Target_N_Peers},
	{reply, Reply, S}.


handle_cast({add_peer, IP_Address}, S) ->
	Mode = S#state.mode,
	N_Peers = S#state.n_peers,
	
	case Mode of
		header_first1 ->
			MaxDepth = 5,
			case blockchain:collect_getheaders_hashes(MaxDepth) of
				not_ready -> ok;
				ListOfList ->
					[jobs:add_job(
					{IP_Address, {getheaders,Hashes}, 60})
					|| Hashes <- ListOfList]
			end;
		header_first ->
			{A,P} = {0.75,0.08},
			case blockchain:collect_getheaders_hashes_exponential({A,P}) of
				not_ready -> ok;
				Hashes ->
					Hashes1 = lists:sublist(Hashes,?MAX_HEADERS_COUNT),
					jobs:add_job({IP_Address, {getheaders,Hashes1}, 60})
			end;
		tip_on_header ->
			ok % do nothing
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

	S1 =
	if
		N_Headers == ?MAX_HEADERS_COUNT ->
			% try to obtain more headers
			blockchain:create_getheaders_job_on_update(
				tips,
				Origin
				),
			S;
		N_Headers <  ?MAX_HEADERS_COUNT ->
			% peer seems to send all the headers available
			% now we annouce the current view of the tree to the other peers
			blockchain:create_getheaders_job_on_update(
				exponential_sampling,
				{except, Origin}
				),

			% update strategy depending on the getheaders returns
			% FIXME: when some peers do not respond getheaders command for
			% a long time, strategy may be left unchanged.
			Mode = S#state.mode,
			N_PeersReachedTip1 = S#state.n_peers_reached_tip +1,
			Target_N_Peers = S#state.target_n_peers,
			{Mode1, Target_N_Peers1} =
			case Mode of
				header_first ->
					if
						N_PeersReachedTip1 == 1 ->
							{header_first, Target_N_Peers*2};
						N_PeersReachedTip1 <  3 ->
							{header_first, Target_N_Peers}; % not change
						N_PeersReachedTip1 >= 3 ->
							io:format("strategy: mode change (tip_on_header)~n",
								[]),

							erlang:send_after(?ADVERTISE_TIP_INTERVAL, self(),
								advertise_tip),
							{tip_on_header, Target_N_Peers+2}
					end;
				_ -> {Mode, Target_N_Peers}
			end,
			
			S#state{
				n_peers_reached_tip = N_PeersReachedTip1,
				target_n_peers = Target_N_Peers1,
				mode = Mode1
			}
	end,

	{noreply, S1};

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
	lists:foreach(fun(J) -> jobs:add_job({{except,Origin},J,60}) end,
		JobSpecs),

	{noreply, S};

handle_cast({got_inv, InvVects, Origin}, S) ->
	Mode = S#state.mode,

	case Mode of
		header_first -> ok;
		_ -> %FIXME
			InvVectsTx = [IV || {msg_tx, _HashStr}=IV <- InvVects],
			jobs:add_job({Origin, {getdata, InvVectsTx}, 30})
	end,

	{noreply, S};

handle_cast({got_tx, Payload, Origin}, S) ->
	tx:add_to_mempool({tx, Payload}, Origin),
	view:got_tx(),
	
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
	end;

handle_info(advertise_tip, S) ->
	blockchain:create_getheaders_job_on_update(
		tips,
		all
	),
	
	erlang:send_after(?ADVERTISE_TIP_INTERVAL, self(), advertise_tip), % repeat
	{noreply, S}.


%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------
request_peer(S) ->
	io:format("strategy: request_peer~n",[]),
	NetType = S#state.net_type,

	IP_Address =
	case peer_finder:request_peer(new) of
		not_available ->
			peer_finder:request_peer(newer);
		Any -> Any 
	end,

	case IP_Address of
		not_available ->
			io:format("\tnot available~n",[]),
			ok;
		_ ->		
			Port = 
			case NetType of
				% for regtest we assign modified port number to bitcoind
				% The default port number is used by Moles.
				regtest -> rules:default_port(NetType)+1;
				_ -> rules:default_port(NetType)
			end,
			io:format("~w port=~w~n",[IP_Address,Port]),
			comm_sup:add_comm(NetType, {outgoing, {IP_Address,Port}})
	end,
	
	erlang:send_after(?CHECK_N_PEERS_INTERVAL, self(), check_n_peers),
	{noreply, S}.


