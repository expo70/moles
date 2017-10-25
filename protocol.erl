%% Bitcoin Protocol
%% as described in https://en.bitcoin.it/wiki/Protocol_documentation
-module(protocol).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all]).



read_message(<<>>) -> {error, empty};
read_message(<<16#D9B4BEF9:32/little, Rest/binary>>) -> read_message(mainnet, Rest); 
read_message(<<16#DAB5BFFA:32/little, Rest/binary>>) -> read_message(regtest, Rest); 
read_message(<<16#0709110B:32/little, Rest/binary>>) -> read_message(testnet, Rest); 
read_message(<<16#FEB4BEF9:32/little, Rest/binary>>) -> read_message(namecoin, Rest). 

read_message(NetType, <<BinCommand:12/binary, Length:32/little, Checksum:4/binary, Payload:Length/binary, Rest/binary>>) ->
	Command = bin12_to_atom(BinCommand),
	<<RealChecksum:4/binary, _/binary>> = dhash(Payload),
	
	case RealChecksum of
		Checksum -> {ok, {NetType, Command, Payload, Rest}};
		       _ -> {error, checksum, {NetType, Rest}}
	end;
read_message(NetType,Bin) ->
	Magic = magic(NetType),
	{error, incomplete, <<Magic:32/little, Bin/binary>>}.

parse_version(<<MyProtocolVersion:32/little, MyServices:64/little, Timestamp:64/little, AddrRecv:26/binary, Rest/binary>>) ->
	MyServicesType = parse_services(MyServices),
	{Time, PeerServicesType, PeerAddress, PeerPort} = parse_net_addr(AddrRecv),
	parse_version1({{MyServicesType, MyProtocolVersion}, Timestamp, {PeerAddress, PeerPort}, PeerServicesType, Time}, Rest).

parse_version1(B1, <<>>) -> {B1,{},{}};
parse_version1(B1, Rest) ->
	<<AddrFrom:26/binary, Nonce:64/little, Rest1/binary>> = Rest,
	{Time, MyServicesType, MyAddress, MyPort} = parse_net_addr(AddrFrom),
	{StrUserAgent, Rest2} = read_var_str(Rest1),
	<<StartBlockHeight:32/little, Rest3/binary>> = Rest2,
	parse_version2(B1, {{MyAddress, MyPort}, MyServicesType, Time, Nonce, StrUserAgent, StartBlockHeight}, Rest3).

parse_version2(B1, B2, <<>>) -> {B1,B2,{}};
parse_version2(B1, B2, Rest) ->
	<<Relay>> = Rest,
	RelayQ = parse_bool(Relay),
	{B1, B2, {RelayQ}}.

version(NetType, {PeerAddress, PeerPort, PeerServicesType, PeerProtocolVersion}, {MyAddress, MyPort, MyServicesType, MyProtocolVersion}, StrUserAgent, StartBlockHeight, RelayQ) ->
	MyServices   = services(MyServicesType),
	Timestamp = unix_timestamp(),
	% time field is not present in version message.
	<<_:32, AddrRecv/binary>> = net_addr(PeerAddress, PeerPort, {PeerServicesType, PeerProtocolVersion}),
	<<_:32, AddrFrom/binary>> = net_addr(MyAddress, MyPort,   {MyServicesType, MyProtocolVersion}),
	Nonce = nonce64(),
	UserAgent = var_str(StrUserAgent),
	Relay = case RelayQ of
		true  -> 1;
		false -> 0
	end,

	B1 = <<MyProtocolVersion:32/little, MyServices:64/little, Timestamp:64/little, AddrRecv/binary>>,
	B2 = <<AddrFrom/binary, Nonce:64/little, UserAgent/binary, StartBlockHeight:32/little>>,
	B3 = <<Relay:8>>,
	
	Payload = if
		MyProtocolVersion >= 70001 -> <<B1/binary,B2/binary,B3/binary>>;
		MyProtocolVersion >=   106 -> <<B1/binary,B2/binary>>;
		MyProtocolVersion <    106 -> B1
	end,

	message(NetType, version, Payload).

%% verack message
verack(NetType) -> message(NetType, verack, <<>>).

%% getaddr message
getaddr(NetType) -> message(NetType, getaddr, <<>>).

%% mempool message
mempool(NetType, ProtocolVersion) when ProtocolVersion >= 60002 ->
	message(NetType, mempool, <<>>).

%% sendheaders message
sendheaders(NetType, ProtocolVersion) when ProtocolVersion >= 70012 ->
	message(NetType, sendheaders, <<>>).

parse_verack(<<>>) -> ok.

parse_sendheaders(<<>>) -> ok.

%% ping message
ping(NetType) ->
	Nonce = nonce64,
	message(NetType, ping, <<Nonce:64/little>>).

parse_ping(<<Nonce:64/little>>) -> Nonce.

pong(NetType, Nonce) -> message(NetType, pong, <<Nonce:64/little>>).







message(NetType, Command, Payload) ->
	Magic = magic(NetType),
	BinCommand = atom_to_bin12(Command),
	Length = byte_size(Payload),
	<<Checksum:4/binary, _/binary>> = dhash(Payload),

	<<Magic:32/little, BinCommand/binary, Length:32/little, Checksum/binary, Payload/binary>>.


%% net_addr
net_addr({A,B,C,D}, Port, {ServicesType, MyProtocolVersion}) ->
	Time = unix_timestamp(),
	Services = services(ServicesType),
	IP6Address = <<0:(8*10), 16#FF, 16#FF, A:8, B:8, C:8, D:8>>,
	if
		MyProtocolVersion >= 31402 -> <<Time:32/little, Services:64/little, IP6Address:16/binary, Port:16/big>>;
		MyProtocolVersion <  31402 -> <<                Services:64/little, IP6Address:16/binary, Port:16/big>>
	end.

parse_net_addr(<<Time:32/little, Rest:(8+16+2)/binary>>) -> parse_net_addr(Time, Rest);
parse_net_addr(<<Bin:(8+16+2)/binary>>) -> parse_net_addr(null, Bin).

parse_net_addr(Time, <<Services:64/little, IPAddress:16/binary, Port:16/big>>) ->
	{Time, parse_services(Services), parse_ip_address(IPAddress), Port}.

read_net_addr(Bin, ProtocolVersion) ->
	if
		ProtocolVersion >= 31402 ->
			<<Time:32/little, Services:64/little, IPAddress:16/binary, Port:16/big, Rest/binary>> = Bin;
		ProtocolVersion <  31402 ->
			Time=null,
			<<Services:64/little, IPAddress:16/binary, Port:16/big, Rest/binary>> = Bin
	end,
	{{Time, parse_services(Services), parse_ip_address(IPAddress), Port}, Rest}.

read_net_addr_n(Bin, N, ProtocolVersion) -> read_net_addr_n([], N, Bin, ProtocolVersion).

read_net_addr_n(Acc, 0, Bin, _ProtocolVersion) -> {lists:reverse(Acc), Bin};
read_net_addr_n(Acc, N, Bin, ProtocolVersion) when is_integer(N), N>0 ->
	{NetAddr, Rest} = read_net_addr(Bin, ProtocolVersion),
	read_net_addr_n([NetAddr|Acc], N-1, Rest, ProtocolVersion).

%% addr message
parse_addr(Bin, ProtocolVersion) ->
	{Count, Rest} = read_var_int(Bin),
	{NetAddrs, _Rest1} = read_net_addr_n(Rest, Count, ProtocolVersion),
	NetAddrs.


%% IP Address
parse_ip_address(<<0:(8*10), 16#FF, 16#FF, A, B, C, D>>) -> {A,B,C,D}; %IP4
parse_ip_address(<<E:16/big, F:16/big, G:16/big, H:16/big, I:16/big, J:16/big, K:16/big, L:16/big>>) -> {E,F,G,H,I,J,K,L}. %IP6


%% inv_vect
inv_vect({ObjectType, HashStr}) ->
	Type = object_type(ObjectType),
	Hash = hash(HashStr),
	<<Type:32/little, Hash:32/binary>>.

read_inv_vect(<<Type:32/little, Hash:32/binary, Rest/binary>>) ->
	ObjectType = parse_object_type(Type),
	{{ObjectType, parse_hash(Hash)}, Rest}.

read_inv_vect_n(Bin, N) -> read_inv_vect_n([], N, Bin).

read_inv_vect_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_inv_vect_n(Acc, N, Bin) when is_integer(N), N>0 ->
	{InvVect, Rest} = read_inv_vect(Bin),
	read_inv_vect_n([InvVect|Acc], N-1, Rest).

%% inv message
parse_inv(Bin) ->
	{Count, Rest} = read_var_int(Bin),
	{InvVects, _Rest1} = read_inv_vect_n(Rest, Count),
	InvVects.

%% getdata message
getdata(NetType, InvVects) when is_list(InvVects) ->
	CountBin = var_int(length(InvVects)),
	InvVectsBin = list_to_binary([inv_vect(I) || I <- InvVects]),
	Payload = <<CountBin/binary, InvVectsBin/binary>>,
	
	message(NetType, getdata, Payload).


%% alert message
read_alert(<<Version:32/little, RelayUntil:64/little, Expiration:64/little, ID:32/little, Cancel:32/little, Rest/binary>>) ->
	%setCancel set<int32_t>
	{Length,Rest1} = read_var_int(Rest),
	%<<Head:(Length*4)/binary, Rest2/binary>> = Rest1,
	%ListCancels = [X || <<X:32/little>> <= Head],
	{ListCancels, Rest2} = read_int32_n(Rest1, Length),
	read_alert([Version, RelayUntil, Expiration, ID, Cancel, ListCancels],Rest2).

read_alert(Props, <<MinVer:32/little, MaxVer:32/little, Rest/binary>>) ->
	%setSubVer set<var_str>
	{Length,Rest1} = read_var_int(Rest),
	{ListSubVers, Rest2} = read_var_str_n(Rest1,Length),
	<<Priority:32/little, Rest3/binary>> = Rest2,
	{Comment, Rest4} = read_var_str(Rest3),
	{StatusBar, Rest5} = read_var_str(Rest4),
	{Reserved, Rest6} = read_var_str(Rest5),
	{list_to_tuple(Props++[MinVer, MaxVer, ListSubVers, Priority, Comment, StatusBar, Reserved]), Rest6}.

%% getblocks message
getblocks(NetType, {ProtocolVersion, Hashes, HashStop}) ->
	HashCount = var_int(length(Hashes)),
	HashesBin = [hash(H) || H <- Hashes],
	HashStopBin = hash(HashStop),
	Payload = list_to_binary([<<ProtocolVersion:32/little, HashCount/binary>>, HashesBin, <<HashStopBin/binary>>]),
	message(NetType, getblocks, Payload).

parse_getblocks(<<ProtocolVersion:32/little, Rest/binary>>) ->
	{_HashCount, Rest1} = read_var_int(Rest),
	RHashes = lists:reverse(partition(binary_to_list(Rest1), 32)),
	{ProtocolVersion, [parse_hash(list_to_binary(L)) || L <-lists:reverse(tl(RHashes))], parse_hash(list_to_binary(hd(RHashes)))}.


%% getheaders message
%NOTE: similar to getblocks()
getheaders(NetType, {ProtocolVersion, Hashes, HashStop}) ->
	HashCount = var_int(length(Hashes)),
	HashesBin = [hash(H) || H <- Hashes],
	HashStopBin = hash(HashStop),
	Payload = list_to_binary([<<ProtocolVersion:32/little, HashCount/binary>>, HashesBin, <<HashStopBin/binary>>]),
	message(NetType, getheaders, Payload).

parse_getheaders(Bin) -> parse_getblocks(Bin).


%% Tx
read_tx(<<Version:32/little-signed, 0, 1, Rest/binary>>) -> read_tx(Version, true, Rest);
read_tx(<<Version:32/little-signed, Rest/binary>>) -> read_tx(Version, false, Rest).

read_tx(Version, _HasWitnessQ, Rest) ->
	{TxInCount, Rest1} = read_var_int(Rest),
	{TxIns, Rest2} = read_tx_in_n(Rest1, TxInCount),
	{TxOutCount, Rest3} = read_var_int(Rest2),
	{TxOuts, Rest4} = read_tx_out_n(Rest3, TxOutCount),
	<<LockTime:32/little, Rest5/binary>> = Rest4,

	{{Version, TxIns, TxOuts, LockTime}, Rest5}.

read_tx_n(Bin, N) -> read_tx_n([], N, Bin).

read_tx_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_tx_n(Acc, N, Bin) when is_integer(N), N>0 ->
	{Tx, Rest} = read_tx(Bin),
	read_tx_n([Tx|Acc], N-1, Rest).


%% TxIn
read_tx_in_n(Bin, N) ->
	read_tx_in_n([], N, Bin).

read_tx_in_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_tx_in_n(Acc, N, Bin) when is_integer(N), N>0 ->
	<<PreviousOutput:36/binary, Rest/binary>> = Bin,
	{ScriptLength, Rest1} = read_var_int(Rest),
	<<SignatureScript:ScriptLength/binary, Rest2/binary>> = Rest1,
	<<Sequence:32/little, Rest3/binary>> = Rest2,
	read_tx_in_n([{parse_outpoint(PreviousOutput), bin_to_hexstr(SignatureScript), Sequence}|Acc], N-1, Rest3).

%% Outpoint
parse_outpoint(<<Hash:32/binary, Index:32/little>>) -> {parse_hash(Hash), Index}.

%% TxOut
read_tx_out_n(Bin, N) -> read_tx_out_n([], N, Bin).

read_tx_out_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_tx_out_n(Acc, N, Bin) when is_integer(N), N>0 ->
	<<Value:64/little, Rest/binary>> = Bin,
	{PkScriptLength, Rest1} = read_var_int(Rest),
	<<PkScript:PkScriptLength/binary, Rest2/binary>> = Rest1,
	read_tx_out_n([{Value, parse_script(PkScript)}|Acc], N-1, Rest2).

%% Block
read_block(Bin) ->
	{{_Version, _PrevBlockHash, _MerkleRootHash, _Timestamp, _Bits, _Nonce, TxnCount}=BlockHeader, Rest} = read_block_header(Bin),
	{Txs, Rest1} = read_tx_n(Rest, TxnCount),
	{{BlockHeader, Txs}, Rest1}.

read_block_n(Bin, N) -> read_block_n([], N, Bin).

read_block_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_block_n(Acc, N, Bin) when is_integer(N), N>0 ->
	{Block, Rest} = read_block(Bin),
	read_block_n([Block|Acc], N-1, Rest).

%% Block Hash
%% https://en.bitcoin.it/wiki/Block_hashing_algorithm
block_hash(Version, PrevBlock, MerkleRoot, Timestamp, Bits, Nonce) ->
	dhash(<<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary, Timestamp:32/little, Bits:32/little, Nonce:32/little>>).


%% Block Header
read_block_header(<<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary, Timestamp:32/little, Bits:32/little, Nonce:32/little, Rest/binary>>) ->
	Hash = block_hash(Version, PrevBlock, MerkleRoot, Timestamp, Bits, Nonce),
	{TxnCount, Rest1} = read_var_int(Rest),
	{{parse_hash(Hash), Version, parse_hash(PrevBlock), parse_hash(MerkleRoot), Timestamp, Bits, Nonce, TxnCount}, Rest1}.

read_block_header_n(Bin, N) -> read_block_header_n([], N, Bin).

read_block_header_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_block_header_n(Acc, N, Bin) when is_integer(N), N>0 ->
	{BlockHeader, Rest} = read_block_header(Bin),
	read_block_header_n([BlockHeader|Acc], N-1, Rest).


%% headers message
parse_headers(Bin) ->
	{Count, Rest} = read_var_int(Bin),
	{Headers, _Rest1} = read_block_header_n(Rest, Count),
	Headers.


%% blocks message
parse_blocks(Bin) ->
	{Count, Rest} = read_var_int(Bin),
	{Blocks, _Rest1} = read_block_n(Rest, Count),
	Blocks.


%% reject message
parse_reject(Bin) ->
	{MessageType, Rest} = read_var_str(Bin),
	<<CCode, Rest1/binary>> = Rest,
	{Reason, Rest2} = read_var_str(Rest1),

	{list_to_atom(MessageType), parse_ccode(CCode), Reason, Rest2}.

parse_ccode(C) ->
	case C of
		16#01 -> reject_malformed;
		16#10 -> reject_invalid;
		16#11 -> reject_obsolete;
		16#12 -> reject_duplicate;
		16#40 -> reject_nonstandard;
		16#41 -> reject_dust;
		16#42 -> reject_insufficientfee;
		16#43 -> reject_checkpoint;
		_Other -> C
	end.



%% Services

% see ServiceFlags in bitcoin-master/src/protoco.h
services(ServicesType) when not is_list(ServicesType) ->
	services(0, [ServicesType]);
services(ServicesType) when is_list(ServicesType) ->
	services(0, ServicesType).

services(Acc, []) -> Acc;
services(Acc, [H|T]) ->
	case H of
		node_none    -> services(Acc+0, T);

		node_network -> services(Acc+1, T);
		node_getutxo -> services(Acc+2, T);
		node_bloom   -> services(Acc+4, T);
		node_witness -> services(Acc+8, T);
		node_xthin   -> services(Acc+16, T)
	end.

parse_services(0)        -> []; % node_none
parse_services(Services) -> parse_services([], 5, Services). %NOTE: ignores the other uknown flags

parse_services(Acc, 0, _Services) -> lists:reverse(Acc);
parse_services(Acc, N, Services) when is_integer(N), N>0 ->
	case Services band (2#1 bsl (N-1)) of
		0     -> parse_services(Acc, N-1, Services);
		_Other ->
			H = case N of
				1 -> node_network;
				2 -> node_getutxo;
				3 -> node_bloom;
				4 -> node_witness;
				5 -> node_xthin
			end,
			parse_services([H|Acc], N-1, Services)
	end.

parse_bool(0) -> false;
parse_bool(1) -> true.

magic(NetType) ->
	case NetType of
		mainnet  -> 16#D9B4BEF9;
		%testnet  -> 16#DAB5BFFA;
		regtest  -> 16#DAB5BFFA;
		testnet  -> 16#0709110B;
		namecoin -> 16#FEB4BEF9
	end.

object_type(ObjectType) ->
	case ObjectType of
		error              -> 0;
		msg_tx             -> 1;
		msg_block          -> 2;
		msg_filtered_block -> 3;
		msg_cmpct_block    -> 4
	end.

parse_object_type(Type) ->
	case Type of
		0 -> error;
		1 -> msg_tx;
		2 -> msg_block;
		3 -> msg_filtered_block;
		4 -> msg_cmpct_block
	end.

% CompactSize
var_int(X) when X <  16#FD -> <<X>>;
var_int(X) when X =< 16#FFFF -> <<16#FD, X:16/little>>;
var_int(X) when X =< 16#FFFFFFFF -> <<16#FE, X:32/little>>;
var_int(X) when X =< 16#FFFFFFFFFFFFFFFF -> <<16#FF, X:64/little>>.

read_var_int(<<16#FF, X:64/little, Rest/binary>>) -> {X, Rest};
read_var_int(<<16#FE, X:32/little, Rest/binary>>) -> {X, Rest};
read_var_int(<<16#FD, X:16/little, Rest/binary>>) -> {X, Rest};
read_var_int(<<X, Rest/binary>>) -> {X, Rest}.

var_str(Str) ->
	Bin = list_to_binary(Str),
	Length = var_int(byte_size(Bin)),
	<<Length/binary, Bin/binary>>.

read_var_str(Bin) ->
	{Length, Rest} = read_var_int(Bin),
	<<Str:Length/binary, Rest1/binary>> = Rest,
	{binary_to_list(Str), Rest1}.

read_var_str_n(Bin, N) -> read_var_str_n([], N, Bin).

read_var_str_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_var_str_n(Acc, N, Bin) when is_integer(N), N>0 ->
	{Str, Rest} = read_var_str(Bin),
	read_var_str_n([Str|Acc], N-1, Rest).

read_int32_n(Bin, N) -> read_int32_n([], N, Bin).

read_int32_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_int32_n(Acc, N, Bin) when is_integer(N), N>0 ->
	<<Int:32/little, Rest/binary>> = Bin,
	read_int32_n([Int|Acc], N-1, Rest).

atom_to_binary(Atom) -> list_to_binary(atom_to_list(Atom)).


atom_to_bin12(Command) ->
	BinCommand = atom_to_binary(Command),
	Len = byte_size(BinCommand),
	<<BinCommand/binary,0:(8*(12-Len))>>.

bin12_to_atom(Bin) when byte_size(Bin) == 12 ->
	L = string:strip(binary_to_list(Bin), right, 0),
	list_to_atom(L).

dhash(Bin) -> crypto:hash(sha256, crypto:hash(sha256, Bin)).

parse_hash(<<Hash:32/binary>>) -> bin_to_hexstr(Hash).
hash(Str) when length(Str)==2*32 ->
	hexstr_to_bin(Str).

unix_timestamp() ->
	{Mega, Secs, _} = erlang:timestamp(),
	Timestamp = Mega*1000000 + Secs,
	Timestamp.

bin_to_hexstr(Bin) -> bin_to_hexstr(Bin,"").

bin_to_hexstr(Bin,Sep) ->
  string:to_lower(lists:flatten(string:join([io_lib:format("~2.16.0B", [X]) ||
      X <- binary_to_list(Bin)], Sep))).

hexstr_to_bin("") -> <<>>;
hexstr_to_bin(Str) ->
	T = partition(Str, 2),
	list_to_binary([list_to_integer(S,16) || S <- T]).

hexstr_to_bin(Str,Sep) ->
	T = string:tokens(Str,Sep),
	list_to_binary([list_to_integer(S,16) || S <- T]).


% from https://stackoverflow.com/questions/31395608/how-to-split-a-list-of-strings-into-given-number-of-lists-in-erlang
partition(L, N) when is_integer(N), N > 0 ->
	partition(N, 0, L, []).

partition(_, _, [], Acc) ->
	[lists:reverse(Acc)];
partition(N, N, L, Acc) ->
	[lists:reverse(Acc) | partition(N, 0, L, [])];
partition(N, X, [H|T], Acc) ->
	partition(N, X+1, T, [H|Acc]).


nonce64() ->
	% 2^64
	rand:uniform(18446744073709551616)-1.


%% Script

parse_script(Bin) ->
	[parse_op(B) || B <- binary_to_list(Bin)].

parse_op(Byte) ->
	case Byte of
		0   -> op_0;
		76  -> op_pushdata1;
		77  -> op_pushdata2;
		78  -> op_pushdata4;
		79  -> op_1negate;
		81  -> op_1;
		82  -> op_2;
		83  -> op_3;
		84  -> op_4;
		85  -> op_5;
		86  -> op_6;
		87  -> op_7;
		88  -> op_8;
		89  -> op_9;
		90  -> op_10;
		91  -> op_11;
		92  -> op_12;
		93  -> op_13;
		94  -> op_14;
		95  -> op_15;
		96  -> op_16;
		97  -> op_nop;
		99  -> op_if;
		100 -> op_notif;
		103 -> op_else;
		104 -> op_endif;
		105 -> op_verify;
		106 -> op_return;
		107 -> op_toaltstack;
		108 -> op_fromaltstack;
		115 -> op_ifdup;
		116 -> op_depth;
		117 -> op_drop;
		118 -> op_dup;
		119 -> op_nip;
		120 -> op_over;
		121 -> op_pick;
		122 -> op_roll;
		123 -> op_rot;
		124 -> op_swap;
		125 -> op_tuck;
		109 -> op_2drop;
		110 -> op_2dup;
		111 -> op_3dup;
		112 -> op_2over;
		113 -> op_2rot;
		114 -> op_2swap;
		126 -> op_cat;
		127 -> op_substr;
		128 -> op_left;
		129 -> op_right;
		130 -> op_size;
		131 -> op_invert;
		132 -> op_and;
		133 -> op_or;
		134 -> op_xor;
		135 -> op_equal;
		136 -> op_equalverify;
		139 -> op_1add;
		140 -> op_1sub;
		141 -> op_2mul;
		142 -> op_2div;
		143 -> op_negate;
		144 -> op_abs;
		145 -> op_not;
		146 -> op_0notequal;
		147 -> op_add;
		149 -> op_sub;
		150 -> op_div;
		151 -> op_mod;
		152 -> op_lshift;
		153 -> op_rshift;
		154 -> op_booland;
		155 -> op_boolor;
		156 -> op_numequal;
		157 -> op_numequalverify;
		158 -> op_numnotequal;
		159 -> op_lessthan;
		160 -> op_greaterthan;
		161 -> op_lessthanorequal;
		162 -> op_greaterthanorequal;
		163 -> op_min;
		164 -> op_max;
		165 -> op_within;
		166 -> op_ripemd160;
		167 -> op_sha1;
		168 -> op_sha256;
		169 -> op_hash160;
		170 -> op_hash256;
		171 -> op_codeseparator;
		172 -> op_checksig;
		173 -> op_checksigverify;
		174 -> op_checkmultisig;
		175 -> op_checkmutisigverify;
		177 -> op_checklocktimeverify;
		178 -> op_checksequenceverify;
		253 -> op_pubkeyhash;
		254 -> op_pubkey;
		255 -> op_invalidopcode;
		Other -> Other
	end.


-ifdef(EUNIT).

var_str_test_() ->
	[
		?_assertEqual(var_str(""), <<0>>),
		?_assertEqual(var_str("ABC"), <<3,"ABC">>)
	].

atom_to_bin12_test_() ->
	[
		?_assertEqual(atom_to_bin12(version), <<"version","\0\0\0\0\0">>)
	].

bin12_to_atom_test_() ->
	[
		?_assertEqual(bin12_to_atom(atom_to_bin12(version)), version)
	].

bin_to_hexstr_test_() ->
	[
		?_assertEqual(bin_to_hexstr(<<>>), ""),
		?_assertEqual(bin_to_hexstr(<<1,2,3,16#FF>>), "010203FF"),
		?_assertEqual(bin_to_hexstr(<<1,2,3,16#FF>>, " "), "01 02 03 FF")
	].

hexstr_to_bin_test_() ->
	[
		?_assertEqual(hexstr_to_bin(""), <<>>),
		?_assertEqual(hexstr_to_bin(bin_to_hexstr(<<1,2,3,16#FF>>)), <<1,2,3,16#FF>>),
		?_assertEqual(hexstr_to_bin(bin_to_hexstr(<<1,2,3,16#FF>>, " "), " "), <<1,2,3,16#FF>>)
	].

read_var_int_test_() ->
	[
		?_assertEqual(read_var_int(var_int(0)), {0,<<>>}),
		?_assertEqual(read_var_int(var_int(16#FF)), {16#FF,<<>>})
	].

read_var_str_test_() ->
	[
		?_assertEqual(read_var_str(var_str("")), {"",<<>>}),
		?_assertEqual(read_var_str(var_str("ABC")), {"ABC",<<>>})
	
	].
services_test_() ->
	[
		?_assertEqual(services([]), 0),
		?_assertEqual(services(node_network), 1),
		?_assertEqual(services(node_none), 0),
		?_assertEqual(services([node_network, node_bloom, node_witness]), 13)
	].


-endif.

