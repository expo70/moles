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
-include_lib("eunit/include/eunit.hrl").


-behaviour(gen_server).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

% APIs
-export([start_link/1,
	save_headers/2,
	collect_getheaders_hashes/1,
	collect_getheaders_hashes_exponential/1,
	get_floating_root_hashes/0,
	get_best_height/0,
	get_proposed_headers/2
	]).

-include_lib("eunit/include/eunit.hrl").
-include("../include/constants.hrl").

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

collect_getheaders_hashes_exponential({A,P}) ->
	gen_server:call(?MODULE, {collect_getheaders_hashes_exponential, {A,P}}).

get_floating_root_hashes() ->
	gen_server:call(?MODULE, get_floating_root_hashes).

get_best_height() ->
	gen_server:call(?MODULE, get_best_height).

get_proposed_headers(PeerTreeHashes, StopHash) ->
	gen_server:call(?MODULE,
		{get_proposed_headers, PeerTreeHashes, StopHash}).


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
	
	InitialState1 = load_entries_from_file(InitialState),
	% blocking
	{_, InitialState2} = handle_info(update_tree, InitialState1),
	%erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree),
	{ok, InitialState2}.


handle_call({collect_getheaders_hashes, MaxDepth}, _From, S) ->
	GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
	
	case S#state.tid_tree of
		undefined -> %{reply, not_ready, S};
			{reply, [[GenesisBlockHash]], S};
		Tid ->
			Tips = S#state.tips,

			Advertise =
			case Tips of
				[ ] -> [[GenesisBlockHash]];
		 		 _  -> [extended_tip_hashes(Tid, T, MaxDepth) || T <- Tips]
			end,
			{reply, Advertise, S}
	end;
