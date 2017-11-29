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
-include_lib("eunit/include/eunit.hrl").


-behaviour(gen_server).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

% APIs
-export([start_link/1,
	got_headers/2,
	collect_getheaders_hashes/1,
	collect_getheaders_hashes_exponential/1,
	get_floating_root_prevhashes/0,
	get_best_height/0,
	get_proposed_headers/2,
	create_job_on_update/2
	]).

-include_lib("eunit/include/eunit.hrl").
-include("../include/constants.hrl").

-define(HEADER_SIZE, 81). % 80 + byte_size(var_int(0))
-define(TREE_UPDATE_INTERVAL, (10*1000)).
-define(HEADERS_FILE_NAME, "headers.dat").
-define(TREE_FILE_NAME, "tree.ets").
-define(TREE_SUB_FILE_NAME, "tree_sub.ets").

-define(N_TARGET_TIMESPAN, (14*24*60*60)). % two weeks
-define(N_TARGET_SPACING, (10*60)). % 10 min
-define(N_INTERVAL, (?N_TARGET_TIMESPAN div ?N_TARGET_SPACING)). % 2016


-record(state,
	{
		net_type,
		headers_file_path,
		tree_file_path,
		new_entries,
		tid_tree,
		roots,
		leaves, % = tips ++ subtips
		tips,
		subtips,
		best_height,
		tips_jobs,
		exp_sampling_jobs,
		new_block_jobs,
		check_integrity_on_startup,
		tid_testnet_real_difficulty
	}).


%% ----------------------------------------------------------------------------
%% gen_server callbacks
%% ----------------------------------------------------------------------------
start_link(NetType) ->
	Args = [NetType],
	gen_server:start_link({local,?MODULE}, ?MODULE, Args, []).

got_headers(HeadersPayload, Origin) ->
	gen_server:cast(?MODULE, {got_headers, HeadersPayload, Origin}).

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
		{get_proposed_headers, PeerTreeHashes, StopHash}, 15*1000).

create_job_on_update(JobType, JobTarget) ->
	gen_server:cast(?MODULE, {create_job_on_update,
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
			tid_tree = ets:new(blockchain_index,[]),
			new_entries = [],
			tips_jobs = [],
			exp_sampling_jobs = [],
			new_block_jobs = [],
			check_integrity_on_startup = false,
			tid_testnet_real_difficulty = ets:new(real_difficulty,[])
		},
	
	case u:file_existsQ(TreeFilePath) of
		false -> 
			Entries = load_entries_from_file(HeadersFilePath),
			InitialState1 = initialize_tree(Entries, InitialState);
		true ->
			InitialState1 = load_tree_structure(InitialState),
			
			io:format("blockchain:load_tree_structure finished.~n",[]),
			Tid     = InitialState1#state.tid_tree,
			Tips    = InitialState1#state.tips,
			Subtips = InitialState1#state.subtips,
			view:update_blockchain(
				get_painted_tree(Tid, {Tips,Subtips}, 10))
	end,
	
	case InitialState1#state.check_integrity_on_startup 
		andalso not check_integrity_of_index(InitialState1) of
		true  -> {stop, bad_index};
		false ->
			erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree),
			{ok, InitialState1}
	end.


handle_call({collect_getheaders_hashes, MaxDepth}, _From, S) ->
	GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
	Tid = S#state.tid_tree,
	Tips = S#state.tips,

	Advertise =
	case Tips of
		[ ] -> [[GenesisBlockHash]];
		 _  -> [extended_tip_hashes(Tid, T, MaxDepth) || T <- Tips]
	end,
	{reply, Advertise, S};

