-module(tester).

%-export([get_binary/2]).
-compile(export_all).


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
	filename:join([bin_base_dir(Config),"tx",S++".bin"]);
bin_data_path({block, Txid},Config) ->
	S = rhash_string(Txid),
	filename:join([bin_base_dir(Config),"block",S++".bin"]).


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
