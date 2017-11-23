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
	get_floating_root_prevhashes/0,
	get_best_height/0,
	get_proposed_headers/2,
	create_getheaders_job_on_update/2
	]).

-include_lib("eunit/include/eunit.hrl").
-include("../include/constants.hrl").

-define(HEADER_SIZE, 81). % 80 + byte_size(var_int(0))
-define(TREE_UPDATE_INTERVAL, 10*1000).
-define(HEADERS_FILE_NAME, "headers.dat").
-define(TREE_FILE_NAME, "tree.ets").
-define(TREE_SUB_FILE_NAME, "tree_sub.ets").


-record(state,
	{
		net_type,
		headers_file_path,
		tree_file_path,
		new_entries,
		tid_tree,
		roots,
		leaves,
		tips,
		subtips,
		tips_jobs,
		exp_sampling_jobs
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

get_floating_root_prevhashes() ->
	gen_server:call(?MODULE, get_floating_root_prevhashes).

get_best_height() ->
	gen_server:call(?MODULE, get_best_height).

get_proposed_headers(PeerTreeHashes, StopHash) ->
	gen_server:call(?MODULE,
		{get_proposed_headers, PeerTreeHashes, StopHash}).

create_getheaders_job_on_update(JobType, JobTarget) ->
	gen_server:cast(?MODULE, {create_getheaders_job_on_update,
		JobType, JobTarget}).


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
	TreeFilePath = filename:join(HeadersFileDir, ?TREE_FILE_NAME),
	TreeSubFilePath = filename:join(HeadersFileDir, ?TREE_SUB_FILE_NAME),

	InitialState = #state{
			net_type = NetType,
			headers_file_path = HeadersFilePath,
			tree_file_path = {TreeFilePath, TreeSubFilePath},
			new_entries = [],
			tips_jobs = [],
			exp_sampling_jobs = []
		},
	
	case u:file_existsQ(TreeFilePath) of
		false -> 
			InitialState1 = load_entries_from_file(InitialState),
			% blocking
			{_, InitialState2} = handle_info(update_tree, InitialState1);
			%erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree),
		true ->
			InitialState2 = load_tree_structure(InitialState),
			
			io:format("blockchain:load_tree_structure finished.~n",[]),
			Tid = InitialState2#state.tid_tree,
			Tips = InitialState2#state.tips,
			Subtips = InitialState2#state.subtips,
			view:update_blockchain(
				get_painted_tree(Tid, {Tips,Subtips}, 10)),
			
			erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree)
	end,
			
	{ok, InitialState2}.


load_tree_structure(S) ->
	{TreeFilePath, TreeSubFilePath} = S#state.tree_file_path,

	{ok,Tid   } = ets:file2tab(TreeFilePath),
	{ok,TidSub} = ets:file2tab(TreeSubFilePath),
	
	[{_,Roots}]   = ets:lookup(TidSub, roots),
	[{_,Leaves}]  = ets:lookup(TidSub, leaves),
	[{_,Tips}]    = ets:lookup(TidSub, tips),
	[{_,Subtips}] = ets:lookup(TidSub, subtips),

	S#state{tid_tree=Tid,
		roots=Roots, leaves=Leaves, tips=Tips, subtips=Subtips}.


