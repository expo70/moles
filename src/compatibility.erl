%% Some functions for compatibilities with bitcoind
%%
-module(compatibility).
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-define(MAX_BLOCKFILE_SIZE, 16#8000000). % defined in bitcoin/src/validation.h

-define(BASE58_CHARACTERS, "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz").

-record(env, {base_path, net_type}).


%% blk*****.dat
block_data_path(Env, N) when is_integer(N), 0=<N, N=<99999 ->
	%NOTE: nested lists will be flatten by filename:join
	BaseName = io_lib:format("blk~5..0B.dat", [N]),
	NetDirName =
		case Env#env.net_type of
			mainnet -> "";
			testnet -> "testnet3";
			regtest -> "regtest"
		end,
	filename:join([Env#env.base_path, NetDirName, "blocks", BaseName]).


available_byte_size_of_blockfile(Env, N) ->
	%NOTE: filelib:file_size returns 0 when the file does not exist.
	?MAX_BLOCKFILE_SIZE - filelib:file_size(block_data_path(Env, N)).


%FIXME, not completed
open_blockfile_for_writing(Env, N) ->
	Path = block_data_path(Env, N),
	DirName = filename:dirname(Path)++ "/",
	ok = filelib:ensure_dir(DirName),
	file:open(Path, {write, binary, append}).


%% [Entry]
%% Entry = {Hash, Index, PrevHash, []}
header_entry_from_block({BlockHeader, _Txs}) ->
	{HashStr, _Version, PrevBlockHashStr, _MerkleRootHash,
		_TimeStamp, _Bits, _Nonce, _TxCount} = BlockHeader,
	
	{protocol:hash(HashStr), null, protocol:hash(PrevBlockHashStr), []}.

create_header_index_from_block_data(Path, MaxBlockCount) ->
	Entries = for_each_block_chunk(Path, fun header_entry_from_block/1,
		MaxBlockCount),
	[{Hash, {StartPos, Size}, PrevBlockHash, []} 
		|| {{StartPos, Size}, {Hash, null, PrevBlockHash, []}} <- Entries].


for_each_block_chunk(BlockDataPath, ProcessBlockFunc, MaxBlockCount) ->
	{ok,F} = file:open(BlockDataPath, [read, binary]),
	FileSize = filelib:file_size(BlockDataPath),
	block_chunk_loop([], F, ProcessBlockFunc, {FileSize, FileSize}, {1,MaxBlockCount}).

%FIXME, refactor by using file:position(F,cur)
block_chunk_loop(Acc, F, ProcessBlockFunc, {RestSize, TotalSize}, {I,MaxBlockCount}) ->
	if
		I =< MaxBlockCount ->
			case file:read(F, 4+4) of
				{ok, <<_Magic:32/little, Size:32/little>>} ->
					{ok, Bin} = file:read(F, Size),
					{Block,<<>>} = protocol:read_block(Bin),
					Result = ProcessBlockFunc(Block),
					BlockStartPos = TotalSize-RestSize+(4+4),
					RestSize1 = RestSize-Size-(4+4),
					block_chunk_loop([{{BlockStartPos,Size},Result}|Acc],
					F, ProcessBlockFunc, {RestSize1, TotalSize},{I+1,MaxBlockCount});
				eof ->
					file:close(F),
					lists:reverse(Acc)
			end;
		I > MaxBlockCount ->
			file:close(F),
			lists:reverse(Acc)
	end.





%% Encodings of payment address etc.
%% ref: https://en.bitcoin.it/wiki/Base58Check_encoding
base58_encode(Bin) ->
	Size = 8*byte_size(Bin),
	<<Num:Size/big>> = Bin,
	Digits  = base58_loop([],Num),
	Digits1 = base58_move_00(Digits, binary_to_list(Bin)),
	Digits1.

base58_loop([], 0) -> [lists:nth(0+1,?BASE58_CHARACTERS)];
base58_loop(Acc, 0) -> Acc;
base58_loop(Acc, N) when is_integer(N), N >= 0 ->
	Q = N div 58,
	R = N rem 58,
	base58_loop([lists:nth(R+1,?BASE58_CHARACTERS)|Acc], Q).

base58_move_00(Digits, []) -> Digits;
base58_move_00(Digits, [H|T]) ->
	case H of
		0 -> base58_move_00([lists:nth(0+1,?BASE58_CHARACTERS)|Digits],T);
		1 -> Digits
	end.

%% ref: https://en.bitcoin.it/wiki/List_of_address_prefixes
base58check_encode(Env, Type, Value) ->
	PrefixBytes =
		case Env#env.net_type of
			mainnet ->
				case Type of
					p2pkh_pubkey_hash -> <<0>>;
					p2sh_script_hash  -> <<5>>
				end;
			testnet ->
				case Type of
					p2pkh_pubkey_hash -> <<111>>;
					p2sh_script_hash  -> <<196>>
				end
		end,
	ExtendedValue = <<PrefixBytes/binary,Value/binary>>,
	<<CheckSum:4/binary,_/binary>> = protocol:dhash(ExtendedValue),
	base58_encode(<<ExtendedValue/binary,CheckSum/binary>>).


-ifdef(EUNIT).

base58check_encode_test_() ->
	[
		?_assertEqual(base58check_encode(#env{net_type=mainnet}, p2pkh_pubkey_hash, protocol:hexstr_to_bin("010966776006953D5567439E5E39F86A0D273BEE")),"16UwLL9Risc3QfPqBUvKofHmBQ7wMtjvM")
	].

-endif.
