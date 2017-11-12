-module(tester).
-include_lib("eunit/include/eunit.hrl").

%-export([get_binary/2]).
-compile(export_all).

-define(HASH256_ZERO, "0000000000000000000000000000000000000000000000000000000000000000").


default_config() -> #{
	%NOTE: anonymous function seems not to be exported outside the module.
	%http_get => fun(URL)-> io:cmd(lists:flatten(
	%	io_lib:format("wget -q -O - ~s",[URL]))) end,
	overwriteQ => false,
	bin_ext => ".bin",
	bin_base_dir => ['HOME',"moles/tester-data"]
}.


http_get_func() -> 
	fun(URL)-> os:cmd(lists:flatten(
		io_lib:format("wget -q -O - ~s",[URL]))) end.


%% Hash strings are generated in the little-endian notation for 
%% external services
%% 
%% Hash :: binary()
rhash_string(Hash) -> u:bin_to_hexstr(Hash,"",little).

bin_base_dir(Config) ->
	B = maps:get(bin_base_dir,Config),
	B1 = [
		case is_atom(I) of
			true ->  os:getenv(atom_to_list(I));
			false -> I
		end || I <- B],
	filename:join(B1).


%% Txid :: binary()
rawhex_URL({tx, Txid}, _Config) ->
	S = rhash_string(Txid),
	lists:flatten(io_lib:format("http://blockchain.info/tx/~s?format=hex",[S]));
rawhex_URL({block, Txid}, _Config) ->
	S = rhash_string(Txid),
	lists:flatten(io_lib:format("http://blockchain.info/block/~s?format=hex",[S])).


bin_data_path({tx, Txid},Config) ->
	S = rhash_string(Txid),
	filename:join([bin_base_dir(Config),"tx",S++maps:get(bin_ext,Config)]);
bin_data_path({block, BlockHash},Config) ->
	S = rhash_string(BlockHash),
	filename:join([bin_base_dir(Config),"block",S++maps:get(bin_ext,Config)]).


%% ItemType :: atom()
%% Hash :: binary()
get_binary({ItemType, HashStr},Config,Endian) when is_list(HashStr) ->
	Hash = u:hexstr_to_bin(HashStr,"",Endian),
	get_binary({ItemType, Hash},Config).

get_binary({_ItemType, Hash}=Req,Config) when is_binary(Hash) ->
	BinDataPath = bin_data_path(Req,Config),

	case (u:file_existsQ(BinDataPath)) andalso (not maps:get(overwriteQ, Config)) of
		true  ->
			{ok,Bin} = file:read_file(BinDataPath),
			Bin;
		false ->
			% download rawhex file and convert it to binary
			URL = rawhex_URL(Req,Config),
			%HttpGet = maps:get(http_get,Config),
			HttpGet = http_get_func(),
			RawHex = HttpGet(URL),
			case RawHex of
				[ ] -> <<>>; % http errors
				 _  -> 
					Bin = u:hexstr_to_bin(RawHex),
					% save the result (cache)
					Dir = filename:dirname(BinDataPath),
					ok = filelib:ensure_dir(Dir++"/"), %NOTE: "/" is required!
					{ok,F} = file:open(BinDataPath,[write,binary]),
					ok = file:write(F,Bin),
					ok = file:close(F),
					Bin
			end
	end.



read_tx_n_sizes(Bin,N) -> read_tx_n_sizes({[],byte_size(Bin)},Bin,N).

read_tx_n_sizes({Acc,_},Rest,0) -> {lists:reverse(Acc), Rest};
read_tx_n_sizes({Acc,Size},Bin,N) ->
	{{
		{TxidStr,_WTxidStr},
		_Version,
		_TxIns,
		_TxOuts,
		_Witness,
		_LockTime,
		_Template
	},Rest} = protocol:read_tx(Bin),
	NewSize = byte_size(Rest),
	read_tx_n_sizes({[{protocol:hash(TxidStr),(Size-NewSize)}|Acc],NewSize},Rest,N-1).


