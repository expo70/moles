%%
%% Blockchain service
%%
%% Blockchain is actually a tree.
%% This process tries to maintain the most plausible view of the blockchain
%% from obtain data.
%% Other pcocesses can use API to know what are missing now and how to
%% fill the gaps.
%%
-module(blockchain).
-compile(export_all).

-behaviour(gen_server).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

% APIs
-export([start_link/1,
	save_headers/2,
	collect_getheaders_hashes/1,
	get_floating_root_hashes/0
	]).

-include_lib("eunit/include/eunit.hrl").
-include("./include/constants.hrl").

-define(HEADER_SIZE, 81). % 80 + byte_size(var_int(0))
-define(TREE_UPDATE_INTERVAL, 10*1000).
-define(HEADERS_FILE_NAME, "headers.dat").


-record(state,
	{
		net_type,
		headers_file_path,
		new_entries,
		tid_tree,
		roots,
		leaves,
		tips
	}).


%% ----------------------------------------------------------------------------
%% gen_server callbacks
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	Args = [NetType],
	gen_server:start_link({local,?MODULE}, ?MODULE, Args, []).

save_headers(HeadersPayload, Origin) ->
	gen_server:cast(?MODULE, {save_headers, HeadersPayload, Origin}).

collect_getheaders_hashes(MaxDepth) ->
	gen_server:call(?MODULE, {collect_getheaders_hashes, MaxDepth}).

get_floating_root_hashes() ->
	gen_server:call(?MODULE, get_floating_root_hashes).


%% ----------------------------------------------------------------------------
%% gen_server callbacks
%% ----------------------------------------------------------------------------
init([NetType]) ->
	
	HeadersFileDir =
	case NetType of
		mainnet  -> "./mainnet/headers";
		testnet  -> "./testnet/headers";
		regtest  -> "./regtest/headers"
	end,
	
	ok = filelib:ensure_dir(HeadersFileDir++'/'),
	HeadersFilePath = filename:join(HeadersFileDir, ?HEADERS_FILE_NAME),

	InitialState = #state{
			net_type = NetType,
			headers_file_path = HeadersFilePath,
			new_entries = []
		},
	
	InitialState1 = load_headers_from_file(InitialState),
	
	erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree),
	{ok, InitialState1}.


handle_call({collect_getheaders_hashes, MaxDepth}, _From, S) ->
	case S#state.tid_tree of
		undefined -> {reply, not_ready, S};
		Tid ->
			GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
			Tips = S#state.tips,

			Advertise =
			case Tips of
				[ ] -> [[GenesisBlockHash]];
		 		_  -> [extended_tip_hashes(Tid, T, MaxDepth) || T <- Tips]
			end,
			{reply, Advertise, S}
	end;
handle_call(get_floating_root_hashes, _From, S) ->
	case S#state.tid_tree of
		undefined -> {reply, not_ready, S};
		_Tid ->
			Roots = S#state.roots,
			GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
			[Hash || {Hash,_,PrevHash,_} <- Roots,
				PrevHash =/= GenesisBlockHash]
	end.


