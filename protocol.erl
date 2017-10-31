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
		       _ -> {error, checksum, {NetType, Command, Payload, Rest}}
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

%% RelayQ - see BIP37
%%
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
%% BIP35
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

parse_ping(<<>>) -> null; % for older protocol versions
parse_ping(<<Nonce:64/little>>) -> Nonce.

pong(NetType, null) -> message(NetType, pong, <<>>);
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
	{date_time(Time), parse_services(Services), parse_ip_address(IPAddress), Port}.

read_net_addr(Bin, ProtocolVersion) ->
	if
		ProtocolVersion >= 31402 ->
			<<Time:32/little, Services:64/little, IPAddress:16/binary, Port:16/big, Rest/binary>> = Bin;
		ProtocolVersion <  31402 ->
			Time=null,
			<<Services:64/little, IPAddress:16/binary, Port:16/big, Rest/binary>> = Bin
	end,
	{{date_time(Time), parse_services(Services), parse_ip_address(IPAddress), Port}, Rest}.

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

% for SegWit
% see BIP-144
% marker and flag (collectly, <<0,1>>) are not included in Txid calculations
% but included in wTxid calculations
read_tx(<<Version:32/little-signed, 0, 1, Rest/binary>>) ->
	read_tx([{witness_marker_and_flag, <<0,1>>}, <<Version:32/little-signed>>], Version, true, Rest);
% for non-SegWit
read_tx(<<Version:32/little-signed, Rest/binary>>) ->
	read_tx([<<Version:32/little-signed>>], Version, false, Rest).

read_tx(TAcc, Version, HasWitnessQ, Rest) ->
	{TAcc1, TxInCount, Rest1} = read_var_int(TAcc, Rest),
	{TAcc2, TxIns, Rest2} = read_tx_in_n(TAcc1, Rest1, TxInCount),
	{TAcc3, TxOutCount, Rest3} = read_var_int(TAcc2, Rest2),
	{TAcc4, TxOuts, Rest4} = read_tx_out_n(TAcc3, Rest3, TxOutCount),
	{TAcc5, Witnesses, Rest5} =
		case HasWitnessQ of
			false -> {TAcc4, [], Rest4};
			true  ->
				{TAccWitness, Witnesses1, RestWitness} =
					read_witness_n([], Rest4, TxInCount),
				WitnessBin = list_to_binary(lists:reverse(TAccWitness)),
				{
					[{witness, WitnessBin}|TAcc4],
					Witnesses1,
					RestWitness
				}
		end,
	<<LockTime:32/little, Rest6/binary>> = Rest5,
	TAcc6 = [<<LockTime:32/little>>|TAcc5],
	T = to_template(TAcc6),
	% NOTE: wTxid of coinbase assumed to be 0, but here, 
	% we calculate the real one.
	WTxid = dhash(template_default_binary(T)),
	% when calculating traditional Txid, we skip witness-related slots
	 Txid = dhash(template_default_binary(
	 	template_fill_nth(
	 		template_fill_nth(T,{witness_marker_and_flag, <<>>},any),
			{witness, <<>>},any
		))),

	{{{parse_hash(Txid),parse_hash(WTxid)}, Version, TxIns, TxOuts, Witnesses, LockTime, T}, Rest6}.

read_tx_n(Bin, N) -> read_tx_n([], N, Bin).

read_tx_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_tx_n(Acc, N, Bin) when is_integer(N), N>0 ->
	{Tx, Rest} = read_tx(Bin),
	read_tx_n([Tx|Acc], N-1, Rest).


%% create binary template for signing Tx
%% binary fragments have been accumulated in TAcc in reverse order 
%%
%% In the template, atoms used as slots.
to_template(TAcc) ->
	L = lists:reverse(TAcc),
	concatenate_binaries(L).

concatenate_binaries(L) -> concatenate_binaries([], L).

concatenate_binaries(Acc, []) -> lists:reverse(Acc);
concatenate_binaries(Acc, [{S,_B}=H|T]) when is_atom(S) ->
	concatenate_binaries([H|Acc], T);
concatenate_binaries(Acc, [H|T]) when is_binary(H) ->
	case Acc of
		[] -> concatenate_binaries([H],T);
		[{S,_B}=_H1|_T1] when is_atom(S) ->
			concatenate_binaries([H|Acc], T);
		[H1|T1] when is_binary(H1) ->
			concatenate_binaries([<<H1/binary,H/binary>>|T1], T)
	end.

template_default_binary(T) -> template_default_binary(<<>>, T).

template_default_binary(Acc, []) -> Acc;
template_default_binary(Acc, [{S,B}=_H|T]) when is_atom(S) ->
	template_default_binary(<<Acc/binary,B/binary>>, T);
