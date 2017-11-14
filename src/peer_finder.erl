-module(peer_finder).

-behaviour(gen_server).

-define(PEERS_FILE_NAME, "peers.dat").


% API
-export([start_link/1,
	request_peer/1, update_peer/1, new_peer/1, register_peer/1, find_peer/1]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).


-record(state,{
	net_type,
	dns_servers,
	tid_peers,
	peers_file_path,
	tid_peers_used
	}).


% peers table entry
% {IP_Address, UserAgent, ServicesFlag, BestHeight,
%	LastUseTime, TotalUseDuration, TotalInBytes, TotalOutBytes}


%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	Args = [NetType],
	gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

request_peer(Priority) ->
	gen_server:call(?MODULE, {request_peer, Priority}).

find_peer(IP_Address) ->
	gen_server:call(?MODULE, {find_peer, IP_Address}).

update_peer(PeerInfo) ->
	gen_server:cast(?MODULE, {update_peer, PeerInfo}).

new_peer(IP_Address) ->
	gen_server:cast(?MODULE, {new_peer, IP_Address}).

register_peer(PeerInfo) ->
	gen_server:cast(?MODULE, {register_peer, PeerInfo}).


%% ----------------------------------------------------------------------------
%% gen_server callbaks
%% ----------------------------------------------------------------------------
init([NetType]) ->
	PeersFileDir =
	case NetType of
		mainnet  -> "./mainnet/peers";
		testnet  -> "./testnet/peers";
		regtest  -> "./regtest/peers"
	end,
	
	ok = filelib:ensure_dir(PeersFileDir++'/'),
	PeersFilePath = filename:join(PeersFileDir, ?PEERS_FILE_NAME),
	case u:file_existsQ(PeersFilePath) of
		true ->
			{ok,Tid} = ets:file2tab(PeersFilePath);
		false ->
			Tid = ets:new(peers, [])
	end,
	
	InitialStatus = #state{
		net_type = NetType,
		dns_servers = dns_servers(NetType),
		tid_peers = Tid,
		peers_file_path = PeersFilePath,
		tid_peers_used = ets:new(peers_used, [])
	},
	
	gen_server:cast(?MODULE, {dns_seeds, InitialStatus}),
	{ok, not_initialized_yet}.


%% 
%% Priority = new | 
%% 
handle_call({request_peer, new=_Priority}, _From, S) ->
	Tid = S#state.tid_peers,
	TidPeersUsed = S#state.tid_peers_used,

	%FIXME, now only supports Priority = new
	Matches = ets:match(Tid, {'$1','_','_','_',{new,'_'},'_','_','_'}),
	IPs = [IP || [IP] <- Matches, not ets:member(TidPeersUsed, IP)],

	case IPs of
		[ ] -> {reply, not_available, S};
		 _  ->
		 	Reply = hd(IPs),
			ets:insert(TidPeersUsed, {Reply}),
			{reply, Reply, S}
	end;
handle_call({find_peer, IP_Address}, _From, S) ->
	Tid = S#state.tid_peers,

	Reply =
	case ets:lookup(Tid, IP_Address) of
		[] -> not_found;
		[PeerInfo] -> PeerInfo
	end,

	{reply, Reply, S}.


handle_cast({dns_seeds, S}, _S) ->
	NetType = S#state.net_type,
	Tid = S#state.tid_peers,
	DNS_Servers = S#state.dns_servers,
	
	IPs = 
	case NetType of
		mainnet -> ns_lookup(hd(DNS_Servers), in, a);
		testnet -> ns_lookup(hd(DNS_Servers), in, a);
		regtest -> [{127,0,0,1}]
	end,
	Time = erlang:system_time(second),

	lists:foreach(fun(P) -> add_new_peer(P, {new, Time}, Tid) end, IPs),

	{noreply, S#state{dns_servers=u:list_rotate_left1(DNS_Servers)}};
handle_cast({update_peer,{IP_Address, UserAgent, ServicesFlag, BestHeight,
	LastUseTime, TotalUseDuration, TotalInBytes, TotalOutBytes}=PeerInfo}, S) ->
	
	Tid = S#state.tid_peers,

	case ets:lookup(Tid, IP_Address) of
		[] -> ets:insert_new(Tid, PeerInfo);
		[{IP_Address, _, _, _, _,
			OldTotalUseDuration, OldTotalInBytes, OldTotalOutBytes}] ->
			%FIXME, avoid summing totals again
			ets:insert(Tid, {IP_Address, UserAgent, ServicesFlag, BestHeight,
				LastUseTime,
				OldTotalUseDuration + TotalUseDuration,
				OldTotalInBytes + TotalInBytes,
				OldTotalOutBytes + TotalOutBytes})
	end,
	
	S1 = save_peers(S),
	{noreply, S1};
handle_cast({new_peer, IP_Address},S) ->
	Tid = S#state.tid_peers,
	TidPeersUsed = S#state.tid_peers_used,

	ets:insert(TidPeersUsed, {IP_Address}),

	case ets:lookup(Tid, IP_Address) of
		[ ] -> add_new_peer(IP_Address, erlang:system_time(second), Tid);
		 _  -> ok
	end,

	{noreply, S};
handle_cast({register_peer, {IP_Address,_,_,_,_,_,_,_}=PeerInfo}, S) ->
	
	Tid = S#state.tid_peers,

	case ets:lookup(Tid, IP_Address) of
		[ ] -> ets:insert_new(Tid, PeerInfo);
		 _  -> ok
	end,
	
	{noreply, S}.


handle_info(_Info, S) ->
	{noreply, S}.



%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------
ns_lookup(Name, Class, Type) ->
	case inet_res:resolve(Name, Class, Type) of
		{ok,Msg} ->
			[inet_dns:rr(RR, data)
			|| RR <- inet_dns:msg(Msg, anlist),
				inet_dns:rr(RR, type) =:= Type,
				inet_dns:rr(RR, class) =:= Class];
		{error,_} ->
			[]
	end.


add_new_peer(IP_Address, TimeSpec, Tid) ->
	NewEntry = {IP_Address,
		undefined,
		undefined,
		undefined,
		TimeSpec,
		0,0,0},

	case ets:lookup(Tid, IP_Address) of
		[] ->
			ets:insert_new(Tid, NewEntry);
		[{IP_Address, _, _, _, {new, _}, _, _, _}] ->
			ets:insert(Tid, NewEntry); % update
		[_Entry] ->
			ok
	end.


save_peers(S) ->
	Tid = S#state.tid_peers,
	PeersFilePath = S#state.peers_file_path,

	io:format("peers data saving ...~n",[]),
	ok = ets:tab2file(Tid, PeersFilePath),
	S.


dns_servers(testnet) -> [
	"testnet-seed.bitcoin.schildbach.de"
	];
dns_servers(regtest) -> [].
