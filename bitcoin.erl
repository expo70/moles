-module(bitcoin).
-export([version/0]).

version() ->
	version({78,47,147,60}).

% Testnet peer addresses can be obtained by
% dig +short testnet-seed.bitcoin.schildbach.de
version(Address) ->
	Version = 70002,
	Services = 1,
	Timestamp = unix_timestamp(),
	<<IP6Address:48/big-unsigned-integer>> = <<16#FF,16#FF,127,0,0,1>>,
	Port = 18333,
	StartHeight = 329167,
	Nonce = 16#f85379c9cb358012,

	Payload = <<
		Version:32/little-signed-integer,
		Services:64/little-unsigned-integer,
		Timestamp:64/little-signed-integer,
		Services:64/little-unsigned-integer,
		IP6Address:128/big-unsigned-integer,
		Port:16/big-unsigned-integer,
		Services:64/little-unsigned-integer,
		IP6Address:128/big-unsigned-integer,
		Port:16/big-unsigned-integer,
		Nonce:64/little-unsigned-integer,
		0,
		StartHeight:32/little-signed-integer
	>>,
	Checksum = checksum(Payload),
	PayloadSize = bit_size(Payload),
	Message = list_to_binary([<<16#0b110907:32/big-unsigned-integer,
		"version\0\0\0\0\0":96,
		PayloadSize:32/little-unsigned-integer>>,
		Checksum,
		Payload]),
	
	%Size = bit_size(Message),
	%<<X:Size/big-unsigned-integer>> = Message,
	%integer_to_list(X,16).
	{ok,Socket} = gen_tcp:connect(Address,18333,[binary, {packet, 0}]),
	ok = gen_tcp:send(Socket, Message),
	receive_data(Socket, []).

receive_data(Socket, SoFar) ->
	receive
		{tcp,Socket,Bin} ->
			receive_data(Socket, [Bin|SoFar]);
		{tcp_closed,Socket}->
			list_to_binary(lists:reverse(SoFar))
	end.

checksum(Payload) ->
	crypto:start(),
	<<Checksum:32/binary, _/binary>> = crypto:hash(sha256,crypto:hash(sha256,Payload)),
	Checksum.

unix_timestamp() ->
	{Mega, Secs, _} = erlang:timestamp(),
	Timestamp = Mega*1000000 + Secs,
	Timestamp.