% record Tx starting positions for later use
create_index_from_block(BlockHash, Config) ->
	BinDataPath = bin_data_path({block, BlockHash}, Config),
	BlockByteSize = filelib:file_size(BinDataPath),
	{ok,Bin} = file:read_file(BinDataPath),

	{{HashStr,_Version,_PrevBlockHash,_MerkleRootHash,_Timestamp,_Bits,_Nonce,TxnCount}=BlockHeader, Rest} = protocol:read_block_header(Bin),

	BlockHash = protocol:hash(HashStr),
	TxStartPos = BlockByteSize - byte_size(Rest),
	{TxSizes,Rest1} = read_tx_n_sizes(Rest,TxnCount),
	<<>> = Rest1,
	TxIndex = create_tx_index({BlockHash,TxStartPos},TxSizes),
	Summary = lists:zip(
		lists:seq(1,length(TxIndex)),
		[process_Tx(Ent,fun summarize_Tx1/2,Config) || Ent <- TxIndex]
		),
	{ok,F}=file:open("./tester.txt",[write]),
	ok=io:format(F,"~w~n",[Summary]),
	ok.


create_tx_index({BlockHash,TxStartPos},TxSizes) ->
	{TxHashes,Sizes} = lists:unzip(TxSizes),
	TxOffsets = lists:reverse(lists:foldl(fun(E,Acc)->[hd(Acc)+E|Acc] end,[TxStartPos],Sizes)),
	lists:zip(TxHashes,[{BlockHash,Ofs,Siz} || {Ofs,Siz} <- lists:zip(u:most(TxOffsets),Sizes)]).


process_Tx({_TxHash, {BlockHash,Offset,Size}}=_TxIndexEntry, ProcessFunc, Config) ->
	BinDataPath = bin_data_path({block, BlockHash}, Config),
	{ok,F} = file:open(BinDataPath,[read,binary]),
	try
		{ok,_} = file:position(F, Offset),
		{ok,B} = file:read(F, Size),
		file:close(F),
		{Tx,<<>>} = protocol:read_tx(B),
		ProcessFunc(Tx, Config)
	catch
		_Class:Reason ->
			file:close(F),
			throw({failed_to_process_tx, Reason})
	end.


summarize_Tx({
		{_TxidStr,_WTxidStr},
		_Version,
		TxIns,
		TxOuts,
		Witness,
		_LockTime,
		_Template}=_Tx, _Config) ->
	
	{
		[{in,  Idx,SS}  || {Idx,_,{scriptSig,    {SS,_}},_} <- TxIns],
		[{witness, W}   || W <- Witness],
		[{out, Idx,SPK} || {Idx,_,{scriptPubKey, {SPK,_}}} <- TxOuts]
	}.

summarize_TxOut({Idx,_,{scriptPubKey, {SPK,_}}}=_TxOut, _Config) ->
	{out, Idx,SPK}.

summarize_Tx1({
		{TxidStr,_WTxidStr},
		_Version,
		TxIns,
		TxOuts,
		Witness,
		_LockTime,
		_Template}=_Tx, Config) ->
	io:format("Tx ... ~s~n",[TxidStr]),
	
	{
		[{in,  Idx,SS}  || {Idx,_,{scriptSig,    {SS,_}},_} <- TxIns],
		[{witness, W}   || W <- Witness],
		[{out, Idx,SPK} || {Idx,_,{scriptPubKey, {SPK,_}}} <- TxOuts],
		[
			begin
			case PrevTxHashStr of
				?HASH256_ZERO -> {prevOut, Idx, non_coinbase};
				_ ->
					io:format("Tx ->. ~s~n",[PrevTxHashStr]),
					Bin = get_binary({tx, protocol:hash(PrevTxHashStr)},Config),
					{{_,_,_,TO,_,_,_},<<>>} = protocol:read_tx(Bin),
					TxOut = lists:nth(Index0+1,TO),
					{prevOut, Idx, summarize_TxOut(TxOut,Config)}
			end
			end || {Idx,{PrevTxHashStr,Index0},_,_} <- TxIns
		]
	}.