%% for the paylod of headers message
%% We save headers that match the following conditions:
%% * has a hash that does not exist in the current table
%% * its hash satisfies its decleared difficulty (nBits)
handle_cast({save_headers, HeadersPayload, Origin}, S) ->
	Tid = S#state.tid_tree,
	HeadersFilePath = S#state.headers_file_path,
	%NOTE: the file is created if it does not exist.
	{ok,F} = file:open(HeadersFilePath,[write,binary,append]),

	SaveFunc = fun(HeaderBin) ->
		{{HashStr,PrevHashStr,_,_,_,DifficultyTarget,_,0},<<>>} =
			protocol:read_block_header(HeaderBin),
		Hash = protocol:hash(HashStr),
		PrevHash = protocol:hash(PrevHashStr),
		case ets:member(Tid, Hash) of
			false ->
				case Hash =< DifficultyTarget of
					true ->
						{ok,Position} = file:position(F, cur),
						ok = file:write(F, HeaderBin),
						{Hash,{headers,Position},PrevHash,[]};
					false ->
						{{error, not_satisfy_difficulty}, Origin, Hash}
				end;
			true -> {{error, already_have}, Origin, Hash}
		end
	end,

	NewEntries  = list:reverse(S#state.new_entries),
	NewEntries1 = for_each_header_chunk_from_payload(NewEntries,
		SaveFunc, HeadersPayload, Origin),
	file:close(F),

	{noreply, S#state{new_entries=NewEntries1}}.


handle_info(update_tree, S) ->
	NewEntries = S#state.new_entries,

	{NewEntriesNonError,NewEntriesWithError} =
	lists:partition(fun(X) ->
		case X of
			{<<_Hash:32/binary>>,_Index,<<_PrevHash:32/binary>>, []} -> true;
			_ -> false
		end
		end,
		NewEntries),
	
	case length(NewEntriesWithError) of
		0 -> ok;
		_ ->
			report_errornous_entries(NewEntriesWithError)
	end,

	case NewEntriesNonError of
		[ ] -> {noreply, S};
		 _  ->
		 	case S#state.tid_tree of
				undefined -> % do initialize
					S1 = initialize_tree(NewEntriesNonError, S),
					{noreply, S1#state{new_entries=[]}};
				_ ->
					S1 = update_tree(NewEntriesNonError, S),
					{noreply, S1#state{new_entries=[]}}
			end
	end.













%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------
initialize_tree(Entries, S) ->
	NetType = S#state.net_type,
	GenesisBlockHash = rules:genesis_block_hash(NetType),

	Tid = ets:new(blockchain_index, []),
	insert_new_entries(Tid, Entries, GenesisBlockHash),

	% the list of Entry whose PrevHash is not found in the table
	% including Block-1
	%NOTE: we can also use lists:foldl here
	Roots =
	ets:foldl(fun(Entry,AccIn) ->
		try_to_connect_floating_root(Tid,Entry,AccIn) end, [], Tid),

	Leaves = find_leaves(Tid),
	Tips = find_tips(Tid, Leaves, GenesisBlockHash),

	S#state{tid_tree=Tid, roots=Roots, leaves=Leaves, tips=Tips}.


% floating (non-connected) entry is added into AccIn
try_to_connect_floating_root(Tid, {Hash,_,PrevHash,_}=_Entry, AccIn) ->
	case ets:lookup(Tid, PrevHash) of
		[] -> [Hash|AccIn];
		[{PrevHash, Index, PrevPrevHash, PrevNextHashes}] ->
			% update the entry
			true = ets:insert(Tid,
			{PrevHash, Index, PrevPrevHash, [Hash|PrevNextHashes]}),
			AccIn
	end.


% When inserting the entries, we remove potential genesis blocks.
insert_new_entries(Tid, Entries, GenesisBlockHash) ->
	[ets:insert_new(Tid,E) ||
		{<<Hash:32/binary>>,_Index,<<PrevHash:32/binary>>,_NextHashes}=E
		<- Entries,
		PrevHash =/= ?HASH256_ZERO_BIN, Hash =/= GenesisBlockHash,
		Hash =/= PrevHash].


%% We assume that the number of NewEntries are usually much smaller than that of
%% existing entries in the table.
%% We also assume in this update function that there are only additinal changes.
update_tree(NewEntries, S) ->
	NetType = S#state.net_type,
	GenesisBlockHash = rules:genesis_block_hash(NetType),
	Tid = S#state.tid_tree,
	Leaves = S#state.leaves,
	Roots = S#state.roots,
	
	insert_new_entries(Tid, NewEntries, GenesisBlockHash),
	Roots1 =
	lists:foldl(fun(Entry,AccIn) ->
		try_to_connect_floating_root(Tid,Entry,AccIn) end, [],
		Roots ++ NewEntries),
	
	Leaves1 = lists:filter(fun(L)-> is_leafQ(Tid,L) end, Leaves ++ NewEntries),

	Tips = find_tips(Tid, Leaves, GenesisBlockHash),

	S#state{roots=Roots1, leaves=Leaves1, tips=Tips}.


find_leaves(Tid) ->
	ets:match_object(Tid, {'_','_','_',[]}).


is_leafQ(Tid, Hash) ->
	case ets:lookup(Tid, Hash) of
		[{Hash, _, _, NextHashes}] -> NextHashes =:= []
	end.


split_entries_by_fork_type(Tid) ->
	ets:foldl(fun({_,_,_,NextHashes}=Entry, {F0,F1,Fn}=_AccIn) ->
		case length(NextHashes) of
			0 -> {[Entry|F0],F1,       Fn};
			1 -> { F0,      [Entry|F1],Fn};
			_ -> { F0,       F1,      [Entry|Fn]}
		end end, {[],[],[]}, Tid).


find_root_of_leaf(Tid, Leaf) -> find_root_of_leaf(1, Tid, Leaf).

find_root_of_leaf(Height, Tid, {_,_,PrevHash,_}=Entry) ->
	case ets:lookup(Tid, PrevHash) of
		[] ->
			{Height, Entry};
		[PrevEnt] ->
			find_root_of_leaf(Height+1, Tid, PrevEnt)
	end.


%% Tip is the highest leaf among leaves whose roots are the genesis block.
%% There can be multiple tips.
%%
find_tips(Tid, Leaves, GenesisBlockHash) ->
	RootInfos   = [{L,find_root_of_leaf(Tid, L)} || L <- Leaves],
	RootHeights = [{Height,L}
		|| {L,{Height,{_,_,PrevHash,_}}} 
		<- RootInfos, PrevHash=:=GenesisBlockHash],
	case RootHeights of
		[ ] -> [];
		 _  ->
			SortedRootHeights = lists:sort(fun({H1,_},{H2,_})-> H1 >= H2 end, 
				RootHeights),
			{TopHeight,_} = hd(SortedRootHeights),
			lists:takewhile(fun({H,_}) -> H==TopHeight end, SortedRootHeights)
	end.


extended_tip_hashes(Tid, {Height,TipEntry}=_Tip, MaxLength) ->
	Length = max(Height,MaxLength),
	collect_hash_loop([], Tid, TipEntry, Length).
	
% move down the tree
collect_hash_loop(Acc, _, Entry, 1) -> lists:reverse([Entry|Acc]);
collect_hash_loop(Acc, Tid, {_,_,PrevHash,_}=Entry, Length)
	when is_integer(Length) andalso Length>1 ->
	
	[PrevEntry] = ets:lookup(Tid, PrevHash),
	collect_hash_loop([Entry|Acc], Tid, PrevEntry, Length-1).


% Required difficulty for tblocks should depend on their 
% height and time in tree. 
%check_difficulty_order(Tid) ->
%	.


remove_entry_from_the_tree({Hash,_,PrevHash,NextHashes}=Entry, S) ->
	GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
	Tid = S#state.tid_tree,
	Roots = S#state.roots,
	Leaves = S#state.leaves,

	ets:delete(Tid, Hash),

	{Roots1, Leaves1} =
	case ets:lookup(Tid, PrevHash) of
		[{PrevHash,Index,PrevPrevHash,PrevNextHashes}] ->
			ets:insert({PrevHash,Index,PrevPrevHash,
				lists:delete(Hash,PrevNextHashes)}), % update
			{Roots, Leaves};
		[] -> % root
			{lists:delete(Entry, Roots), Leaves}
	end,

	{Roots2, Leaves2} =
	case NextHashes of
		[ ] -> % leaf
			{Roots1, lists:delete(Entry, Leaves1)};
		 _ ->
		 	{Roots1 ++ [E || [E] <- [ets:lookup(Tid,NH) || NH <- NextHashes]],
				Leaves1}
	end,

	Tips = find_tips(Tid, Leaves2, GenesisBlockHash),

	S#state{roots=Roots2, leaves=Leaves2, tips=Tips}.


load_headers_from_file(S) ->
	HeadersFilePath = S#state.headers_file_path,
	NewEntries = S#state.new_entries,

	case u:file_existsQ(HeadersFilePath) of
		true ->
			{ok,F} = file:read_file(HeadersFilePath),
			
			NewEntries1 = read_header_chunk_loop(lists:reverse(NewEntries),F),
			file:close(F),

			io:format("~wnew entries were loaded.~n",[length(NewEntries1)]),
			S#state{new_entries=NewEntries1};
		false -> S
	end.

read_header_chunk_loop(Acc, F) ->
	{ok,Position} = file:possition(F, cur),

	case file:read(F, ?HEADER_SIZE) of
		{ok,Bin} ->
			{{HashStr,PrevHashStr,_,_,_,_,_,0},<<>>} =
			protocol:read_block_header(Bin),
			Entry = {
				protocol:hash(HashStr),
				{headers,Position},
				protocol:hash(PrevHashStr),
				[]},
			read_header_chunk_loop([Entry|Acc], F);
		eof -> list:reverse(Acc)
	end.


for_each_header_chunk_from_payload(Acc, _, <<>>, _) -> lists:reverse(Acc);
for_each_header_chunk_from_payload(Acc, ProcessHeaderFunc,
	HeadersPayload, Origin) ->
	<<HeaderBin:?HEADER_SIZE/binary, Rest/binary>> = HeadersPayload,
	
	Result =
	try ProcessHeaderFunc(HeaderBin) of
		Any -> Any
	catch
		Class:Reason -> {{Class,Reason}, Origin, HeaderBin}
	end,
	
	for_each_header_chunk_from_payload([Result|Acc],
		ProcessHeaderFunc, Rest, Origin).


report_errornous_entries(Entries) ->
	io:format("reporting ~w errornous header entries:~n", [length(Entries)]),
	io:format("~w~n", [Entries])
	.


