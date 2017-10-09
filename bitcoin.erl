-module(bitcoin).
-export([ping/0]).

ping() ->
	ping({178,21,118,174}).
 
% Testnet peer addresses can be obtained by
% dig +short testnet-seed.bitcoin.schildbach.de
ping(Address) ->
	% Nonce
	Payload = <<16#0094102111e3af4d:64/little-unsigned-integer>>,
	PayloadSize = bit_size(Payload),
	Message = list_to_binary([<<16#0b110907:32/big-unsigned-integer,
		"ping\0\0\0\0\0\0\0\0":96,
		PayloadSize:32/little-unsigned-integer>>
		|checksum(Payload)]),
	
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

