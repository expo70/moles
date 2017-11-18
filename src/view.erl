%% update view of a Mole by using Pub/Sub system through ErlBus
%%
-module(view).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export([start_link/1, update/1]).

-record(state,
	{
		unique_name
	}).




start_link(Coordinate) ->
	Args = [Coordinate],
	gen_server:start_link({local,?MODULE}, ?MODULE, Args, []).


%% mole
%%	update_tree
%%	get_tx
%%	get_block
%%	create_block
%%	send_tx
%%	send_block
update(What) ->
	gen_server:cast(?MODULE, {update, What}).


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


publish_view(What, S) ->
	ebus:pub(S#state.unique_name, What),

	S.


%% ref: https://github.com/afiskon/erlang-uuid-v4
%uuid_generate() ->
%	<<A:32, B:16, C:16, D:16, E:48>> = crypto:rand_bytes(16),
%	Str = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
%		[A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
%	list_to_binary(Str).
