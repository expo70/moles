-module(peer_finder).

-behaviour(gen_server).

-define(PEERS_FILE_NAME, "peers.dets").


% API
-export([start_link/1,
	request_peer/1, update_peer/1, get_peer_info/1, update_peer_last_error/2,
	check_now_in_use/1, on_added_peer/1, on_removed_peer/1]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).


-record(state,{
	net_type,
	dns_servers,
	ref_peers,
	peers_file_path,
	tid_peers_in_use
	}).


% peers table entry (PeerInfo)
% {IP_Address, UserAgent, ServicesFlag, BestHeight, LastUseTime,
%	TotalUseDuration, TotalInBytes, TotalOutBytes, LastError}


%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	Args = [NetType],
	gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

request_peer(Priority) ->
	% assigned longer call timeout value for potential calls
	% before async-init DNS seeding finishes, which usually takes
	% a fair amount time.
	gen_server:call(?MODULE, {request_peer, Priority}, 15*1000).

get_peer_info(IP_Address) ->
	gen_server:call(?MODULE, {get_peer_info, IP_Address}).

check_now_in_use(IP_Address) ->
	gen_server:call(?MODULE, {check_now_in_use, IP_Address}).

on_added_peer(IP_Address) ->
	gen_server:cast(?MODULE, {on_added_peer, IP_Address}).

on_removed_peer(IP_Address) ->
	gen_server:cast(?MODULE, {on_removed_peer, IP_Address}).

update_peer(PeerInfo_Or_NetAddr) ->
	gen_server:cast(?MODULE, {update_peer, PeerInfo_Or_NetAddr}).

update_peer_last_error(IP_Address, Error) ->
	gen_server:cast(?MODULE, {update_peer_last_error, IP_Address, Error}).


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
	% database file will be created when it does not exist
	{ok, RefPeers} = dets:open_file(peers, [{file, PeersFilePath}]),
	
	InitialStatus = #state{
		net_type = NetType,
		dns_servers = dns_servers(NetType),
		ref_peers = RefPeers,
		peers_file_path = PeersFilePath,
		tid_peers_in_use = ets:new(peers_in_use, [])
	},
	
	gen_server:cast(?MODULE, {dns_seeds, InitialStatus}),
	{ok, InitialStatus}.


%% 
%% Priority = new | 
%% 
handle_call({request_peer, new=_Priority}, _From, S) ->
	Ref = S#state.ref_peers,
	TidPeersInUse = S#state.tid_peers_in_use,

	%FIXME, now only supports Priority = new
	Matches = dets:match(Ref, {'$1','_','_','_',{new,'_'},'_','_','_','_'}),
	IPs = [IP || [IP] <- Matches, not ets:member(TidPeersInUse, IP)],

	case IPs of
		[ ] -> {reply, not_available, S};
		 _  ->
		 	Reply = hd(IPs),
			ets:insert(TidPeersInUse, {Reply}),
			{reply, Reply, S}
	end;

handle_call({get_peer_info, IP_Address}, _From, S) ->
	Ref = S#state.ref_peers,

	Reply =
	case dets:lookup(Ref, IP_Address) of
		[] -> not_found;
		[PeerInfo] -> PeerInfo
	end,

	{reply, Reply, S};

handle_call({check_now_in_use, IP_Address}, _From, S) ->
	TidPeersInUse = S#state.tid_peers_in_use,

	NowInUseQ =
	case ets:lookup(TidPeersInUse, IP_Address) of
		[] -> false;
		[_] -> true
	end,

	{reply, NowInUseQ, S}.


handle_cast({on_added_peer, IP_Address},S) ->
	Ref = S#state.ref_peers,
	TidPeersInUse = S#state.tid_peers_in_use,

	ets:insert(TidPeersInUse, {IP_Address}),

	case dets:lookup(Ref, IP_Address) of
		[ ] -> add_new_peer(IP_Address, erlang:system_time(second), Ref);
		 _  -> ok
	end,

	{noreply, S};

