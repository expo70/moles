-module(bitcoin).
-export([version/0, ping/0]).

%-define(PEER_ADDRESS, {144,76,75,197}).
-define(PEER_ADDRESS, {52,72,156,74}).
-define(TESTNET_PORT, 18333).
-define(PROTOCOL_VERSION, 70002).

version() ->
	version(?PEER_ADDRESS).

ping() ->
	ping(?PEER_ADDRESS).

% Testnet peer addresses can be obtained by
% dig +short testnet-seed.bitcoin.schildbach.de
version(Address) ->
	Version = ?PROTOCOL_VERSION,
	Services = 0,
	Timestamp = unix_timestamp(),
	<<IP6AddressMy:48/big-unsigned-integer>> = list_to_binary([<<16#FF,16#FF>>,ip4_to_bin({202,218,2,35})]),
	<<IP6AddressPeer:48/big-unsigned-integer>> = list_to_binary([<<16#FF,16#FF>>,ip4_to_bin(?PEER_ADDRESS)]),
	Port = ?TESTNET_PORT,
	StartHeight = 0,
	Nonce = rand:uniform(18446744073709551616)-1,

	Payload = <<
		Version:32/little-signed-integer,
		Services:64/little-unsigned-integer,
		Timestamp:64/little-signed-integer,
		Services:64/little-unsigned-integer,
		IP6AddressPeer:128/big-unsigned-integer,
		Port:16/big-unsigned-integer,
		Services:64/little-unsigned-integer,
		IP6AddressMy:128/big-unsigned-integer,
		Port:16/big-unsigned-integer,
		Nonce:64/little-unsigned-integer,
		0,
		StartHeight:32/little-signed-integer,
		0
	>>,
	Checksum = checksum(Payload),
	PayloadSize = byte_size(Payload),
	Message = list_to_binary([<<16#0b110907:32/big-unsigned-integer,
		"version\0\0\0\0\0",
		PayloadSize:32/little-unsigned-integer>>,
		Checksum,
		Payload]),
	
	%Size = bit_size(Message),
	%<<X:Size/big-unsigned-integer>> = Message,
	%integer_to_list(X,16).
	{ok,Socket} = gen_tcp:connect(Address,?TESTNET_PORT,[binary, {packet, 0}]),
	ok = gen_tcp:send(Socket, Message),
	receive_data(Socket, []).

receive_data(Socket, SoFar) ->
	receive
		{tcp,Socket,Bin} ->
			receive_data(Socket, [Bin|SoFar]);
		{tcp_closed,Socket}->
			io:format("~p~n",[lists:reverse(SoFar)]),
			list_to_binary(lists:reverse(SoFar))
	end.

checksum(Payload) ->
	crypto:start(),
	<<Checksum:4/binary, _/binary>> = crypto:hash(sha256,crypto:hash(sha256,Payload)),
	Checksum.

unix_timestamp() ->
	{Mega, Secs, _} = erlang:timestamp(),
	Timestamp = Mega*1000000 + Secs,
	Timestamp.

ip4_to_bin({A,B,C,D})->
	<<A:8,B:8,C:8,D:8>>.


ping(Address) ->
	Nonce = rand:uniform(18446744073709551616)-1,

	Payload = <<
		Nonce:64/little-unsigned-integer
	>>,
	Checksum = checksum(Payload),
	PayloadSize = byte_size(Payload),
	Message = list_to_binary([<<16#0b110907:32/big-unsigned-integer,
		"ping\0\0\0\0\0\0\0\0",
		PayloadSize:32/little-unsigned-integer>>,
		Checksum,
		Payload]),
	
	%Size = bit_size(Message),
	%<<X:Size/big-unsigned-integer>> = Message,
	%integer_to_list(X,16).
	{ok,Socket} = gen_tcp:connect(Address,?TESTNET_PORT,[binary, {packet, 0}]),
	ok = gen_tcp:send(Socket, Message),
	receive_data(Socket, []).

