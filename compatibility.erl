%% Some functions for compatibilities with bitcoind
%%
-module(compatibility).

-compile(export_all).

-define(MAX_BLOCKFILE_SIZE, 16#8000000). % defined in bitcoin/src/validation.h

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


