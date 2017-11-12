%%
-module(strategy).

-behaviour(gen_server).

-record(state,
	{
		net_type,
		mode,
		target_n_peers,
		n_peers,
		best_height
	}).

%% API
-export([start_link/1, add_peer/1, remove_peer/1, get_best_height/0, 
	got_headers/2, got_getheaders/2]).

%% gen_server callbak
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHECK_N_PEERS_INTERVAL, 60*1000).


%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	gen_server:start_link({local,?MODULE}, ?MODULE, [NetType], []).

add_peer(IP_Address) ->
	gen_server:cast(?MODULE, {add_peer, IP_Address}).

remove_peer(PeerInfo) ->
	gen_server:cast(?MODULE, {remove_peer, PeerInfo}).

get_best_height() ->
	gen_server:call(?MODULE, get_best_height).

got_headers(Payload, Origin) ->
	gen_server:cast(?MODULE, {got_headers, Payload, Origin}).

got_getheaders(Payload, Origin) ->
	gen_server:cast(?MODULE, {got_getheaders, Payload, Origin}).


%% ----------------------------------------------------------------------------
%% gen_server callback
%% ----------------------------------------------------------------------------
init([NetType]) ->
	BestHeight = blockchain:get_best_height(),
	
	InitialState = #state{
		net_type = NetType,
		mode = header_first,
		target_n_peers = 1,
		n_peers = 0,
		best_height = BestHeight
	},
	
	erlang:send_after(?CHECK_N_PEERS_INTERVAL, self(), check_n_peers),
	{ok, InitialState}.


handle_call(get_best_height, _From, S) ->
	{reply, S#state.best_height, S}.


handle_cast({add_peer, IP_Address}, S) ->
	Mode = S#state.mode,
	N_Peers = S#state.n_peers,
	
	case Mode of
		header_first ->
			MaxDepth = 5,
			case blockchain:collect_getheaders_hashes(MaxDepth) of
				not_ready -> ok;
				ListOfList ->
					[jobs:add_job(
					{IP_Address, {getheaders,Hashes}, 60}) 
					|| Hashes <- ListOfList]
			end
	end,
	
	{noreply, S#state{n_peers=N_Peers+1}};
handle_cast({remove_peer, PeerInfo}, S) ->
	N_Peers = S#state.n_peers,

	peer_finder:update_peer(PeerInfo),
	{noreply, S#state{n_peers=N_Peers-1}};
handle_cast({got_headers, Payload, Origin}, S) ->
	
	blockchain:save_headers(Payload, Origin),

	{noreply, S};
handle_cast({got_getheaders, Payload, Origin}, S) ->
	
	{_Version, Hashes, StopHash} = protocol:parse_getheaders(Payload),
	
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
	NetType = S#state.net_type,

	case peer_finder:request_peer(new) of
		not_available -> ok;
		IP_Address ->
			supervisor:add_comm(NetType, {outgoing, IP_Address}) 
	end,
	
	erlang:send_after(?CHECK_N_PEERS_INTERVAL, self(), check_n_peers),
	{noreply, S}.