template_default_binary(Acc, [H|T]) when is_binary(H) ->
	template_default_binary(<<Acc/binary,H/binary>>, T).


%% template utilities for signature manipulations
%% fills n-th slots that match the input slot name
%% 
%% slot - {NameAtom, DefaultValue}
%% N - integer | 'any'
%% X - fun | binary
template_fill_nth(Template, {SlotName, X}, N) ->
	template_fill_nth({[], 1}, Template, {SlotName, X}, N).

template_fill_nth({Acc,_}, [], {_, _}, _) -> lists:reverse(Acc);
template_fill_nth({Acc,Next}, [{S,B}=H|T], {SlotName, X}, N) when is_atom(S) ->
	{Acc1, Next1} = 
	if
		S =:= SlotName ->
			if
				(N=:=any) orelse (Next == N) ->
					Value =
					if
						is_function(X) -> X(B);
						true           -> X
					end,
					{[Value|Acc], Next+1};
				Next /= N                    -> 
					{[H   |Acc], Next+1}
			end;
		H =/= SlotName -> {[H|Acc], Next}
	end,
	template_fill_nth({Acc1,Next1}, T, {SlotName, X}, N);
template_fill_nth({Acc,Next}, [H|T], {SlotName, Bin}, N) when is_binary(H) ->
	template_fill_nth({[H|Acc],Next}, T, {SlotName, Bin}, N).

template_to_binary(Template) ->
	list_to_binary([B || B <- Template, is_binary(B)]).


%% TxIn
%% as for Sequence, see BIP68
read_tx_in_n(TAcc, Bin, N) ->
	read_tx_in_n(TAcc, [], {N,N}, Bin).

read_tx_in_n(TAcc, Acc, {0,_ }, Bin) -> {TAcc, lists:reverse(Acc), Bin};
read_tx_in_n(TAcc, Acc, {N,N0}, Bin) when is_integer(N), N>0 ->
	<<PreviousOutput:36/binary, Rest/binary>> = Bin,
	TAcc1 = [PreviousOutput|TAcc],
	{[VarIntBin], ScriptLength, Rest1} = read_var_int([], Rest),
	<<SignatureScript:ScriptLength/binary, Rest2/binary>> = Rest1,
	TAcc2 = [{scriptSig,<<VarIntBin/binary, SignatureScript/binary>>}|TAcc1],
	<<Sequence:32/little, Rest3/binary>> = Rest2,
	TAcc3 = [<<Sequence:32/little>>|TAcc2],
	%NOTE: here, internal TxIn indexes start from 1.
	read_tx_in_n(TAcc3, [{N0-(N-1), parse_outpoint(PreviousOutput), script:parse_scriptSig(SignatureScript), Sequence}|Acc], {N-1,N0}, Rest3).


%% Witness
%% Its count is equal to that of TxIns.
%% see BIP-144
%% see BIP-141 for witness data structure ("witness data is NOT script")
read_witness_n(TAcc, Bin, N) ->
	read_witness_n(TAcc, [], N, Bin).

read_witness_n(TAcc, Acc, 0, Bin) -> {TAcc, lists:reverse(Acc), Bin};
read_witness_n(TAcc, Acc, N, Bin) when is_integer(N), N>0 ->
	{TAcc1, StackItemCounts, Rest} = read_var_int(TAcc, Bin),
	{TAcc2, StackItems, Rest1} = read_stack_item_n(TAcc1, Rest, StackItemCounts),
	read_witness_n(TAcc2, [StackItems|Acc], N-1, Rest1).

%% <var_int><data> as defined in BIP-141
read_stack_item_n(TAcc, Bin, N) ->
	read_stack_item_n(TAcc, [], N, Bin).

read_stack_item_n(TAcc, Acc, 0, Bin) -> {TAcc, lists:reverse(Acc), Bin};
read_stack_item_n(TAcc, Acc, N, Bin) when is_integer(N), N>0 ->
	{TAcc1, Length, Rest} = read_var_int(TAcc, Bin),
	<<StackItem:Length/binary, Rest1/binary>> = Rest,
	TAcc2 = [<<StackItem/binary>>|TAcc1],
	read_stack_item_n(TAcc2, [StackItem|Acc], N-1, Rest1).


%% Outpoint
parse_outpoint(<<Hash:32/binary, Index:32/little>>) -> {parse_hash(Hash), Index}.

%% TxOut
read_tx_out_n(TAcc, Bin, N) -> read_tx_out_n(TAcc, [], {N,N}, Bin).

