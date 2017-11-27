%% Tx
%%
%% Traditional ID of Tx, Txid, is not unique for containing transactions
%% (called Transaction Malleability).
-module(tx).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-export([start_link/1, add_to_mempool/2]).

-record(state,{
		mempool_dir
	}).


start_link(NetType) ->
	Args = [NetType],
	gen_server:start_link({local,?MODULE},?MODULE,Args,[]).


add_to_mempool({Type, Hash, Payload}, Origin) ->
	gen_server:cast(?MODULE, {add_to_mempool, {Type, Hash, Payload}, Origin}).


%% ----------------------------------------------------------------------------
%% gen_server callback
%% ----------------------------------------------------------------------------
init([NetType]) ->
	MempoolDir =
	case NetType of
		mainnet  -> "./mainnet/mempool";
		testnet  -> "./testnet/mempool";
		regtest  -> "./regtest/mempool"
	end,
	
	ok = filelib:ensure_dir(MempoolDir++'/'),

	InitialState = #state{
			mempool_dir = MempoolDir
		},

	{ok, InitialState}.


handle_call(_Request, _From, S) ->
	{reply, ok, S}.


handle_cast({add_to_mempool, {Type, Hash, Payload}, _Origin}, S) ->
	Filename = entry_to_saved_filename({Type, Hash}),

	{ok,F} = file:open(filename:join(S#state.mempool_dir, Filename),
		[write,binary]),
	ok = file:write(F, Payload),
	file:close(F),

	{noreply, S}.


handle_info(_Info, S) ->
	{noreply, S}.


%% ----------------------------------------------------------------------------
%% internal functions
%% ----------------------------------------------------------------------------
entry_to_saved_filename({Type, Hash}) ->
	case Type of
		tx ->
			HashStr = u:bin_to_hexstr(Hash),
			lists:concat([HashStr, ".", Type]);
		block ->
			% use little-endian to make string hash match block-explorer etc.
			HashStr = u:bin_to_hexstr(Hash,"",little),
			lists:concat([HashStr, ".", Type])
	end.
