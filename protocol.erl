%% Bitcoin Protocol
%% as described in https://en.bitcoin.it/wiki/Protocol_documentation
-module(protocol).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all]).



read_message(<<16#D9B4BEF9:32/little, Rest/binary>>) -> read_message(main, Rest); 
read_message(<<16#DAB5BFFA:32/little, Rest/binary>>) -> read_message(testnet, Rest); 
read_message(<<16#0709110B:32/little, Rest/binary>>) -> read_message(testnet3, Rest); 
read_message(<<16#FEB4BEF9:32/little, Rest/binary>>) -> read_message(namecoin, Rest). 

read_message(NetType, <<BinCommand:12/binary, Length:32/little, Checksum:4/binary, Payload:Length/binary, Rest/binary>>) ->
	Command = bin12_to_atom(BinCommand),
	<<RealChecksum:4/binary, _/binary>> = dhash(Payload),
	
	case RealChecksum of
		Checksum -> {ok, {NetType, Command, Payload, Rest}};
		       _ -> {error, checksum, {NetType, Rest}}
	end.

parse_version(<<MyProtocolVersion:32/little, MyServices:64/little, Timestamp:64/little, AddrRecv:26/binary, Rest/binary>>) ->
	{PeerAddress, PeerPort, PeerServicesType, Time} = parse_net_addr(AddrRecv),
	parse_version1({{MyServices, MyProtocolVersion}, Timestamp, {PeerAddress, PeerPort}, PeerServicesType, Time}, Rest).

parse_version1(B1, <<>>) -> {B1,{},{}};
parse_version1(B1, Rest) ->
	<<AddrFrom:26/binary, Nonce:64/little, Rest1/binary>> = Rest,
	{MyAddress, MyPort, MyServicesType, Time} = parse_net_addr(AddrFrom),
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
	% 2^64
	Nonce = rand:uniform(18446744073709551616)-1,
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

verack(NetType) -> message(NetType, verack, <<>>).

addr(NetType, PeerAddresses, ProtocolVersion) ->
	Count = var_int(length(PeerAddresses)),
	T = unix_timestamp(),
	Timestamp = if
		ProtocolVersion >= 31402 -> <<T:32/little>>;
		ProtocolVersion <  31402 -> <<>>
	end,
	Payload = list_to_binary([Count, Timestamp, PeerAddresses]),
	
	message(NetType, addr, Payload).





message(NetType, Command, Payload) ->
	Magic = magic(NetType),
	BinCommand = atom_to_bin12(Command),
	Length = byte_size(Payload),
	<<Checksum:4/binary, _/binary>> = dhash(Payload),

	<<Magic:32/little, BinCommand/binary, Length:32/little, Checksum/binary, Payload/binary>>.


net_addr({A,B,C,D}, Port, {ServicesType, MyProtocolVersion}) ->
	Time = unix_timestamp(),
	Services = services(ServicesType),
	IP6Address = <<0:(8*10), 16#FF, 16#FF, A:8, B:8, C:8, D:8>>,
	if
		MyProtocolVersion >= 31402 -> <<Time:32/little, Services:64/little, IP6Address:16/binary, Port:16/big>>;
		MyProtocolVersion <  31402 -> <<                Services:64/little, IP6Address:16/binary, Port:16/big>>
	end.

parse_net_addr(<<Time:32/little, Rest:(8+16+2)/binary>>) -> parse_net_addr(Time, Rest);
parse_net_addr(<<Bin:(8+16+2)/binary>>) -> parse_net_addr(0, Bin).

parse_net_addr(Time, <<Services:64/little, IP6Address:16/binary, Port:16/big>>) ->
	ServicesType = parse_services(Services),
	IPAddress = case IP6Address of
		<<0:(8*10), 16#FF, 16#FF, A:8, B:8, C:8, D:8>> -> {A,B,C,D};
		<<E:16/big, F:16/big, G:16/big, H:16/big, I:16/big, J:16/big, K:16/big, L:16/big>> -> {E,F,G,H,I,J,K,L}
	end,
	{IPAddress, Port, ServicesType, Time}.

inv_vect(ObjectType, Hash) ->
	Type = object_type(ObjectType),
	<<Type:32/little, Hash:32/binary>>.


services(ServicesType) ->
	case ServicesType of
		node_network -> 1;
		node_getutxo -> 2;
		node_bloom   -> 4
	end.

parse_services(Services) ->
	case Services of
		1 -> node_network;
		2 -> node_getutxo;
		4 -> node_bloom
	end.

parse_bool(<<0>>) -> false;
parse_bool(<<1>>) -> true.

magic(NetType) ->
	case NetType of
		main     -> 16#D9B4BEF9;
		testnet  -> 16#DAB5BFFA;
		testnet3 -> 16#0709110B;
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

atom_to_binary(Atom) -> list_to_binary(atom_to_list(Atom)).


atom_to_bin12(Command) ->
	BinCommand = atom_to_binary(Command),
	Len = byte_size(BinCommand),
	<<BinCommand/binary,0:(8*(12-Len))>>.

bin12_to_atom(Bin12) ->
	L = string:strip(binary_to_list(Bin12), right, 0),
	list_to_atom(L).

dhash(Bin) -> crypto:hash(sha256, crypto:hash(sha256, Bin)).


unix_timestamp() ->
	{Mega, Secs, _} = erlang:timestamp(),
	Timestamp = Mega*1000000 + Secs,
	Timestamp.

bin_to_hexstr(Bin) -> bin_to_hexstr(Bin,"").

bin_to_hexstr(Bin,Sep) ->
  string:join([io_lib:format("~2.16.0B", [X]) ||
      X <- binary_to_list(Bin)], Sep).

hexstr_to_bin(Str) -> hexstr_to_bin(Str, "").

hexstr_to_bin(Str,Sep) ->
	T = string:tokens(Str,Sep),
	list_to_binary([list_to_integer(S,16) || S <- T]).


-ifdef(EUNIT).

var_str_test() ->
	[
		?_assertEqual(var_str(""), <<0>>),
		?_assertEqual(var_str("ABC"), <<3,"ABC">>)
	].

atom_to_bin12_test() ->
	[
		?_assertEqual(atom_to_bin12(version), <<"version","\0\0\0\0\0">>)
	].

bin12_to_atom_test() ->
	[
		?_assertEqual(bin12_to_atom(atom_to_bin12(version)), version)
	].

bin_to_hexstr_test() ->
	[
		?_assertEqual(bin_to_hexstr(<<>>), ""),
		?_assertEqual(bin_to_hexstr(<<1,2,3,16#FF>>), "010203FF"),
		?_assertEqual(bin_to_hexstr(<<1,2,3,16#FF>>, " "), "01 02 03 FF")
	].

hexstr_to_bin_test() ->
	[
		?_assertEqual(hexstr_to_bin(""), <<>>),
		?_assertEqual(hexstr_to_bin(bin_to_hexstr(<<1,2,3,16#FF>>)), <<1,2,3,16#FF>>),
		?_assertEqual(hexstr_to_bin(bin_to_hexstr(<<1,2,3,16#FF>>, " "), " "), <<1,2,3,16#FF>>)
	].

read_var_int_test() ->
	[
		?_assertEqual(read_var_int(var_int(0)), {0,<<>>}),
		?_assertEqual(read_var_int(var_int(16#FF)), {16#FF,<<>>})
	].

read_var_str_test() ->
	[
		?_assertEqual(read_var_str(var_str("")), {"",<<>>}),
		?_assertEqual(read_var_str(var_str("ABC")), {"ABC",<<>>})
	
	].


-endif.