handle_cast({on_removed_peer, IP_Address},S) ->
	TidPeersInUse = S#state.tid_peers_in_use,
	
	ets:delete(TidPeersInUse, {IP_Address}),

	{noreply, S};

handle_cast({dns_seeds, S}, _S) ->
	NetType = S#state.net_type,
	Ref = S#state.ref_peers,
	DNS_Servers = S#state.dns_servers,
	
	IPs = 
	case NetType of
		mainnet -> ns_lookup(hd(DNS_Servers), in, a);
		testnet -> ns_lookup(hd(DNS_Servers), in, a);
		regtest -> [{127,0,0,1}]
	end,
	Time = erlang:system_time(second),
	lists:foreach(fun(P) -> add_new_peer(P, {new, Time}, Ref) end, IPs),
	
	{noreply, S#state{dns_servers=u:list_rotate_left1(DNS_Servers)}};

% NetAddr = {Time,
% 	parse_services(Services),
%	parse_ip_address(IPAddress),
%	Port}
handle_cast({update_peer, {Time, Services, IP_Address, _Port}=_NetAddr}, S) ->
	Ref = S#state.ref_peers,

	case dets:lookup(Ref, IP_Address) of
		[] ->
			PeerInfo = {IP_Address, undefined, Services, undefined, Time,
				0, 0, 0, normal},
			true = dets:insert_new(Ref, PeerInfo);
		[{IP_Address, UserAgent, _OldServices, BestHeight, OldLastUseTime,
			TotalUseDuration, TotalInBytes, TotalOutBytes, LastError}] ->
			
			Time1 =
			case OldLastUseTime of
				{new,_T} -> Time;
				T -> max(T, Time)
			end,	
			
			PeerInfo = {IP_Address, UserAgent, Services, BestHeight, Time1,
				TotalUseDuration, TotalInBytes, TotalOutBytes, LastError},
			dets:insert(Ref, PeerInfo) % update
	end,

	{noreply, S};

handle_cast({update_peer, {IP_Address, UserAgent, ServicesFlag, BestHeight,
	LastUseTime, TotalUseDuration, TotalInBytes, TotalOutBytes, LastError}
	=PeerInfo}, S) ->
	Ref	= S#state.ref_peers,

	case dets:lookup(Ref, IP_Address) of
		[] -> dets:insert_new(Ref, PeerInfo);
		[{IP_Address, _, _, _, _,
			OldTotalUseDuration, OldTotalInBytes, OldTotalOutBytes,_}] ->
			dets:insert(Ref, {IP_Address, UserAgent, ServicesFlag, BestHeight,
				LastUseTime,
				OldTotalUseDuration + TotalUseDuration,
				OldTotalInBytes + TotalInBytes,
				OldTotalOutBytes + TotalOutBytes,
				LastError})
	end,
	
	{noreply, S};

handle_cast({update_peer_last_error, IP_Address, Error}, S) ->
	Ref = S#state.ref_peers,

	case dets:lookup(Ref, IP_Address) of
		[] -> ok;
		[{IP_Address,UserAgent,Services,BestHeight,TimeSpec,
			TotalUseDuration, TotalInBytes, TotalOutBytes, _}]->
		
			PeerInfo = {IP_Address, UserAgent, Services, BestHeight, TimeSpec,
				TotalUseDuration, TotalInBytes, TotalOutBytes, Error},
			dets:insert(Ref, PeerInfo) % update
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


add_new_peer(IP_Address, TimeSpec, Ref) ->
	NewEntry = {IP_Address,
		undefined,
		undefined,
		undefined,
		TimeSpec,
		0,0,0,normal},

	case dets:lookup(Ref, IP_Address) of
		[] ->
			true = dets:insert_new(Ref, NewEntry);
		[{IP_Address, _, _, _, {new, _}, _, _, _, _}] ->
			dets:insert(Ref, NewEntry); % update
		[_Entry] ->
			ok
	end.


dns_servers(testnet) -> [
	"testnet-seed.bitcoin.schildbach.de"
	];
dns_servers(regtest) -> [].