save_tree_structure(S) ->
	{TreeFilePath, TreeSubFilePath} = S#state.tree_file_path,

	Tid    = S#state.tid_tree,
	TidSub = ets:new(tree_sub, []),
	true = ets:insert_new(TidSub, {roots, S#state.roots}),
	true = ets:insert_new(TidSub, {leaves, S#state.leaves}),
	true = ets:insert_new(TidSub, {tips, S#state.tips}),
	true = ets:insert_new(TidSub, {subtips, S#state.subtips}),

	ok = ets:tab2file(Tid, TreeFilePath),
	ok = ets:tab2file(TidSub, TreeSubFilePath),

	S.


handle_call({collect_getheaders_hashes, MaxDepth}, _From, S) ->
	GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
	
	case S#state.tid_tree of
		undefined -> %{reply, not_ready, S};
			{reply, [[GenesisBlockHash]], S}; % required for startup
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
	GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),

	case S#state.tid_tree of
		undefined -> %{reply, not_ready, S};
			{reply, [GenesisBlockHash], S}; % required for startup
		Tid ->
			Tips = S#state.tips,

			case Tips of
				[ ] -> {reply, [GenesisBlockHash], S};
				 _  ->
				 	Tip = hd(Tips),
					Tips1 = u:list_rotate_left1(Tips),
				 	Advertise = exponentially_sampled_hashes(Tid, Tip, {A,P}),
					{reply, Advertise, S#state{tips=Tips1}}
			end
	end;
handle_call(get_floating_root_prevhashes, _From, S) ->
	case S#state.tid_tree of
		undefined -> {reply, not_ready, S};
		_Tid ->
			Roots = S#state.roots,
			GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
			[PrevHash || {_,_,PrevHash,_} <- Roots,
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
					?debugMsg("not_found"),
					{_H, TipEntry} = hd(Tips),
					NetType = S#state.net_type,
					GenesisBlockHash = rules:genesis_block_hash(NetType),
					lists:reverse(go_down_tree_before(TipEntry, 
						GenesisBlockHash, Tid));
				Entry ->
					?debugFmt("Entry = ~p~n",[Entry]),
					{_H, TipEntry} = hd(Tips),
					% function without the limit of search range takes
					% too much time in some situations. So we use with-limit
					% function. Note that this may result in returning a
					% tree entries that do not reside in the main stem of
					% the tree.
					climb_tree_until_with_limit(Entry, TipEntry, Tid,
						?MAX_HEADERS_COUNT)
			end,
			%Entries1 = lists:sublist(Entries,?MAX_HEADERS_COUNT),
			Entries1 = Entries, % trunction is not required for ..._with_limit.
			Entries2 =
			case StopHash of
				?HASH256_ZERO_BIN -> Entries1;
				_ -> u:take_until(fun({Hash,_,_,_})-> Hash=:=StopHash end,
					Entries1)
			end,

			?debugMsg("loading headers from file"),
			HeadersPayload = load_headers_from_file(indexes(Entries2), S),
			
			Tips1 = u:list_rotate_left1(Tips),
			{reply, HeadersPayload, S#state{tips=Tips1}}
	end.


%% for the paylod of headers message
%% We save headers that match the following conditions:
%% * has a hash that does not exist in the current table
%% * its hash satisfies its decleared difficulty (nBits)
handle_cast({save_headers, HeadersPayload, Origin}, S) ->
	Tid = S#state.tid_tree, %NOTE, can be undefined headers are empty
	HeadersFilePath = S#state.headers_file_path,

	{_N_Headers, Rest} = protocol:read_var_int(HeadersPayload),

	%NOTE: the file is created if it does not exist.
	{ok,F} = file:open(HeadersFilePath,[write,binary,append]),

	NewEntries  = lists:reverse(S#state.new_entries),
	NewEntries1 = for_each_header_chunk_from_bin(NewEntries,
		fun save_header_func/3, Rest, Origin, {F,Tid}),

	file:close(F),

	%io:format("saved ~w headers from ~w~n",[N_Headers,Origin]),
	{noreply, S#state{new_entries=NewEntries1}};

handle_cast({create_getheaders_job_on_update, JobType, JobTarget}, S) ->
	case JobType of
		tips ->
			TipsJobs = S#state.tips_jobs,
			TipsJobs1 = [JobTarget|TipsJobs],
			{noreply, S#state{tips_jobs=TipsJobs1}};
		exponential_sampling ->
			ExpSamplingJobs = S#state.exp_sampling_jobs,
			ExpSamplingJobs1 = [JobTarget|ExpSamplingJobs],
			{noreply, S#state{exp_sampling_jobs=ExpSamplingJobs1}}
	end.


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

	S2 = case NewEntriesNonError of
		[ ] -> S;
		 _  ->
		 	case S#state.tid_tree of
				undefined -> % do initialize
					S1 = initialize_tree(NewEntriesNonError, S),
					S1#state{new_entries=[]};
				_ ->
					S1 = update_tree(NewEntriesNonError, S),
					S1#state{new_entries=[]}
			end
	end,

	io:format("blockchain:update_tree finished -~n",[]),
	case S2#state.tid_tree of
		undefined -> ok;
		_ ->
			Tips = S2#state.tips,
			io:format("\t~w tips, ~w leaves, ~w roots.~n",
			[length(Tips), length(S2#state.leaves), length(S2#state.roots)]),
			if
				length(Tips) >= 1 ->
					{Height,_} = hd(Tips),
					io:format("\tbest height = ~w.~n", [Height]);
				true -> ok
			end
	end,

	S3 = process_jobs(S2),

	erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree),
	{noreply, S3}.



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
	{Tips, Subtips} = find_tips(Tid, Leaves, GenesisBlockHash),

	io:format("blockchain:initialize_tree finished.~n",[]),
	view:update_blockchain(
		get_painted_tree(Tid, {Tips,Subtips}, 10)),

	NewState = S#state{tid_tree=Tid, roots=Roots, leaves=Leaves,
		tips=Tips, subtips=Subtips},
	save_tree_structure(NewState).


% floating (non-connected) entry is added into AccIn
try_to_connect_floating_root(Tid, {Hash,_,PrevHash,_}=Entry, AccIn) ->
	case ets:lookup(Tid, PrevHash) of
		[] -> [Entry|AccIn];
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
	%io:format("update_tree got ~w new entries.~n",[length(NewEntries)]),
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
	
	Leaves1 = lists:filter(fun(Entry)-> is_leafQ(Tid,Entry) end,
		Leaves ++ NewEntries),

	{Tips, Subtips} = find_tips(Tid, Leaves1, GenesisBlockHash),
	view:update_blockchain(
		get_painted_tree(Tid, {Tips,Subtips}, 10)),

	NewState =
		S#state{roots=Roots1, leaves=Leaves1, tips=Tips, subtips=Subtips},
	save_tree_structure(NewState).



find_leaves(Tid) ->
	ets:match_object(Tid, {'_','_','_',[]}).


is_leafQ(Tid, {Hash,_,_,_}=_Entry) ->
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


%% (Leaf)-> o-> o-> o-> x
%% H = 4    3   2   1   0
%%                  |
%%                 root
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
%% returns {Tips, Subtips}
%% Tips = [Tip|T], Tip = {Height,TreeEntry}
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
			lists:splitwith(fun({H,_}) -> H==TopHeight end, SortedRootHeights)
	end.


%% paint tree entries according to their stem-ness
%% (stem = level 0, braches = level 1, 2, ...).
%% The painting process starts only from tips and subtips, 
%% i.e., leaves whose root is the genesis root.
%%
%% returns the list of
%% {E, {0, _, H'}} for the stem entries, or
%% {E, {BranchLevel, ForkPointE, H'}} for general entries,
%% where H' is the relative height of each entry from the painting limit
%% for the stem entries (when MaxLength = Best height, H' == H (height))
%% or lengthes from their fork points for general entries.
%%
%% The output painted list is always in order of increasing BranchLevel.
%% 
get_painted_tree(_Tid, {[], _Subtips}, _MaxLength) -> [];
get_painted_tree(Tid, {Tips, Subtips}, MaxLength) ->
	{BestHeight, _} = hd(Tips),
	MaxLength1 = min(MaxLength, BestHeight),

	lists:foldl(
		fun(TipEntry,PaintedIn) ->
			paint_loop(PaintedIn, [], Tid, TipEntry, MaxLength1) end,
		[], % PaintedIn0
		[TipEntry || {_H,TipEntry} <- Tips ++ Subtips]
	).


paint_loop(Painted, Acc, _Tid, {Hash,_,_,_}=_NotForkPoint, 1) ->
	% which should be stem
	Acc1 = [Hash|Acc],
	Painted ++ lists:zip(
		Acc1,
		[{0,undefined,H} || H <- lists:seq(1,length(Acc1))]);

paint_loop(Painted, Acc, Tid, {Hash,_,PrevHash,_}=_NotForkPoint, Hight) ->

	case proplists:get_value(PrevHash, Painted) of
		undefined ->
			[PrevEntry] = ets:lookup(Tid, PrevHash),
			paint_loop(Painted, [Hash|Acc], Tid, PrevEntry, Hight-1);
		{BranchLevel,_ForkPointHash,_Hight} ->
			Acc1 = [Hash|Acc],
			Painted ++ lists:zip(
				Acc1,
				[{BranchLevel+1,PrevHash,H}
					|| H <- lists:seq(1,length(Acc1))])
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

	{Tips,Subtips} = find_tips(Tid, Leaves2, GenesisBlockHash),
	io:format("blockchain:remove_entry_from_tree finished.~n",[]),
	view:update_blockchain(
		get_painted_tree(Tid, {Tips,Subtips}, 10)),

	NewState =
		S#state{roots=Roots2, leaves=Leaves2, tips=Tips, subtips=Subtips},
	save_tree_structure(NewState).



load_entries_from_file(S) ->
	HeadersFilePath = S#state.headers_file_path,
	NewEntries = S#state.new_entries,

	case u:file_existsQ(HeadersFilePath) of
		true ->
			io:format("reading ~s...~n",[HeadersFilePath]),
			{ok,F} = file:open(HeadersFilePath, [read,binary]),
			
			NewEntries1 = read_header_chunk_loop(lists:reverse(NewEntries),F),
			file:close(F),

			io:format("~w new entries were loaded.~n",[length(NewEntries1)]),
			S#state{new_entries=NewEntries1};
		false -> S
	end.


read_header_chunk_loop(Acc, F) ->
	{ok,Position} = file:position(F, cur),

	case file:read(F, ?HEADER_SIZE) of
		{ok,Bin} ->
			{{HashStr,_,PrevHashStr,_,_,_,_,0},<<>>} =
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
	io:format("reporting ~w errornous header entries:~n", [length(Entries)])
	%io:format("~w~n", [Entries])
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
	?debugMsg("climb_tree_until"),
	
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


climb_tree_until_with_limit({_Hash,_Index,_PrevHash,NextHashes}=_Start, Goal,
	TidTree, Limit) when is_integer(Limit) andalso Limit>0 ->
	?debugMsg("climb_tree_until_with_limit"),
	
	try go_next_loop_with_limit([],NextHashes,Goal,TidTree,Limit) of
		_NotFound -> []
	catch
		throw:Acc -> lists:reverse(Acc)
	end.

go_next_loop_with_limit(Acc,[], _, _, _) -> Acc;
go_next_loop_with_limit(Acc, _, _, _, 0) -> throw(Acc);
go_next_loop_with_limit(Acc, [NextHash|T], {GoalHash,_,_,_}=Goal, TidTree,
	Limit) ->
	case NextHash of
		GoalHash -> throw([Goal|Acc]);
		_ ->
			[{NextHash, _,_, NextNextHashes}=Entry]
				= ets:lookup(TidTree, NextHash),
			go_next_loop_with_limit([Entry|Acc], NextNextHashes, Goal,
				TidTree, Limit-1),
			go_next_loop_with_limit(Acc, T, Goal, TidTree, Limit)
	end.


find_first_common_entry(Hashes, TidTree) ->
	?debugFmt("blockchain:find_first_common_entry~n",[]),
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
	?debugFmt("blockchain:go_down_tree_before~n",[]),
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


process_jobs(S) ->
	Tid = S#state.tid_tree,
	Tips = S#state.tips,

	S1 =
	case S#state.tips_jobs of
		[] -> S;
		TipsJobs ->
			case Tips of
				[ ] -> S#state{tips_jobs=[]};
				 _  ->
				 	MaxDepth = 5,
				 	ListOfList =
					[extended_tip_hashes(Tid, T, MaxDepth) || T <- Tips],
					[jobs:add_job({Target,
						{getheaders, Hashes},
						60}) || Target <- TipsJobs, Hashes <- ListOfList],
					%[jobs:add_job({Target,
					%	{getheaders, [Hash]},
					%	60}) || Target <- TipsJobs, {_H,{Hash,_,_,_}} <- Tips],
					S#state{tips_jobs=[]}
			end
	end,

	S2 =
	case S#state.exp_sampling_jobs of
		[] -> S1;
		ExpSamplingJobs ->
			Hashes =
			case Tips of
				[ ] ->
					Tips1 = [], %dummy
					GenesisBlockHash = 
						rules:genesis_block_hash(S1#state.net_type),
					[GenesisBlockHash];
				 _  ->
				 	T = hd(Tips),
					Tips1 = u:list_rotate_left1(Tips),
					{A,P} = {0.75,0.08},
				 	exponentially_sampled_hashes(Tid, T, {A,P})
			end,

			Hashes1 = lists:sublist(Hashes, ?MAX_HEADERS_COUNT),
			[jobs:add_job({Target,
				{getheaders, Hashes1},
				60}) || Target <- ExpSamplingJobs],
			S1#state{exp_sampling_jobs=[], tips=Tips1}
	end,

	S2.


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

get_painted_tree_test() ->
	TidTree = ets:new(tree,[]),
	[ets:insert_new(TidTree, E) || E <-
		[
			{"A",0,"B",[]},
			{"B",0,"C",["A"]},
			{"C",0,"D",["B"]},
			{"D",0,"E",["C"]},
			{"E",0,"F",["D","J"]},
			{"F",0,"G",["E"]},
			{"G",0,"H",["F"]},
			{"H",0,0,  ["G"]},
			{"I",0,"C",[]},
			{"J",0,"E",["K"]},
			{"K",0,"J",["L","M"]},
			{"L",0,"K",[]},
			{"M",0,"K",[]}
		]
	],
	Tips = [{8,{"A",0,"B",[]}}],
	Subtips =
		[
			{7,{"I",0,"C",[]}},
			{7,{"L",0,"K",[]}},
			{7,{"M",0,"K",[]}}
		],
		
	Painted = get_painted_tree(TidTree, {Tips,Subtips}, 8),

	?assertEqual(
		[
			{"H",{0,undefined,1}},
			{"G",{0,undefined,2}},
			{"F",{0,undefined,3}},
			{"E",{0,undefined,4}},
			{"D",{0,undefined,5}},
			{"C",{0,undefined,6}},
			{"B",{0,undefined,7}},
			{"A",{0,undefined,8}},
			{"I",{1,"C",1}},
			{"J",{1,"E",1}},
			{"K",{1,"E",2}},
			{"L",{1,"E",3}},
			{"M",{2,"K",1}}
		],
		Painted).

get_proposed_headers_test_func() ->
	
	InitialState = #state{
			net_type = testnet,
			headers_file_path = undefined,
			tree_file_path = {"../test-data/tree.ets",
				"../test-data/tree_sub.ets"},
			new_entries = [],
			tips_jobs = [],
			exp_sampling_jobs = []
		},
	S = load_tree_structure(InitialState),

	GetHeadersHashStrs =
	[
	"71a060a0db039b1b0959c05e823a7a23f1a681792758b4e561e2256f00000000",
	"c34ab546fb6164dc8455ef6b4c6be0b4d9f6b06a7b2b909b38b5092d00000000",
	"de5b260ed3baf747b4b6b90a73d4ed29f3d6b4dc1ee8548a3b611fe300000000",
	"0359f6957915f5cc0f50e106dc9a0df72189762d01b3f0696605adf900000000",
	"837003a924ef904cc26a553c8471e6da16048ac8ed724b19b21de38800000000",
	"d9568362378703af3aa1c5effc8f26263d242f96174f701cdf50adae00000000",
	"3aba031f2eed066e62044aae543f930c627e3c0f85ff1dd0bfa720da00000000",
	"41fe5438905e78898f75191b7967976b416ecc09d3763135d94e839f00000000",
	"081a28f384d05ad8d2a6fd2d758785b27faea569d8f7a64bde1bd53200000000",
	"b64c59375a1adf97389899a62f0ec0979c02f8f71fbb5662fe36659a00000000",
	"bd6666e2411455a59e01645d196df41babf34d09d9dbfa1b1809000000000000",
	"043588b14200ddaf2c0ecca7afc37df083fbd994f51f1b5add2a000000000000",
	"63b841da75d724115d31621a42c5a0bee7b32ca96bb929e38c0e000000000000",
	"bacd92546309826eea8b6e25f312a2677e95b850a3fd3ce2887d96d100000000",
	"a2c9ad2ed00b08beeb313a4f36f6d0071ae06f5847a2e4a44611000000000000",
	"94583ec6b661601884982a23087f86e89985a0fc9f2043465d0e52f900000000",
	"725b9b5bf8751110de083a12b5901134c8c5e3ac072bb69e568a63e100000000",
	"86ca5a0f8c3d3fd38f646e80ca0cde7a2371a348f8e948f8ffd118dc00000000",
	"28c83aa906f3b143374de067582cb29534c129486fe4854e8ffe68c900000000",
	"bcbf0f5c9f8cbfa77705ba053a908f2cc0603b2b6b1015700736000000000000",
	"f89fcf06195dde3120e1645ee3334b332857d55b5195267cbd85a26a00000000",
	"4d8eaea94325c9559bd774de621343b8a765a2d2e2423617db00000000000000",
	"8ad187d1cb9528cee2b22d807beb0d0965880349340fbf9a9fe0020000000000",
	"597a5be5dba1ddf2fe79a8208e803ffe7a7d29b26dd4a01663f12f0000000000",
	"42a7410b427744d655b3f58e3c6546395b12ac3189107b478b38543a00000000",
	"a72fb94dc84b388b0dca6090df39d59d557899beffb6574c0d4f000000000000",
	"4923e67cab68b207ea2f79fb3556832e465f95a3cb3975818d62010000000000",
	"8dcde6f6a9d19d8284c040119ccc5238efd8546c0052572aecd50d0000000000",
	"70172a68bf4485a86428f4b01d06b9156071219f491462119d72b10000000000",
	"a8ba48b4a9e8b64b3c7d690317e81a61c61f5e38db4a56bb5c0da00000000000",
	"24f202424c3709f5cd159ff7c9ade52ab1ee49f0b1102f86d579409e00000000",
	"43497fd7f826957108f4a30fd9cec3aeba79972084e90ead01ea330900000000"],
	GetHeadersHashes = [protocol:hash(H) || H <- GetHeadersHashStrs],
	StopHash = ?HASH256_ZERO_BIN,

	Reply = handle_call({get_proposed_headers, GetHeadersHashes, StopHash},
		undefined, S),
	?debugFmt("get_proposed_headers result = ~p~n",[Reply]),
	ok.
	
%get_proposed_headers_test_() ->
%	[
%		{timeout, 20, fun get_proposed_headers_test_func/0}
%	].

-endif.


