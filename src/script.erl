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
-define(OP_RETURN, 106).


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

parse_scriptPubKey(<<?OP_DUP, ?OP_HASH160, Rest/binary>>, false=_HasWitnessQ) ->
	{Pushes,Rest1} = read_PUSHes(Rest),
	[{push,PubKeyHash}] = Pushes,
	<<?OP_EQUALVERIFY, Rest2/binary>> = Rest1,
	<<?OP_CHECKSIG>> = Rest2,
	{scriptPubKey, {pubKeyHash, PubKeyHash}};
parse_scriptPubKey(<<?OP_HASH160, Rest/binary>>, false=_HasWitnessQ) ->
	{Pushes,Rest1} = read_PUSHes(Rest),
	[{push,RedeemScriptHash}] = Pushes,
	<<?OP_EQUAL>> = Rest1,
	{scriptPubKey, {redeemScriptHash, RedeemScriptHash}};
parse_scriptPubKey(<<?OP_RETURN, Rest/binary>> =Script, false=_HasWitnessQ) ->
	{Pushes,Rest1} = read_PUSHes(Rest),
	if
		length(Pushes) == 1 ->
			<<>> = Rest1,
			{push, Bin} = hd(Pushes),
			{scriptPubKey, {op_return, Bin}};
		true -> {scriptPubKey, {unknown, Script}}
	end;
parse_scriptPubKey(Bin, false=_HasWitnessQ) ->
	{scriptPubKey, {unknown, read_PUSHes(Bin)}};
%% Version 0 Witness Program
%% ref: BIP-141
parse_scriptPubKey(<<16#16,16#00,16#14,KeyHash:20/binary>>, true=_HasWitnessQ) ->
	{scriptPubKey, {nested_p2wpkh_keyHash, KeyHash}};
parse_scriptPubKey(<<16#22,16#00,16#20,Hash:32/binary>>, true=_HasWitnessQ) ->
	{scriptPubKey, {nested_p2wsh_hash, Hash}};
parse_scriptPubKey(<<      16#00,16#14,KeyHash:20/binary>>, true=_HasWitnessQ) ->
	{scriptPubKey, {native_p2wpkh_keyHash, KeyHash}};
parse_scriptPubKey(<<      16#00,16#20,Hash:32/binary>>, true=_HasWitnessQ) ->
	{scriptPubKey, {native_p2wsh_hash, Hash}};
parse_scriptPubKey(<<?OP_HASH160,Hash:20/binary,?OP_EQUAL>>, true=_HasWitnessQ) ->
	{scriptPubKey, {nested_p2w_hash, Hash}};
%parse_scriptPubKey(<<?OP_DUP, ?OP_HASH160, 
parse_scriptPubKey(Script, true=_HasWitnessQ) -> parse_scriptPubKey(Script, false).


parse_scriptSig(<<0, Rest/binary>> = Script, false=_HasWitnessQ) ->
	{Pushes,Rest1} = read_PUSHes(Rest),
	if
		length(Pushes) >= 2 ->
			<<>> = Rest1,
			RPushes = lists:reverse(Pushes),
			Sigs = [
				begin
					DERLen = byte_size(B)-1,
					<<SigDER:DERLen/binary, SigType>> = B,
					{sig, ecdsa:parse_signature_DER(SigDER), SigType}
				end
				|| {push, B} <- lists:droplast(RPushes)],
			{push, RedeemScript} = lists:last(RPushes),
			{scriptSig,
				{
					{multisig, Sigs},
					{redeemScript, RedeemScript}
				}
			};
		true -> {scriptSig, {unknown, Script}}
	end;
parse_scriptSig(Script, false=_HasWitnessQ) ->
	{Pushes,Rest1} = read_PUSHes(Script),
	case length(Pushes) of
		 2 ->
		 	case Rest1 of
		 		<<>> ->
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
			end;
		 _ -> {scriptSig, {unknown, Script}}   
	end;
%% Version 0 Witness Program
%% ref: BIP-141
parse_scriptSig(<<>>, true=_HasWitnessQ) -> % 'native'
	{scriptSig, {native_witness, <<>>}};
%% 0x160014 means 
%% var_int(22), PUSH_0, PUSH_20.
parse_scriptSig(<<16#16,16#00,16#14,KeyHash:20/binary>>, true=_HasWitnessQ) -> % 'nested in BIP16 P2SH'
	{scriptSig, {p2wpkh_keyHash, KeyHash}};
%% var_int(34), PUSH_0, PUSH_32
parse_scriptSig(<<16#22,16#00,16#20,Hash:32/binary>>, true=_HasWitnessQ) -> % 'nested in BIP16 P2SH'
	{scriptSig, {p2wsh_hash, Hash}};
parse_scriptSig(Script, true=_HasWitnessQ) -> parse_scriptSig(Script, false).



%% assumes P2SH multisig
parse_redeemScript(Script) ->
	{Pushes,Rest} = read_PUSHes(Script),
	<<?OP_CHECKMULTISIG>> = Rest,
	Parameters = lists:reverse(Pushes),
	{push, M} = hd(Parameters),
	{push, N} = hd(Pushes),
	PubKeys = [{pubKey,ecdsa:parse_public_key(P)} || {push,P} <- tl(lists:reverse(tl(Pushes)))], % in-between
	{p2sh_multisig, {M,N}, PubKeys}.




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