handle_call({collect_getheaders_hashes_exponential, {A,P}}, _From, S) ->
	GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
	Tid = S#state.tid_tree,
	Tips = S#state.tips,
	
	case Tips of
		[ ] -> {reply, [GenesisBlockHash], S};
		 _  ->
		 	Tip = hd(Tips),
			Tips1 = u:list_rotate_left1(Tips),
			Advertise = exponentially_sampled_hashes(Tid, Tip, {A,P}),
			{reply, Advertise, S#state{tips=Tips1}}
	end;

handle_call(get_floating_root_prevhashes, _From, S) ->
	Roots = S#state.roots,
	GenesisBlockHash = rules:genesis_block_hash(S#state.net_type),
	[PrevHash || {_,_,PrevHash,_,_} <- Roots,
		PrevHash =/= GenesisBlockHash];

%%FIXME, use state.best_height?
handle_call(get_best_height, _From, S) ->
	case S#state.tips of
		[] -> {reply, 0, S};
		[{_,_,_,_,Height}|_T] -> {reply, Height, S}
	end;

handle_call({get_proposed_headers, PeerTreeHashes, StopHash}, _From, S) ->
	Tid = S#state.tid_tree,
	Tips = S#state.tips,

	case Tips of
		[ ] -> {reply, <<>>, S};
		 _  ->
		 	Entries =
		 	case find_first_common_entry(PeerTreeHashes, Tid) of
				not_found ->
					TipEntry = hd(Tips),
					NetType = S#state.net_type,
					GenesisBlockHash = rules:genesis_block_hash(NetType),
					lists:reverse(go_down_tree_before(TipEntry, 
						GenesisBlockHash, Tid));
				Entry ->
					TipEntry = hd(Tips),
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
				_ -> u:take_until(fun({Hash,_,_,_,_})-> Hash=:=StopHash end,
					Entries1)
			end,

			HeadersPayload = load_headers_from_file(indexes(Entries2), S),
			
			Tips1 = u:list_rotate_left1(Tips),
			{reply, HeadersPayload, S#state{tips=Tips1}}
	end.


handle_cast({got_headers, HeadersPayload, Origin}, S) ->
	Tid = S#state.tid_tree,

	{_N_Headers, Rest} = protocol:read_var_int(HeadersPayload),

	NewEntries = for_each_header_chunk_from_bin(S#state.new_entries,
		fun precheck_header_func/4, Rest, Origin, Tid),

	{noreply, S#state{new_entries=NewEntries}};

handle_cast({create_job_on_update, JobType, JobTarget}, S) ->
	case JobType of
		tips ->
			TipsJobs = S#state.tips_jobs,
			TipsJobs1 = [JobTarget|TipsJobs],
			{noreply, S#state{tips_jobs=TipsJobs1}};
		exponential_sampling ->
			ExpSamplingJobs = S#state.exp_sampling_jobs,
			ExpSamplingJobs1 = [JobTarget|ExpSamplingJobs],
			{noreply, S#state{exp_sampling_jobs=ExpSamplingJobs1}};
		new_block ->
			NewBlockJobs = S#state.new_block_jobs,
			{_Node, _BlockHash} = JobTarget, % format check
			NewBlockJobs1 = [JobTarget|NewBlockJobs],
			{noreply, S#state{new_block_jobs=NewBlockJobs1}}
	end.


handle_info(update_tree, S) ->
	%NewEntries = lists:reverse(S#state.new_entries),
	NewEntries = S#state.new_entries,

	{NewEntriesNonError,NewEntriesWithError} =
	lists:partition(fun(X) ->
		case X of
			{<<_Hash:32/binary>>,_Bin,<<_PrevHash:32/binary>>, [],
				undefined} -> true;
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
		[ ] -> S#state{new_entries=[]};
		 _  ->
			S1 = update_tree(NewEntriesNonError, S),
			S1#state{new_entries=[]}
	end,

	io:format("blockchain:update_tree finished -~n",[]),
	Tips = S2#state.tips,
	io:format("\t~w tips, ~w leaves, ~w roots.~n",
	[length(Tips), length(S2#state.leaves), length(S2#state.roots)]),
	S3 =
	if
		length(Tips) >= 1 ->
			{_,_,_,_,Height} = hd(Tips),
			io:format("\tbest height = ~w.~n", [Height]),
			% is the best height updated?
			OldHeight = S2#state.best_height,
			%case Height =/= OldHeight of
			%	true ->
					view:update_best_height(OldHeight, Height), %;
			%	false -> ok
			%end,
			view:update_blockchain(
				get_painted_tree(S2#state.tid_tree,
					{S2#state.tips,S2#state.subtips}, 10)),
			S2#state{best_height=Height};
		true -> S2
	end,

	S4 = process_jobs(S3),

	erlang:send_after(?TREE_UPDATE_INTERVAL, self(), update_tree), % repeat
	{noreply, S4}.



%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------
initialize_tree(Entries, S) ->
	io:format("blockchain:initialize_tree started.~n",[]),
	NetType = S#state.net_type,
	Tid = S#state.tid_tree,
	GenesisBlockHash = rules:genesis_block_hash(NetType),

	insert_entries(Tid, Entries, GenesisBlockHash),

	% the list of Entry whose PrevHash is not found in the table
	% including Block-1
	%NOTE: we can also use lists:foldl here
	io:format("\tfinding roots...~n",[]),
	erlang:garbage_collect(), % this had an effect for a low memory environment.
	Roots = %NOTE, this entry may not have valid NextHashes
	ets:foldl(fun(Entry,AccIn) ->
		try_to_connect_floating_root(Tid,Entry,AccIn) end, [], Tid),

	io:format("\tfinding leaves...~n",[]),
	Leaves = find_leaves(Tid),
	
	% Updating heights by using update_height_of_leaf is accumulator based and
	% requires a lot of memory for the entire tree and tends to cause memory
	% overflow. So we first update heights from the root one by one and use
	% update_height_of_leaf for the remainings.
	io:format("\tupdating heights(step 1)...~n",[]),
	case [Entry || {_,_,GenesisBlockHash1,_,_}=Entry <- Roots,
		GenesisBlockHash1 =:= GenesisBlockHash] of
		[] -> ok;
		[{GenesisRootHash,_,_,_,_}] ->
			update_heights_from_the_root(GenesisRootHash,S)
	end,
	io:format("\tupdating heights(step 2)...~n",[]),
	UpdatedLeaves = [update_height_of_leaf(L,S) || L <- Leaves],
	
	io:format("\tfinding tips...~n",[]),
	{Tips, Subtips} = find_tips(UpdatedLeaves),

	io:format("blockchain:initialize_tree finished.~n",[]),
	view:update_blockchain(
		get_painted_tree(Tid, {Tips,Subtips}, 10)),

	NewState = S#state{tid_tree=Tid, roots=Roots, leaves=Leaves,
		tips=Tips, subtips=Subtips},
	save_tree_structure(NewState).


% floating (non-connected) entry is added into AccIn
try_to_connect_floating_root(Tid, {Hash,_,PrevHash,_,_}=Entry, AccIn) ->
	case ets:lookup(Tid, PrevHash) of
		[] -> [Entry|AccIn];
		[{PrevHash, Index, PrevPrevHash, PrevNextHashes, PrevHeight}] ->
			% update the entry
			true = ets:insert(Tid,
			{PrevHash, Index, PrevPrevHash, [Hash|PrevNextHashes], PrevHeight}),
			AccIn
	end.


% When inserting the entries, we remove potential genesis blocks.
insert_entries(Tid, Entries, GenesisBlockHash) ->
	[ets:insert_new(Tid,E) ||
		{<<Hash:32/binary>>,_Index,<<PrevHash:32/binary>>,[],undefined}=E
		<- Entries,
		PrevHash =/= ?HASH256_ZERO_BIN, Hash =/= GenesisBlockHash,
		Hash =/= PrevHash].


%% We assume that the number of NewEntries are usually much smaller than that of
%% existing entries in the table.
%% We also assume in this update function that there are only additinal changes.
%%
%% Hashes in NewEntries must have duplicates neither in their own nor
%% in tid_tree table.
update_tree(NewEntries, S) ->
	%io:format("update_tree got ~w new entries.~n",[length(NewEntries)]),
	NetType = S#state.net_type,
	GenesisBlockHash = rules:genesis_block_hash(NetType),
	Tid = S#state.tid_tree,
	Leaves = S#state.leaves,
	Roots = S#state.roots,
	
	NewEntries1 = save_headers(NewEntries, S#state.headers_file_path),
	insert_entries(Tid, NewEntries1, GenesisBlockHash),
	
	Roots1 =
	lists:foldl(fun(Entry,AccIn) ->
		try_to_connect_floating_root(Tid,Entry,AccIn) end, [],
		Roots ++ NewEntries1),
	
	Leaves1 = lists:filter(fun(Entry)-> is_leafQ(Tid,Entry) end,
		Leaves ++ NewEntries1),
	UpdatedLeaves = [update_height_of_leaf(L,S) || L <- Leaves1],
	{Tips, Subtips} = find_tips(UpdatedLeaves),
	%view:update_blockchain(
	%	get_painted_tree(Tid, {Tips,Subtips}, 10)),

	NewState =
		S#state{roots=Roots1, leaves=Leaves1, tips=Tips, subtips=Subtips},
	save_tree_structure(NewState).


save_headers(NewEntries, HeadersFilePath) ->
	
	%NOTE: the file is created if it does not exist.
	{ok,F} = file:open(HeadersFilePath,[write,binary,append]),
	Size = filelib:file_size(HeadersFilePath),
	SavedEntries =
	[
		begin
		% when writing in append mode, position value seems to start with 0,
		% but after the first write (except <<>>), the value seems to jump
		% to the expected one.
		{ok,Position} = file:position(F, cur),
		ok = file:write(F, HeaderBin),
		Position1 =
		case Position of
			0 -> Size;
			_ -> Position
		end,
		{Hash,{headers,Position1},PrevHash,NextHashes,Height}
		end
		|| {Hash,HeaderBin,PrevHash,NextHashes,Height} <- NewEntries
	],
	file:close(F),

	SavedEntries.


find_leaves(Tid) ->
	ets:match_object(Tid, {'_','_','_',[],'_'}).


is_leafQ(Tid, {Hash,_,_,_,_}=_Entry) ->
	case ets:lookup(Tid, Hash) of
		[{Hash, _, _, NextHashes, _}] -> NextHashes =:= []
	end.


split_entries_by_fork_type(Tid) ->
	ets:foldl(fun({_,_,_,NextHashes,_}=Entry, {F0,F1,Fn}=_AccIn) ->
		case length(NextHashes) of
			0 -> {[Entry|F0],F1,       Fn};
			1 -> { F0,      [Entry|F1],Fn};
			_ -> { F0,       F1,      [Entry|Fn]}
		end end, {[],[],[]}, Tid).


check_difficultyQ({_,Index,_,_,_}=Entry, S) ->
	NetType = S#state.net_type,
	{_,_,_,_,_Time,DifficultyTarget,_,_}
		= load_header_from_file(Index, S),
	
	%io:format("~w at Time=~w~n",[DifficultyTarget,Time]),
	WorkRequired =
	case NetType of
		testnet -> testnet_work_required_for(Entry, true, S);
		_ -> work_required_for(Entry,S)
	end,

	case WorkRequired == DifficultyTarget of
		true -> true;
		false ->
			case NetType of
				testnet ->
					RealWorkRequired
					= testnet_work_required_for(Entry, false, S),
					case RealWorkRequired == DifficultyTarget of
						true -> true;
						false ->
							io:format("Expected: ~w; Actual: ~w~n",
								[RealWorkRequired, DifficultyTarget]),
							false
					end;
				_ ->
					io:format("Expected: ~w; Actual: ~w~n",
						[WorkRequired, DifficultyTarget]),
					false
			end
	end.


% update the entries
%
% returns the updated last (i.e. leaf) entry in the accumulator (Entries)
update_heights(Entries, Height0, S) ->
	Tid = S#state.tid_tree,
	UpdatedEntries = [{H,I,PH,NH,Height} ||
		{{H,I,PH,NH,undefined}, Height}
		<- lists:zip(Entries,lists:seq(1+Height0,length(Entries)+Height0))],

	[ ets:insert(Tid, E) || E <- UpdatedEntries ],
	BadDifficulties = lists:filter(fun(E)-> not check_difficultyQ(E,S) end,
		UpdatedEntries),
	
	N_BadDifficulties = length(BadDifficulties),
	case N_BadDifficulties == 0 of
		true -> ok;
		false ->
			io:format("~w entries did not pass the difficulty check:\n~p~n",
				[N_BadDifficulties, BadDifficulties])
	end,
	
	lists:last(UpdatedEntries).


%% (Leaf)-> o-> o-> o-> x
%% H = 4    3   2   1   0
%%                  |
%%                 root
update_height_of_leaf({_,_,_,_,Height}=Entry,_S) when Height =/= undefined ->
	Entry;
update_height_of_leaf(Leaf, S) ->
	update_height_of_leaf([Leaf], 1, Leaf, S).

update_height_of_leaf(Acc, Height,
	{_,_,PrevHash,_,undefined}=Entry, S) ->
	NetType = S#state.net_type,
	Tid = S#state.tid_tree,
	GenesisBlockHash = rules:genesis_block_hash(NetType),

	case ets:lookup(Tid, PrevHash) of
		[] ->
			case PrevHash of
				GenesisBlockHash ->
					update_heights(Acc, 0, S);
				_ -> Entry % not connected to the genesis block
			end;
		[{_,_,_,_,PrevHeight}=PrevEnt] ->
			case PrevHeight of
				undefined ->
					Acc1 = [PrevEnt|Acc],
					update_height_of_leaf(Acc1, Height+1, PrevEnt, S);
				_ ->
					update_heights(Acc, PrevHeight, S)
			end
	end.


update_heights_from_the_root(GenesisRootHash, S) ->
	[GenesisRoot] = ets:lookup(S#state.tid_tree, GenesisRootHash),
	update_heights_loop(1, GenesisRoot, S).

update_heights_loop(H, {Hash,Index,PrevHash,NextHashes,undefined}=Entry,
	S) ->
	%io:format("~p~n",[Hash]),
	case H rem 100000 of
		0 ->
			%erlang:garbage_collect(),
			io:format("update_heights reached height = ~p.~n",[H]);
		_ -> ok
	end,

	case check_difficultyQ(Entry, S) of
		false ->
			io:format("bad difficulty found in block ~p at height = ~w~n",
				[Hash,H]),
			throw(bad_difficulty);
		true ->
			% update
			Tid = S#state.tid_tree,
			ets:insert(Tid, {Hash,Index,PrevHash,NextHashes,H}),
			case NextHashes of
				[] -> ok;
				% make tail-recursive
				% FIXME, how can we go to the other branches?
				[NextHash1|_] ->
					[E] = ets:lookup(Tid, NextHash1),
					update_heights_loop(H+1,E,S)
			end
	end.


%% Tip is the highest leaf among leaves whose roots are the genesis block.
%% There can be multiple tips.
%%
%% returns {Tips, Subtips}
find_tips(UpdatedLeaves) ->
	% A leaf is not connected to the genesis block when its height = undefined.
	PotentialTips = [L || {_,_,_,_,H}=L <- UpdatedLeaves, H =/= undefined],

	case PotentialTips of
		[ ] -> {[],[]};
		 _  ->
			Sorted = lists:sort(fun({_,_,_,_,H1},{_,_,_,_,H2})-> H1 >= H2 end, 
				PotentialTips),
			{_,_,_,_,TopHeight} = hd(Sorted),
			lists:splitwith(fun({_,_,_,_,H}) -> H==TopHeight end, Sorted)
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
	{_,_,_,_,BestHeight} = hd(Tips),
	MaxLength1 = min(MaxLength, BestHeight),
	%io:format("get_painted_tree: Tips = ~p, Subtips = ~p~n",[Tips,Subtips]),
	HeightLimit = BestHeight - MaxLength1 + 1,
	StartTips = [E || {_,_,_,_,H}=E <- Tips ++ Subtips, H >= HeightLimit],
	%FIXME, for long branch whose fork is under the paint limit
	% remove branches (i.e. run except the first run) that do not meet forks

	Result=
	lists:foldl(
		fun(TipEntry,PaintedIn) ->
			paint_loop(PaintedIn, [], Tid, TipEntry, MaxLength1) end,
		[], % PaintedIn0
		StartTips
	),
	%io:format("\t~p~n",[Result]),
	Result.


paint_loop(Painted, Acc, _Tid, {Hash,_,_,_,_}=_NotForkPoint, 1) ->
	% which should be stem
	Acc1 = [Hash|Acc],
	Painted ++ lists:zip(
		Acc1,
		[{0,undefined,H} || H <- lists:seq(1,length(Acc1))]);

paint_loop(Painted, Acc, Tid, {Hash,_,PrevHash,_,_}=_NotForkPoint, Hight) ->

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


extended_tip_hashes(Tid, {_,_,_,_,Height}=TipEntry, MaxLength) ->
	Length = min(Height,MaxLength),
	collect_hash_loop([], Tid, TipEntry, Length).
	
% move down the tree
collect_hash_loop(Acc, _, {Hash,_,_,_,_}, 1) -> lists:reverse([Hash|Acc]);
collect_hash_loop(Acc, Tid, {Hash,_,PrevHash,_,_}=_Entry, Length)
	when is_integer(Length) andalso Length>1 ->
	
	[PrevEntry] = ets:lookup(Tid, PrevHash),
	collect_hash_loop([Hash|Acc], Tid, PrevEntry, Length-1).



% testnet has a special 20-min rule: if no block has been found
% in 20 minutes, the difficulty automatically resets back to the
% minimum for a single block, after which it returns to its
% previous value.
testnet_work_required_for({Hash,Index,PrevHash,_,_}=Entry, Use20MinRuleQ, S) ->
	TidTree = S#state.tid_tree,
	GenesisBlockHash = rules:genesis_block_hash(testnet),
	MinimumDifficultyTarget = rules:minimum_difficulty_target(testnet),
	TidTestnetRealDifficulty = S#state.tid_testnet_real_difficulty,

	case PrevHash of
		GenesisBlockHash -> MinimumDifficultyTarget;
		_ ->
			[{PrevHash,IndexLast,_,_,Height}] = ets:lookup(TidTree, PrevHash),
			{_,_,_,_,Time,_,_,_}
				= load_header_from_file(Index, S),
			{_,_,_,_,TimeLast,_,_,_}
				= load_header_from_file(IndexLast, S),

			WorkRequired =
			case (Height+1) rem ?N_INTERVAL of
				0 ->
					% go back by what we want to be 14 days worth of blocks
					{_,IndexFirst,_,_,_} = go_down_tree_n_times(
						Entry, ?N_INTERVAL, GenesisBlockHash, TidTree),
					retarget_difficulty(IndexLast, IndexFirst, S);
				_ ->
					case ets:lookup(TidTestnetRealDifficulty, PrevHash) of
						[] ->
							{_,_,_,_,_,DifficultyTarget,_,_}
								= load_header_from_file(IndexLast, S),
							DifficultyTarget;
						[{PrevHash,RealDifficulty}] -> RealDifficulty
					end
			end,

			case Use20MinRuleQ andalso (TimeLast + 20*60 < Time) of
				false -> WorkRequired;
				true ->
					ets:insert(TidTestnetRealDifficulty, {Hash, WorkRequired}),
					MinimumDifficultyTarget
			end
	end.


% The target difficulty is determined by a feedback mechanism defined in
% GetNextWorkRequired() function in Main.cpp of the original bitcoin.
%
work_required_for({_,_,PrevHash,_,_}=Entry, S) ->
	NetType = S#state.net_type,
	TidTree = S#state.tid_tree,
	GenesisBlockHash = rules:genesis_block_hash(NetType),

	case PrevHash of
		GenesisBlockHash ->
			rules:minimum_difficulty_target(NetType);
		_ ->
			[{PrevHash,Index,_,_,Height}] = ets:lookup(TidTree, PrevHash),
			% only change once per interval
			case (Height+1) rem ?N_INTERVAL of
				0 ->
					% go back by what we want to be 14 days worth of blocks
					{_,IndexFirst,_,_,_} = go_down_tree_n_times(
						Entry, ?N_INTERVAL, GenesisBlockHash, TidTree),
					retarget_difficulty(Index, IndexFirst, S);
				_ ->
					{_,_,_,_,_,DifficultyTarget,_,_}
						= load_header_from_file(Index, S),
					DifficultyTarget
			end
	end.


retarget_difficulty(IndexLast, IndexFirst, S) ->
	NetType = S#state.net_type,
	{HashLast,_,_,_,TimestampLast,DifficultyTargetLast,_,_}
		= load_header_from_file(IndexLast, S),
	{_,_,_,_,TimestampFirst,_DifficultyTargetFirst,_,_}
		= load_header_from_file(IndexFirst, S),
	
	ActualTimespan = TimestampLast - TimestampFirst,
	% limit adjustment step
	ActualTimespan1 =
	if
		ActualTimespan < ?N_TARGET_TIMESPAN div 4 ->
			?N_TARGET_TIMESPAN div 4;
		ActualTimespan > ?N_TARGET_TIMESPAN*4 ->
			?N_TARGET_TIMESPAN*4;
		true -> ActualTimespan
	end,
	
	% note that difficulty target is the upper limit of hash value:
	% smaller value means greater difficulty of the work

	DifficultyTargetLast1 =
	case NetType of
		testnet ->
			case ets:lookup(S#state.tid_testnet_real_difficulty, HashLast) of
				[] -> DifficultyTargetLast;
				[RealDifficulty] -> RealDifficulty
			end;
		_ -> DifficultyTargetLast
	end,

	NewTarget = DifficultyTargetLast1 * ActualTimespan1 div ?N_TARGET_TIMESPAN,
	DifficultyLimit = rules:minimum_difficulty_target(NetType),
	NewTarget1 =
	if
		NewTarget > DifficultyLimit -> DifficultyLimit;
		true -> NewTarget
	end,

	NewTarget2 = protocol:parse_difficulty_target(
		protocol:compact(NewTarget1)),

	%io:format("retarget (~w):\n~w\n~w~n",[ActualTimespan1,
	%	DifficultyTargetLast1,NewTarget2]),
	NewTarget2.


load_entries_from_file(HeadersFilePath) ->

	case u:file_existsQ(HeadersFilePath) of
		true ->
			io:format("reading ~s...~n",[HeadersFilePath]),
			{ok,F} = file:open(HeadersFilePath, [read,binary]),
			
			Entries = read_header_chunk_loop([],F),
			file:close(F),

			io:format("~w entries were loaded.~n",[length(Entries)]),
			Entries;
		false -> []
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
				[],
				undefined},
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


load_header_binary_from_file(Index, S) ->
	Payloads = load_headers_from_file([Index],S),
	{1, Bin} = protocol:read_var_int(Payloads),
	Bin.


load_header_from_file(Index, S) ->
	Bin = load_header_binary_from_file(Index, S),

	{BlockHeader, _Rest} = protocol:read_block_header(Bin),
	BlockHeader.


check_integrity_of_index(S) ->
	Tid = S#state.tid_tree,

	try
		ets:foldl(fun({Hash,Index,_,_,_}=Entry,_AccIn) ->
			begin
			Bin = load_header_binary_from_file(Index, S),
			case protocol:read_block_header(Bin)  of
				{{HashStr,_,_,_,_,_,_,0},<<>>} -> ok;
				_ ->
					HashStr = "", % dummy
					throw({bad_index,Entry})
			end,
			
			case protocol:hash(HashStr) of
				Hash  -> ok;
				_ -> throw({bad_index,Entry})
			end
			
			end
			end,
			undefined, Tid),
			
		true
	catch
		throw:Reason ->
			io:format("check_integrity_of_index failed at ~p~n",[Reason]),
			false
	end.


for_each_header_chunk_from_bin(Acc, _, <<>>, _, _) -> lists:reverse(Acc);
for_each_header_chunk_from_bin(Acc, CheckHeaderFunc,
	Bin, Origin, Tid) ->
	<<HeaderBin:?HEADER_SIZE/binary, Rest/binary>> = Bin,
	
	Result =
	try CheckHeaderFunc(Acc,HeaderBin,Origin,Tid) of
		Any -> Any
	catch
		Class:Reason -> {{Class,Reason}, Origin, HeaderBin}
	end,
	
	for_each_header_chunk_from_bin([Result|Acc],
		CheckHeaderFunc, Rest, Origin, Tid).


report_errornous_entries(Entries) ->
	io:format("~w errornous header entries~n", [length(Entries)])
	.


precheck_header_func(CheckedHeaders, HeaderBin, Origin, Tid) ->
	{{HashStr,_,PrevHashStr,_,_,_,_,0}=BlockHeader,<<>>} =
		protocol:read_block_header(HeaderBin),
	Hash = protocol:hash(HashStr),
	PrevHash = protocol:hash(PrevHashStr),
	
	case ets:member(Tid, Hash)
		orelse proplists:lookup(Hash, CheckedHeaders)=/=none of
		false ->
			case protocol:is_difficulty_satisfiedQ(BlockHeader) of
				true ->
					{Hash,HeaderBin,PrevHash,[],undefined};
				false ->
					{{error, not_satisfy_difficulty}, Origin, Hash}
			end;
		true -> {{error, already_have}, Origin, Hash}
	end.


climb_tree_until({_Hash,_Index,_PrevHash,NextHashes,_Height}=_Start, Goal,
	TidTree) ->
	
	try go_next_loop([],NextHashes,Goal,TidTree) of
		_NotFound -> []
	catch
		throw:Acc -> lists:reverse(Acc)
	end.

go_next_loop(Acc,[], _, _) -> Acc;
go_next_loop(Acc, [NextHash|T], {GoalHash,_,_,_,_}=Goal, TidTree) ->
	case NextHash of
		GoalHash -> throw([Goal|Acc]);
		_ ->
			[{NextHash,_,_,NextNextHashes,_}=Entry]
				= ets:lookup(TidTree, NextHash),
			go_next_loop([Entry|Acc], NextNextHashes, Goal, TidTree),
			go_next_loop(Acc, T, Goal, TidTree)
	end.


climb_tree_until_with_limit({_Hash,_Index,_PrevHash,NextHashes,_Height}=_Start,
	Goal, TidTree, Limit) when is_integer(Limit) andalso Limit>0 ->
	
	try go_next_loop_with_limit([],NextHashes,Goal,TidTree,Limit) of
		_NotFound -> []
	catch
		throw:Acc -> lists:reverse(Acc)
	end.

go_next_loop_with_limit(Acc,[], _, _, _) -> Acc;
go_next_loop_with_limit(Acc, _, _, _, 0) -> throw(Acc);
go_next_loop_with_limit(Acc, [NextHash|T], {GoalHash,_,_,_,_}=Goal, TidTree,
	Limit) ->
	case NextHash of
		GoalHash -> throw([Goal|Acc]);
		_ ->
			[{NextHash,_,_,NextNextHashes,_}=Entry]
				= ets:lookup(TidTree, NextHash),
			go_next_loop_with_limit([Entry|Acc], NextNextHashes, Goal,
				TidTree, Limit-1),
			go_next_loop_with_limit(Acc, T, Goal, TidTree, Limit)
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


go_down_tree_before({_Hash,_Index,PrevHash,_NextHashes,_Height}=Start,
	GoalHash, TidTree) ->
	go_prev_loop([Start], PrevHash, GoalHash, TidTree).

go_prev_loop(Acc, PrevHash, GoalHash, TidTree) ->
	case PrevHash of
		GoalHash -> lists:reverse(Acc);
		_ ->
			case ets:lookup(TidTree, PrevHash) of
			[] -> throw(goal_not_found);
			[{_PrevHash,_Index,PrevPrevHash,_PrevNextHashes,_Height}=Entry]->
				go_prev_loop([Entry|Acc], PrevPrevHash, GoalHash, TidTree)
			end
	end.

go_down_tree_n_times(Entry, 0, _GenesisBlockHash, _TidTree) -> Entry;
go_down_tree_n_times({_Hash,_Index,GenesisBlockHash,_NextHashes,_Height}=Entry,
	_N, GenesisBlockHash, _TidTree) -> Entry;
go_down_tree_n_times({_Hash,_Index,PrevHash,_NextHashes,_Height}=_Start,
	N, GenesisBlockHash, TidTree) when is_integer(N) ->
	case ets:lookup(TidTree, PrevHash) of
		[] -> throw(not_connected_to_the_genesis_block);
		[Entry] ->
			go_down_tree_n_times(Entry, N-1, GenesisBlockHash, TidTree)
	end.


indexes(TreeEntries) -> [Index || {_,Index,_,_,_} <- TreeEntries].


%% sampling intervals = ceil(A * exp(n P)), n = 1,2,...
exponentially_sampled_hashes(TidTree,
	{Hash,_Index,PrevHash,[],_Height}=_Tip, {A,P}) ->
	
	N = 2,
	Gap = ceil(A*math:exp(N*P)),
	exponential_sampling_loop([Hash], PrevHash, N, {A,P}, Gap, TidTree).

exponential_sampling_loop(Acc, Hash, N, {A,P}, 1, TidTree) ->
	case ets:lookup(TidTree,Hash) of
		[] -> lists:reverse(Acc);
		[{Hash,_Index,PrevHash,_NextHashes,_Height}] ->
			N1 = N+1,
			Gap = ceil(A*math:exp(N1*P)),
			exponential_sampling_loop([Hash|Acc], PrevHash, N1, {A,P}, Gap,
				TidTree)
	end;
exponential_sampling_loop(Acc, _Hash, _N, {_A,_P}, Gap, _TidTree)
	when Gap > ?MAX_HEADERS_COUNT -> % for limiting
		lists:reverse(Acc);
exponential_sampling_loop(Acc, Hash, N, {A,P}, Gap, TidTree) ->
	case ets:lookup(TidTree,Hash) of
		[] -> lists:reverse(Acc);
		[{Hash,_Index,PrevHash,_NextHashes,_Height}] ->
			exponential_sampling_loop(Acc, PrevHash, N, {A,P}, Gap-1, TidTree)
	end.


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


%% JOBS:
%%	tips_jobs
%%	exp_sampling_jobs
%%
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

	S3 =
	case S#state.new_block_jobs of
		[] -> S2;
		NewBlockJobs -> % [{Node, BlockHash}| ...]
			% remove duplicated hashes
			NewBlockJobs1 = lists:usort(fun({_N1,H1},{_N2,H2})-> H1=<H2 end,
				NewBlockJobs),
			% remove block hashes that already exist in the headers
			NewBlockJobs2 = [Job || {_Node, Hash}=Job <- NewBlockJobs1,
				not ets:member(Tid, Hash)
				],

			[
				begin
				InvVects = [{msg_block, protocol:parse_hash(Hash)}],
				jobs:add_job({Node, {getdata, InvVects}, 60})
				end || {Node,Hash} <- NewBlockJobs2
			],
			S2#state{new_block_jobs=[]}
	end,

	S3.


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