read_tx_out_n(TAcc, Acc, {0, _}, Bin) -> {TAcc, lists:reverse(Acc), Bin};
read_tx_out_n(TAcc, Acc, {N,N0}, Bin) when is_integer(N), N>0 ->
	<<Value:64/little, Rest/binary>> = Bin, % in satoshis
	TAcc1 = [<<Value:64/little>>|TAcc],
	{[VarIntBin], PkScriptLength, Rest1} = read_var_int([], Rest),
	<<PkScript:PkScriptLength/binary, Rest2/binary>> = Rest1,
	TAcc2 = [{scriptPubKey,<<VarIntBin/binary, PkScript/binary>>}|TAcc1],
	%NOTE: here, internal TxOut indexes start from 1.
	read_tx_out_n(TAcc2, [{N0-(N-1), Value, script:parse_scriptPubKey(PkScript)}|Acc], {N-1,N0}, Rest2).

%% Block
read_block(Bin) ->
	{{_Hash, _Version, _PrevBlockHash, _MerkleRootHash, _Timestamp, _Bits, _Nonce, TxnCount}=BlockHeader, Rest} = read_block_header(Bin),
	{Txs, Rest1} = read_tx_n(Rest, TxnCount),
	{{BlockHeader, Txs}, Rest1}.



%% Block Hash
%% https://en.bitcoin.it/wiki/Block_hashing_algorithm
block_hash(Version, PrevBlock, MerkleRoot, Timestamp, Bits, Nonce) ->
	dhash(<<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary, Timestamp:32/little, Bits:32/little, Nonce:32/little>>).

%% Merkle Hash
merkle_hash(Txids) when is_list(Txids) andalso length(Txids)==1 -> hd(Txids); % for coinbase
merkle_hash(Txids) when is_list(Txids) ->
	merkle_hash([dhash(list_to_binary(P)) || P <- partition_2_with_padding(Txids)]).

%% Block Header
%% for block Version, see BIP9
read_block_header(<<Version:32/little, PrevBlock:32/binary, MerkleRoot:32/binary, Timestamp:32/little, Bits:32/little, Nonce:32/little, Rest/binary>>) ->
	Hash = block_hash(Version, PrevBlock, MerkleRoot, Timestamp, Bits, Nonce),
	{TxnCount, Rest1} = read_var_int(Rest),
	{{parse_hash(Hash), Version, parse_hash(PrevBlock), parse_hash(MerkleRoot), date_time(Timestamp), parse_difficulty_target(Bits), Nonce, TxnCount}, Rest1}.

read_block_header_n(Bin, N) -> read_block_header_n([], N, Bin).

read_block_header_n(Acc, 0, Bin) -> {lists:reverse(Acc), Bin};
read_block_header_n(Acc, N, Bin) when is_integer(N), N>0 ->
	{BlockHeader, Rest} = read_block_header(Bin),
	read_block_header_n([BlockHeader|Acc], N-1, Rest).

