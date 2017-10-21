%% Bitcoin Protocol
%% as described in https://en.bitcoin.it/wiki/Protocol_documentation
-module(protocol).
-compile([export_all]).








version(NetType, {PeerAddress, PeerPort}, {ServicesType, ProtocolVersion}, {MyAddress, MyPort}, StrUserAgent, StartBlockHeight, RelayQ) ->
	Services = services(ServicesType),
	Timestamp = unix_timestamp(),
	% time field is not present in version message.
	<<_:32, AddrRecv/binary>> = net_addr(PeerAddress, PeerPort, {ServicesType, ProtocolVersion}),
	<<_:32, AddrFrom/binary>> = net_addr(MyAddress, MyPort,   {ServicesType, ProtocolVersion}),
	% 2^64
	Nonce = rand:uniform(18446744073709551616)-1,
	UserAgent = var_str(StrUserAgent),
	Relay = case RelayQ of
		true  -> 1;
		false -> 0
	end,

	B1 = <<ProtocolVersion:32/little, Services:64/little, Timestamp:64/little, AddrRecv/binary>>,
	B2 = <<AddrFrom/binary, Nonce:64/little, UserAgent/binary, StartBlockHeight:32/little>>,
	B3 = <<Relay:8>>,
	
	Payload = if
		ProtocolVersion >= 70001 -> <<B1/binary,B2/binary,B3/binary>>;
		ProtocolVersion >=   106 -> <<B1/binary,B2/binary>>;
		ProtocolVersion <    106 -> B1
	end,

	message(NetType, version, Payload).



		



message(NetType, Command, Payload) ->
	Magic = magic(NetType),
	BinCommand = atom_to_bin12(Command),
	Length = byte_size(Payload),
	<<Checksum:4/binary, _/binary>> = dhash(Payload),

	<<Magic:32/little, BinCommand/binary, Length:32/little, Checksum/binary, Payload/binary>>.


net_addr({A,B,C,D}, Port, {ServicesType, ProtocolVersion}) ->
	Time = unix_timestamp(),
	Services = services(ServicesType),
	IP6Address = <<0:(8*10), 16#FF, 16#FF, A:8, B:8, C:8, D:8>>,
	if
		ProtocolVersion >= 31402 -> <<Time:32/little, Services:64/little, IP6Address/binary, Port:16/big>>;
		ProtocolVersion <  31402 -> <<                Services:64/little, IP6Address/binary, Port:16/big>>
	end.


services(ServicesType) ->
	case ServicesType of
		node_network -> 1;
		node_getutxo -> 2;
		node_bloom   -> 4
	end.


magic(NetType) ->
	case NetType of
		main     -> 16#D9B4BEF9;
		testnet  -> 16#DAB5BFFA;
		testnet3 -> 16#0709110B;
		namecoin -> 16#FEB4BEF9
	end.


% CompactSize
var_int(X) when X <  16#FD -> <<X>>;
var_int(X) when X =< 16#FFFF -> <<16#FD, X:16/little>>;
var_int(X) when X =< 16#FFFFFFFF -> <<16#FE, X:32/little>>;
var_int(X) when X =< 16#FFFFFFFFFFFFFFFF -> <<16#FF, X:64/little>>.


var_str(Str) ->
	Bin = list_to_binary(Str),
	Length = var_int(byte_size(Bin)),
	<<Length/binary, Bin/binary>>.


atom_to_binary(Atom) -> list_to_binary(atom_to_list(Atom)).


atom_to_bin12(Command) ->
	BinCommand = atom_to_binary(Command),
	Len = byte_size(BinCommand),
	<<BinCommand/binary,0:(8*(12-Len))>>.


dhash(Bin) -> crypto:hash(sha256, crypto:hash(sha256, Bin)).


unix_timestamp() ->
	{Mega, Secs, _} = erlang:timestamp(),
	Timestamp = Mega*1000000 + Secs,
	Timestamp.

bin_to_hexstr(Bin) ->
  lists:flatten([io_lib:format("~2.16.0B", [X]) ||
      X <- binary_to_list(Bin)]).

