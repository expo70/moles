%% update view of a Mole by using Pub/Sub system through ErlBus
%%
-module(view).

-include_lib("eunit/include/eunit.hrl").


-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export([start_link/1,
	update_blockchain/1, update_best_height/2, got_tx/0]).

-record(state,
	{
		unique_name
	}).



%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link(Coordinate) ->
	io:format("view:start_link with Coordinate = ~p~n", [Coordinate]),
	Args = [Coordinate],
	gen_server:start_link({local,?MODULE}, ?MODULE, Args, []).


%% mole
%%	update_blockchain
%%	update_best_height
%%	got_tx
%%	got_block
%%	create_block
%%	send_tx
%%	send_block
update_blockchain(PaintedTree) ->
	%io:format("view:update_blockchain~n",[]),
	View = create_blockchain_view(PaintedTree),

	%% prepare for JSON conversion
	%% change hash to string
	%% {X,Y}-coordinates to list
	%% Maps (dict in JSON) cannot be used here because the order of
	%% the blocks in the list is important.
	View1 = [[list_to_binary(u:bin_to_hexstr(Hash,"",little)),[X,Y]] || {Hash,{X,Y}} <- View],

	What = #{ cmd => update_blockchain, view => View1 },
	gen_server:cast(?MODULE, {update, What}).


update_best_height(From, To) ->
	
	What = #{ cmd => update_best_height, from => From, to => To },
	gen_server:cast(?MODULE, {update, What}).


got_tx() ->
	
	What = #{ cmd => got_tx },
	gen_server:cast(?MODULE, {update, What}).



%% ----------------------------------------------------------------------------
%% gen_server callback
%% ----------------------------------------------------------------------------
init([Coordinate]) ->
	InitialState = #state{
		unique_name = Coordinate
		},
	
	{ok, InitialState}.


handle_call(_Request, _From, S) ->
	{reply, ok, S}.


handle_cast({update, What}, S) ->
	S1 = publish_view(What, S),

	{noreply, S1}.


handle_info(_Info, S) ->
	{noreply, S}.


%% view.erl and moles_kingdom/ws_handler.erl indirectely communicate
%% with each other through PubSub node provided by ErlBus (ebus).
%% Each PubSub node is identified by its unique_name. 
%% "What" message is converted into JSON in ws_handler.erl by using jsone
%% module and sent through websocket into subscribed web browsers.
publish_view(What, S) ->
	Topic = S#state.unique_name,
	
	io:format("try to pub to topic: ~p~n", [Topic]),
	ok = ebus:pub(Topic, What),

	S.


%% ref: https://github.com/afiskon/erlang-uuid-v4
%uuid_generate() ->
%	<<A:32, B:16, C:16, D:16, E:48>> = crypto:rand_bytes(16),
%	Str = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
%		[A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
%	list_to_binary(Str).


%% produces the (X,Y)-coordinates of blocks in the blockchain from
%% blockchain:get_painted_tree() result.
%%
%% PaintTree is in proplist format.
create_blockchain_view(PaintedTree) ->
	% [{Hash,{X,Y}}, ...]
	Coords = lists:map(fun(P) -> to_coordinate(P,PaintedTree) end,
		PaintedTree),
	
	% sort the coordinates in order of increasing X and Y for drawing
	SortedByY = lists:sort(fun({_Hash1,{_X1,Y1}}, {_Hash2,{_X2,Y2}})->
		Y1 =< Y2 end, Coords),
	GatherByY = u:gather_by(fun({_Hash,{_X,Y}})->Y end, SortedByY),
	SortedByY_X = [lists:sort(fun({_Hash1,{X1,_Y1}},{_Hash2,{X2,_Y2}})->
		X1 =< X2 end, Cs) || Cs <- GatherByY],
	
	lists:append(SortedByY_X).


to_coordinate({Hash, {0,undefined,Height}}, _PaintedTree) ->
	{Hash, {Height,0}};
to_coordinate({Hash, {BranchLevel,ForkPointHash,Height}}, PaintedTree) ->
	ForkPoint = proplists:lookup(ForkPointHash, PaintedTree),
	{ForkPointHash,{X,Y}} = to_coordinate(ForkPoint, PaintedTree),
	{DeltaX,DeltaY} =
	case BranchLevel rem 2 of
		0 -> {Height,0};
		1 -> {0,Height}
	end,

	{Hash, {X+DeltaX, Y+DeltaY}}.


-ifdef(EUNIT).

create_blockchain_view_test() ->
	PaintedTree =
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
	?assertEqual(
		[
			{"H",{1,0}},
			{"G",{2,0}},
			{"F",{3,0}},
			{"E",{4,0}},
			{"D",{5,0}},
			{"C",{6,0}},
			{"B",{7,0}},
			{"A",{8,0}},
			{"J",{4,1}},
			{"I",{6,1}},
			{"K",{4,2}},
			{"M",{5,2}},
			{"L",{4,3}}
		],
		create_blockchain_view(PaintedTree)
	).




-endif.

