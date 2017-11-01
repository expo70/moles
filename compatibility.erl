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


open_blockfile_for_writing(Env, N) ->
	Path = block_data_path(Env, N),
	DirName = filename:dirname(Path)++ "/",
	ok = filelib:ensure_dir(DirName),
	{ok, _F} = file:open(Path, {write, binary, append}).

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
