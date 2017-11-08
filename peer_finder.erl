-module(peer_finder).

-behaviour(gen_server).

-define(PEERS_FILE_NAME, "peers.dat").


% API
-export([start_link/1, request_peer/1, update_peer/2]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).


-record(status,{
	net_type,
	dns_servers,
	tid_peers,
	peers_file_path,
	tid_peers_used
	}).


% peers table entry
% {IP_Address, UserAgent, ServicesFlag,
%	LastUseTime, TotalUseDuration, TotalInBytes, TotalOutBytes}


%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	Args = [NetType],
	gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

request_peer(Priority) ->
	gen_server:call(?MODULE, {request_peer, Priority}).

update_peer(Address, PeerInfo) ->
	gen_server:cast(?MODULE, {update_peer, Address, PeerInfo}).



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
	
	InitialStatus = #status{
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
handle_call({request_peer, _Priority}, _From, S) ->
	Tid = S#status.tid_peers,
	TidPeersUsed = S#status.tid_peers_used,

	%FIXME, now only supports Priority = new
	Matches = ets:match(Tid, {'$1','_','_',{new,'_'},'_','_','_'}),
	IPs = [IP || [IP] <- Matches, not ets:member(TidPeersUsed, IP)],

	case IPs of
		[ ] -> {reply, not_available, S};
		 _  ->
		 	Reply = hd(IPs),
			ets:insert(TidPeersUsed, {Reply}),
			{reply, Reply, S}
	end.


handle_cast({dns_seeds, S}, _S) ->
	Tid = S#status.tid_peers,
	DNS_Servers = S#status.dns_servers,
	
	IPs = ns_lookup(hd(DNS_Servers), in, a),
	Time = erlang:system_time(second),

	lists:foreach(fun(P) -> add_new_peer(P, {new, Time}, Tid) end, IPs),

	{noreply, S#status{dns_servers=u:list_rotate_left1(DNS_Servers)}};
handle_cast({update_peer,{IP_Address, UserAgent, ServicesFlag, LastUseTime,
	TotalUseDuration, TotalInBytes, TotalOutBytes}=PeerInfo}, S) ->
	
	Tid = S#status.tid_peers,
	TidPeersUsed = S#status.tid_peers_used,

	ets:insert(TidPeersUsed, {IP_Address}),

	case ets:lookup(Tid, IP_Address) of
		[] -> ets:insert_new(PeerInfo);
		[{IP_Address, _, _, _,
			OldTotalUseDuration, OldTotalInBytes, OldTotalOutBytes}] ->
			%FIXME, avoid summing totals again
			ets:insert(Tid, {IP_Address, UserAgent, ServicesFlag, LastUseTime,
				OldTotalUseDuration + TotalUseDuration,
				OldTotalInBytes + TotalInBytes,
				OldTotalOutBytes + TotalOutBytes})
	end,
	
	{noreply, S}.


handle_info(_Info, S) ->
	{noreply, S}.


terminate(_Reason, S) ->
	Tid = S#status.tid_peers,
	PeersFilePath = S#status.peers_file_path,

	ets:tab2file(Tid, PeersFilePath).


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


add_new_peer(IP_Address, {new, Time}, Tid) ->
	NewEntry = {IP_Address,
		undefined,
		undefined,
		{new, Time},
		0,0,0},

	case ets:lookup(Tid, IP_Address) of
		[] ->
			ets:insert_new(Tid, NewEntry);
		[{IP_Address, _, _, {new, _}, _, _, _}] ->
			ets:insert(Tid, NewEntry); % update
		[_Entry] ->
			ok
	end.


dns_servers(testnet) -> [
	"testnet-seed.bitcoin.schildbach.de"
	].
