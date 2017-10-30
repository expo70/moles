%% Script
%% 
%% reference implementation: https://github.com/bitcoin/bitcoin/blob/master/src/script/interpreter.cpp
-module(script).

-compile(export_all).

-define(MAX_SCRIPT_SIZE, 10000).
%-define(MAX_SCRIPT_ELEMENT_SIZE, ).

-define(OP_DUP, 118).
-define(OP_HASH160, 169).
-define(OP_EQUALVERIFY, 136).
-define(OP_CHECKSIG, 172).
-define(OP_EQUAL, 135).
-define(OP_CHECKMULTISIG, 174).


%%
%% Standard Transactions
%%
%% * Pay to Public Key Hash (P2PKH)
%% * Pay to Script Hash (P2SH)
%%

%% P2PKH
%% Sig    script: PUSH <Sig> PUSH <PubKey>
%% PubKey script: OP_DUP OP_HASH160 <PubKeyHash> OP_EQUALVERIFY OP_CHECKSIG

%% P2SH
%% Sig    script: PUSH <Sig> [Sig...] <RedeemScript>
%% PubKey script: OP_HASH160 <RedeemScriptHash> OP_EQUAL
%%
%% multisig type
%% Sig    script: OP_0 PUSH <Sig1> PUSH <SigX> ... PUSH <RedeemScript>
%% PubKey script: OP_HASH160 <RedeemScriptHash> OP_EQUAL
%% Redeem script: PUSH <m> PUSH <PubKey1> PUSH <PubKey2> ... PUSH <PubKeym> PUSH <n> OP_CHECKMULTISIG
%%
%% OP_0 is icluded to deal with the off-by-one bug of OP_CHECKMULTISIG in the original BitCoin source code
%%
%% BIP16 - https://github.com/bitcoin/bips/blob/master/bip-0016.mediawiki

parse_scriptPubKey(<<?OP_DUP, ?OP_HASH160, Rest/binary>>) ->
	{Pushes,Rest1} = read_PUSHes(Rest),
	[{push,PubKeyHash}] = Pushes,
	<<?OP_EQUALVERIFY, Rest2/binary>> = Rest1,
	<<?OP_CHECKSIG>> = Rest2,
	{scriptPubKey, {pubKeyHash, PubKeyHash}};
parse_scriptPubKey(<<?OP_HASH160, Rest/binary>>) ->
	{Pushes,Rest1} = read_PUSHes(Rest),
	[{push,RedeemScriptHash}] = Pushes,
	<<?OP_EQUAL>> = Rest1,
	{scriptPubKey, {redeemScriptHash, RedeemScriptHash}};
parse_scriptPubKey(Bin) ->
	{scriptPubKey, {unknown, read_PUSHes(Bin)}}.

parse_scriptSig(Script) ->
	{Pushes,Rest1} = read_PUSHes(Script),
	case length(Pushes) of
		 2 ->
		 	<<>> = Rest1,
		 	[{push, PubKey}, {push, Sig}] = Pushes,
			DERLen = byte_size(Sig)-1,
			<<SigDER:DERLen/binary, SigType>> = Sig,
		 	{scriptSig,
				{
					{sig,    ecdsa:parse_signature_DER(SigDER), SigType},
					{pubKey, ecdsa:parse_public_key(PubKey)}
				}
			};
		 _ -> {scriptSig, {unknown, Script}}   
	end.


is_PUSH(OpCode) -> (OpCode =< 96) andalso (OpCode /= 80).

read_push_data(OpCode, Rest) ->
	if
		OpCode =:= 0 -> {<<>>, 0, Rest};
		(1 =< OpCode) andalso (OpCode =< 75) ->
			<<Data:OpCode/binary, Rest1/binary>> = Rest,
			{Data, OpCode, Rest1};
		OpCode =:= 76 -> % OP_PUSHDATA1
			<<PushSize:8, Rest1/binary>> = Rest,
			<<Data:PushSize/binary, Rest2/binary>> = Rest1,
			{Data, PushSize, Rest2};
		OpCode =:= 77 -> % OP_PUSHDATA2
			<<PushSize:16/little, Rest1/binary>> = Rest,
			<<Data:PushSize/binary, Rest2/binary>> = Rest1,
			{Data, PushSize, Rest2};
		OpCode =:= 78 -> % OP_PUSHDATA4
			<<PushSize:32/little, Rest1/binary>> = Rest,
			<<Data:PushSize/binary, Rest2/binary>> = Rest1,
			{Data, PushSize, Rest2};
		OpCode =:= 79 -> % OP_1NEGATE
			{-1, 0, Rest};
		(81 =< OpCode) andalso (OpCode =< 96) ->
			{OpCode-80, 0, Rest}
	end.


assert_minimal_push(_, _, 0) -> ok;
% The minimal-push condition should be achived as below,
% but the reference code and some existing coinbase txs seem to allow us to use
% push N < 16 by OP_PUSH1(1).
%assert_minimal_push(OpCode, Data, 1) ->
%	<<N:8>> = Data,
%	if
%		(OpCode =:= 1) andalso (16 < N) andalso (N /= 16#81) -> ok
%	end;
assert_minimal_push(OpCode, _, Size) when Size =< 75 ->
	if
		OpCode == Size -> ok
	end;
assert_minimal_push(OpCode, _, Size) when Size =< 255 ->
	if
		OpCode =:= 76 -> ok
	end;
assert_minimal_push(OpCode, _, Size) when Size =< 65535 ->
	if
		OpCode =:= 77 -> ok
	end;
assert_minimal_push(OpCode, _, Size) when Size =< 4294967295 ->
	if
		OpCode =:= 78 -> ok
	end.

minimal_push(-1) -> <<79>>;
minimal_push(<<>>) -> <<0>>;
minimal_push(N) when (1 =< N) andalso (N =< 16) ->
	OpCode = N + 80,
	<<OpCode>>;
minimal_push(Data) when is_binary(Data) ->
	Size = byte_size(Data),
	if
		%Size == 1 ->
		%	<<N:8>> = Data,
		%	if
		%		(16 < N) andalso (N /= 16#81) -> <<1,N>>
		%	end;
		Size =< 75 -> <<Size,Data/binary>>;
		Size =< 225 ->
			<<76,Size,Data/binary>>;
		Size =< 65535 ->
			<<77,Size:16/little,Data/binary>>;
		Size =< 4294967295 ->
			<<78,Size:32/little,Data/binary>>
	end.


read_PUSHes(Script) -> read_PUSHes([], Script).

read_PUSHes(Stack, <<>>) -> {Stack, <<>>};
read_PUSHes(Stack, Script) ->
	<<OpCode:8, Rest/binary>> = Script,
	case is_PUSH(OpCode) of
		true ->
			{Data, Size, Rest1} = read_push_data(OpCode, Rest),
			assert_minimal_push(OpCode, Data, Size),
			read_PUSHes([{push, Data}|Stack], Rest1);
		false ->
			{Stack, Script}
	end.


%% PubKey script: OP_DUP OP_HASH160 PUSH<PubKeyHash> OP_EQUALVERIFY OP_CHECKSIG
create_P2PKH_scriptPubKey({QX,QY},Format) ->
	PubKeyBin = ecdsa:public_key({QX,QY},Format),
	PubKeyHashBin = minimal_push(protocol:hash160(PubKeyBin)),
	<<?OP_DUP, ?OP_HASH160, PubKeyHashBin/binary, ?OP_EQUALVERIFY, ?OP_CHECKSIG>>.