%% Dumped Blocks in blocks/blk*****.dat generated by bitcoind
read_blockdump(<<16#0709110B:32/little, Rest/binary>>) -> read_blockdump(testnet, Rest). 

read_blockdump(NetType, <<Size:32/little, BlockBin:Size/binary, Rest/binary>>) ->
	{NetType, read_block(BlockBin), Rest}.


%% headers message
parse_headers(Bin) ->
	{Count, Rest} = read_var_int(Bin),
	{Headers, _Rest1} = read_block_header_n(Rest, Count),
	Headers.



%% reject message
%% BIP61
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
				4 -> node_witness; % BIP-144
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

read_var_int(TAcc, <<16#FF, X:64/little, Rest/binary>>) ->
	{[<<16#FF, X:64/little>>|TAcc], X, Rest};
read_var_int(TAcc, <<16#FE, X:32/little, Rest/binary>>) ->
	{[<<16#FE, X:32/little>>|TAcc], X, Rest};
read_var_int(TAcc, <<16#FD, X:16/little, Rest/binary>>) ->
	{[<<16#FD, X:16/little>>|TAcc], X, Rest};
read_var_int(TAcc, <<X, Rest/binary>>) -> {[<<X>>|TAcc], X, Rest}.

start_with_var_int(Bin) ->
	SizeBin = var_int(byte_size(Bin)),
	<<SizeBin/binary, Bin/binary>>.

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

%% 256-bit hash
dhash(Bin) -> crypto:hash(sha256, crypto:hash(sha256, Bin)).

%% 160-bit hash
%% for public key hash (= bitcoin address)
hash160(Bin) -> crypto:hash(ripemd160, crypto:hash(sha256, Bin)).

parse_hash(<<Hash:32/binary>>) -> bin_to_hexstr(Hash).
hash(Str) when length(Str)==2*32 ->
	hexstr_to_bin(Str).

unix_timestamp() ->
	{Mega, Secs, _} = erlang:timestamp(),
	Timestamp = Mega*1000000 + Secs,
	Timestamp.

date_time(null) -> null;
date_time(SecondsFromEpoch) when is_integer(SecondsFromEpoch), SecondsFromEpoch>=0 ->
	Base = calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
	calendar:gregorian_seconds_to_datetime(Base + SecondsFromEpoch).

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

most(L) when is_list(L) ->
	lists:reverse(tl(lists:reverse(L))).

partition_2_with_padding(L) when is_list(L) ->
	case length(L) rem 2 of
		0 -> partition(L, 2);
		1 ->
			L1 = lists:reverse(L),
			partition(lists:reverse([hd(L1)|L1]),2)
	end.



%% Difficulty target (Bits) for Proof of Work
%%
%%     0x** |******
%% 256^(P-3)*  A
%%
%% ref: https://bitcoin.org/en/developer-reference#target-nbits
%% NOTE: Bytes are encoded in little-endian.
parse_difficulty_target(<<A3,A2,A1,P>>) ->
	%<<A:24/little-signed>> = <<A3,A2,A1>>,
	%A bsl (8*(P-3));
	<<A:24/little>> = <<A3,A2,A1>>,
	AMod =
		case A1 band 16#80 of
			16#00 -> A;
			16#80 -> -(A - 16#800000)
		end,
	AMod bsl (8*(P-3));
parse_difficulty_target(N) ->
	parse_difficulty_target(<<N:32/little>>).

%	{P1, A1} =
%		case A1 band 16#80 of
%			16#00 -> {P,  A};
%			16#80 -> {P+1,A bsr 8}
%		end,




%% SegWit (segregated witness) supports
%% BIP141 - bit1
%is_SegWit_block_version(BlockVersion) -> BlockVersion band 16#40000000 /= 0.


%% Commitment struture
%% ref: BIP-141
witness_root_hash_from_coinbaseTx({_TxIdStr, _TxVersion, TxIns, TxOuts, _Witnesses, _LockTime, _Template}) ->
	FirstTxIn = hd(TxIns),
	{0,{"0000000000000000000000000000000000000000000000000000000000000000",_}, _,_} = FirstTxIn, % ensure the identity of conbase
	HashCandidates = [H || {_,_,{scriptPubKey,{op_return,<<16#aa,16#21,16#a9,16#ed,H:32/binary,_/binary>>}}} <- TxOuts],
	% If there are more than one scriptPubKey matching the pattern, the one with highest output index is assumed to be the Commitment (BIP-141).
	lists:last(HashCandidates).


-ifdef(EUNIT).

partition_2_with_padding_test_() ->
	[
		?_assertEqual(partition_2_with_padding([1,2]), [[1,2]]),
		?_assertEqual(partition_2_with_padding([1,2,3]), [[1,2],[3,3]])
	].

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
		?_assertEqual(bin_to_hexstr(<<1,2,3,16#FF>>), "010203ff"),
		?_assertEqual(bin_to_hexstr(<<1,2,3,16#FF>>, " "), "01 02 03 ff")
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

merkle_hash_test_() ->
	[
		?_assertEqual(bin_to_hexstr(merkle_hash([
		hash("8cb1df74dbe980c6b9202e919597a5eabeb2d32e4de0214a39f80c5fab9e453a"),
		hash("b7a6068e5814738422768b92b7ff81b807fd515871ed6a4172bacc0e6ff438be"),
		hash("be327329c96d01bb0ef93977d026b802db0b59bb7bfed9773af66f2ba1f273d1"),
		hash("2f05c75f38829eeeaf843455df87aac0a7f2bb3cf24f2391b4bb68523ee8d159"),
		hash("0cc67a79dd564d2455df58b371afdeb1a31f44ffa0083b9eb7ef069da677cef1"),
		hash("e052df8e7d50da4be474cd505b21996b74e3d02fbfa1afd39f65fe91ba3c0584")])), 
		"52ed578cb6ed9ae5f5316d45429bf69cfdde2be39497ba31570164eb2277df9c")
	].

parse_difficulty_target_test_() ->
	[
		?_assertEqual(parse_difficulty_target(16#01003456),  16#00),
		?_assertEqual(parse_difficulty_target(16#01123456),  16#12),
		?_assertEqual(parse_difficulty_target(16#02008000),  16#80),
		?_assertEqual(parse_difficulty_target(16#05009234),  16#92340000),
		?_assertEqual(parse_difficulty_target(16#04923456), -16#12345600),
		?_assertEqual(parse_difficulty_target(16#04123456),  16#12345600)
	].

is_SegWit_block_version_() ->
	[
%		?_assertEqual(is_SegWit_block_version(16#40000002), true),
%		?_assertEqual(is_SegWit_block_version(2), false)
	].

-endif.