handle_call({collect_getheaders_hashes_exponential, {A,P}}, _From, S) ->
	case S#state.tid_tree of
		undefined -> {reply, not_ready, S};
		Tid ->
			GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
			Tips = S#state.tips,

			case Tips of
				[ ] -> {reply, [GenesisBlockHash], S};
				 _  ->
				 	Tip = hd(Tips),
					Tips1 = u:rotte_list_left1(Tips),
				 	Advertise = exponentially_sampled_hashes(Tid, Tip, {A,P}),
					{reply, Advertise, S#state{tips=Tips1}}
			end
	end;
handle_call(get_floating_root_hashes, _From, S) ->
	case S#state.tid_tree of
		undefined -> {reply, not_ready, S};
		_Tid ->
			Roots = S#state.roots,
			GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
			[Hash || {Hash,_,PrevHash,_} <- Roots,
				PrevHash =/= GenesisBlockHash]
	end;
handle_call(get_best_height, _From, S) ->
	case S#state.tid_tree of
		undefined -> {reply, 0, S};
		_Tid ->
			case S#state.tips of
				[] -> {reply, 0, S};
				[{Height,_Leaf}|_T] -> {reply, Height, S}
			end
	end;
handle_call({get_proposed_headers, PeerTreeHashes, StopHash},
	_From, S) ->
	Tid = S#state.tid_tree,
	Tips = S#state.tips,

	case Tips of
		[ ] -> {reply, <<>>, S};
		 _  ->
		 	Entries =
		 	case find_first_common_entry(PeerTreeHashes, Tid) of
				not_found ->
					{_H, TipEntry} = hd(Tips),
					NetType = S#state.net_type,
					GenesisBlockHash = rules:genesis_block_hash(NetType),
					lists:reverse(go_down_tree_before(TipEntry, 
						GenesisBlockHash, Tid));
				Entry ->
					{_H, TipEntry} = hd(Tips),
					climb_tree_until(Entry, TipEntry, Tid)
			end,
			Entries1 = lists:sublist(Entries,rules:max_headers_counts()),
			Entries2 =
			case StopHash of
				?HASH256_ZERO_BIN -> Entries1;
				_ -> u:take_until(fun({Hash,_,_,_})-> Hash=:=StopHash end,
					Entries1)
			end,

			HeadersPayload = load_headers_from_file(indexes(Entries2), S),
			
			Tips1 = u:list_rotate_left1(Tips),
			{reply, HeadersPayload, S#state{tips=Tips1}}
	end.


%% for the paylod of headers message
%% We save headers that match the following conditions:
%% * has a hash that does not exist in the current table
%% * its hash satisfies its decleared difficulty (nBits)
handle_cast({save_headers, HeadersPayload, Origin}, S) ->
	Tid = S#state.tid_tree, %NOTE, meybe undefined
	HeadersFilePath = S#state.headers_file_path,

	{_N_Headers, Rest} = protocol:read_var_int(HeadersPayload),

	%NOTE: the file is created if it does not exist.
	{ok,F} = file:open(HeadersFilePath,[write,binary,append]),

	NewEntries  = lists:reverse(S#state.new_entries),
	NewEntries1 = for_each_header_chunk_from_bin(NewEntries,
		fun save_header_func/3, Rest, Origin, {F,Tid}),

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

	S1 = case NewEntriesNonError of
		[ ] -> S;
		 _  ->
		 	case S#state.tid_tree of
				undefined -> % do initialize
					initialize_tree(NewEntriesNonError, S),
					S#state{new_entries=[]};
				_ ->
					update_tree(NewEntriesNonError, S),
					S#state{new_entries=[]}
			end
	end,

	io:format("blockchain:update_tree finished.~n",[]),
	erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree),
	{noreply, S1}.



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
	Length = min(Height,MaxLength),
	collect_hash_loop([], Tid, TipEntry, Length).
	
% move down the tree
collect_hash_loop(Acc, _, {Hash,_,_,_}, 1) -> lists:reverse([Hash|Acc]);
collect_hash_loop(Acc, Tid, {Hash,_,PrevHash,_}=_Entry, Length)
	when is_integer(Length) andalso Length>1 ->
	
	[PrevEntry] = ets:lookup(Tid, PrevHash),
	collect_hash_loop([Hash|Acc], Tid, PrevEntry, Length-1).


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


load_entries_from_file(S) ->
	HeadersFilePath = S#state.headers_file_path,
	NewEntries = S#state.new_entries,

	case u:file_existsQ(HeadersFilePath) of
		true ->
			{ok,F} = file:open(HeadersFilePath, [read,binary]),
			
			NewEntries1 = read_header_chunk_loop(lists:reverse(NewEntries),F),
			file:close(F),

			io:format("~wnew entries were loaded.~n",[length(NewEntries1)]),
			S#state{new_entries=NewEntries1};
		false -> S
	end.

read_header_chunk_loop(Acc, F) ->
	{ok,Position} = file:position(F, cur),

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
		eof -> lists:reverse(Acc)
	end.


load_headers_from_file(Indexes, S) ->
	HeadersFilePath = S#state.headers_file_path,
	
	{ok,F} = file:open(HeadersFilePath, [read, binary]),
	Payload = lists:foldl(fun(P,AccIn)->
		begin
			{ok,P} = file:position(F,P),
			{ok,Bin} = file:read(F,?HEADER_SIZE),
			<<AccIn/binary,Bin/binary>>
		end
		end,
		protocol:var_int(length(Indexes)), % AccIn0
		[Position || {headers,Position} <- Indexes]),
	file:close(F),

	Payload.


for_each_header_chunk_from_bin(Acc, _, <<>>, _,{_,_}) -> lists:reverse(Acc);
for_each_header_chunk_from_bin(Acc, ProcessHeaderFunc,
	Bin, Origin, {F,Tid}) ->
	<<HeaderBin:?HEADER_SIZE/binary, Rest/binary>> = Bin,
	
	Result =
	try ProcessHeaderFunc(HeaderBin,Origin,{F,Tid}) of
		Any -> Any
	catch
		Class:Reason -> {{Class,Reason}, Origin, HeaderBin}
	end,
	
	for_each_header_chunk_from_bin([Result|Acc],
		ProcessHeaderFunc, Rest, Origin, {F,Tid}).


report_errornous_entries(Entries) ->
	io:format("reporting ~w errornous header entries:~n", [length(Entries)]),
	io:format("~w~n", [Entries])
	.


save_header_func(HeaderBin, Origin, {F,Tid}) ->
	{{HashStr,_,PrevHashStr,_,_,DifficultyTarget,_,0},<<>>} =
		protocol:read_block_header(HeaderBin),
	Hash = protocol:hash(HashStr),
	<<HashInt:256/little>> = Hash,
	PrevHash = protocol:hash(PrevHashStr),
	case Tid=/=undefined andalso ets:member(Tid, Hash) of
		false ->
			case HashInt =< DifficultyTarget of
				true ->
					{ok,Position} = file:position(F, cur),
					ok = file:write(F, HeaderBin),
					{Hash,{headers,Position},PrevHash,[]};
				false ->
					{{error, not_satisfy_difficulty}, Origin, Hash}
			end;
		true -> {{error, already_have}, Origin, Hash}
	end.


climb_tree_until({_Hash,_Index,_PrevHash,NextHashes}=_Start, Goal,
	TidTree) ->
	
	try go_next_loop([],NextHashes,Goal,TidTree) of
		_NotFound -> []
	catch
		throw:Acc -> lists:reverse(Acc)
	end.

go_next_loop(Acc,[], _, _) -> Acc;
go_next_loop(Acc, [NextHash|T], {GoalHash,_,_,_}=Goal, TidTree) ->
	case NextHash of
		GoalHash -> throw([Goal|Acc]);
		_ ->
			[{NextHash, _,_, NextNextHashes}=Entry]
				= ets:lookup(TidTree, NextHash),
			go_next_loop([Entry|Acc], NextNextHashes, Goal, TidTree),
			go_next_loop(Acc, T, Goal, TidTree)
	end.


find_first_common_entry(Hashes, TidTree) ->
	try find_first_loop(Hashes, TidTree) of
		_NotFound -> not_found
	catch
		throw:Found -> Found
	end.

find_first_loop([], _TidTree) -> not_found;
find_first_loop([Hash|T], TidTree) ->
	case ets:lookup(TidTree, Hash) of
		[] -> find_first_loop(T, TidTree);
		[Found] -> throw(Found)
	end.


go_down_tree_before({_Hash,_Index,PrevHash,_NextHashes}=Start, GoalHash,
	TidTree) ->
	go_prev_loop([Start], PrevHash, GoalHash, TidTree).

go_prev_loop(Acc, PrevHash, GoalHash, TidTree) ->
	case PrevHash of
		GoalHash -> lists:reverse(Acc);
		_ ->
			case ets:lookup(TidTree, PrevHash) of
				[] -> throw(goal_not_found);
				[{_PrevHash,_Index,PrevPrevHash,_PrevNextHashes}=Entry] ->
					go_prev_loop([Entry|Acc], PrevPrevHash, GoalHash,
						TidTree)
			end
	end.


indexes(TreeEntries) -> [Index || {_,Index,_,_} <- TreeEntries].


%% sampling intervals = ceil(A * exp(n P)), n = 1,2,...
exponentially_sampled_hashes(TidTree,
	{_Height,{Hash,_Index,PrevHash,[]}}=_Tip, {A,P}) ->
	
	N = 2,
	Gap = ceil(A*math:exp(N*P)),
	exponential_sampling_loop([Hash], PrevHash, N, {A,P}, Gap, TidTree).

exponential_sampling_loop(Acc, Hash, N, {A,P}, 1, TidTree) ->
	case ets:lookup(TidTree,Hash) of
		[] -> lists:reverse(Acc);
		[{Hash,_Index,PrevHash,_NextHashes}] ->
			N1 = N+1,
			Gap = ceil(A*math:exp(N1*P)),
			exponential_sampling_loop([Hash|Acc], PrevHash, N1, {A,P}, Gap,
				TidTree)
	end;
exponential_sampling_loop(Acc, Hash, N, {A,P}, Gap, TidTree) ->
	case ets:lookup(TidTree,Hash) of
		[] -> lists:reverse(Acc);
		[{Hash,_Index,PrevHash,_NextHashes}] ->
			exponential_sampling_loop(Acc, PrevHash, N, {A,P}, Gap-1, TidTree)
	end.




-ifdef(EUNIT).

climb_tree_until_test() ->
	TidTree = ets:new(tree,[]),
	E1 = {1,1,0,[2]},
	E2 = {2,2,1,[3]},
	E3 = {3,3,2,[4,6]},
	E4 = {4,4,3,[5]},
	E5 = {5,5,4,[]},
	E6 = {6,6,3,[7]},
	E7 = {7,7,6,[8,9]},
	E8 = {8,8,7,[]},
	E9 = {9,9,7,[10]},
	E10 = {10,10,9,[11]},
	E11 = {11,11,10,[]},
	[ets:insert_new(TidTree,E) || E <- [E1,E2,E3,E4,E5,E6,E7,E8,E9,E10,E11]],
	?assertEqual(
		[11,10,9,7],
		extended_tip_hashes(TidTree, {8,E11}, 4)
		),
	?assertEqual(
		[11,10,9,7,6,3,2,1],
		extended_tip_hashes(TidTree, {8,E11}, 9)
		),
	?assertEqual(
		[6,7,9,10],
		indexes(climb_tree_until(E3,E10,TidTree))
		),
	?assertEqual(
		[6,7,9,10,11],
		indexes(climb_tree_until(E3,E11,TidTree))
		),
	?assertEqual(
		[4,5],
		indexes(climb_tree_until(E3,E5,TidTree))
		),
	?assertEqual(
		[],
		indexes(climb_tree_until(E3,{100,100,0,[]},TidTree))
		),
	?assertEqual(
		{3,3,2,[4,6]},
		find_first_common_entry([100,101,102,103,104,3,2,1], TidTree)
		),
	?assertEqual(
		[11,10,9,7,6,3,2,1],
		indexes(go_down_tree_before(E11,0,TidTree))
		).

exponentially_sampled_hashes_test() ->
	TidTree = ets:new(tree,[]),
	[ets:insert_new(TidTree, {I,I,I-1,[I+1]}) || I <- lists:seq(1,99)],
	TipEntry = {100,100,99,[]},
	ets:insert_new(TidTree, TipEntry),
	?assertEqual(
		[100,99,98,96,94,92,90,88,86,84,82,80,77,74,71,68,65,61,57,53,48,43,
			38,32,26,19,12,4],
		exponentially_sampled_hashes(TidTree,{100,TipEntry},{0.75,0.08})).

-endif.


