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


add_to_mempool({ObjectType, Payload}, Origin) ->
	gen_server:cast(?MODULE, {add_to_mempool, {ObjectType, Payload}, Origin}).


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


handle_cast({add_to_mempool, {ObjectType, Payload}, _Origin}, S) ->
	HashStr = u:bin_to_hexstr(crypto:hash(sha256, Payload)),
	Filename = lists:concat([HashStr, ".", ObjectType]),

	{ok,F} = file:open(filename:join(S#state.mempool_dir, Filename),
		[write,binary]),
	ok = file:write(F, Payload),
	file:close(F),

	{noreply, S}.


handle_info(_Info, S) ->
	{noreply, S}.

