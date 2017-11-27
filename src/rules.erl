%% Concensus and obiligatory rules for the integrity of the Bitcoin Block Chain
%%
-module(rules).
-include_lib("eunit/include/eunit.hrl").
-include("../include/constants.hrl").

-compile(export_all).



%% Critical limitations
%% bitcoin/src/consensus/consensus.h
%%-define(
-define(COINBASE_MATURITY, 100).
-define(MAX_BLOCK_SERIALIZED_SIZE, 4000000). % under Segwit


%% Verifying Signatures on Tx
%%
%% ref: https://en.bitcoin.it/wiki/OP_CHECKSIG


%% Verifying signatures in scriptSigs in a Tx
%% only supports the most common case:
%% * All the signing hash type are SIGHASH_ALL
%% * (currently) Assumes all the prev outputs are the most typical one.
%% 
%% Representation of Tx is defined in protocol module
%% does not support the verification of coinbase Tx 
%% (i.e., the first transaction in a block)
%% 
%% returns a boolean vector whose elements show the
%% result of signature verification for each TxIns.
verify_signatures_in_Tx({_TxIdStr, _TxVersion, TxIns, _TxOuts, _Witnesses, _LockTime, [{tx, Template}]}=Tx) ->
	N_TxIns = length(TxIns),
	
	ToProcess = 
	[
		[Idx,S,1,P] || {Idx, _PreviousOutput, {scriptSig, {{sig, S, 1},{pubKey, P}}}, _Sequence} <- TxIns
	],
	[Indexes, Signatures, HashTypes, PublicKeys] =
		case ToProcess of
			[ ] -> [[],[],[],[]];
			 _  -> u:transpose(ToProcess)
		end,
	
	CoinbaseIndexes = [Idx || {Idx, _, {scriptSig, {coinbase, _}},_} <- TxIns],
	CoinbaseCount = length(CoinbaseIndexes),
	CoinbaseResults = [{Idx,true} || Idx <- CoinbaseIndexes],

	Delegated =
	if
		length(Signatures)+CoinbaseCount /= N_TxIns ->
			Unfiltered = u:range(N_TxIns) -- (Indexes++CoinbaseIndexes),
			verify_signatures_in_Tx2(Tx, Unfiltered);
		length(Signatures)+CoinbaseCount == N_TxIns -> []
	end,
	
	%% This is what fills in scriptSig slots when signing.
	%% FIXME
	%% In the original implementation, the slots are filled
	%% by signaturePubKey in the previous outputs (in prev Tx).
	%% But here, I only uses the most common P2PKH scriptPubKey as
	%% an easy alternative.
	Marks = [protocol:start_with_var_int(script:create_P2PKH_scriptPubKey(P,compressed)) || P <- PublicKeys],

	%% procedure when HashType == SIGHASH_ALL(1)
	% use all the TxIns/TxOuts
	% makes scriptPubKey slots are filled by the original binaries
	% When serializing for signing, witness-related slots are ignored.
	TemplateSig = protocol:template_default_binary_for_slots(Template, 
		[tx_in, tx_out, scriptPubKey]),
	SignedHashes =
		[protocol:dhash(
			begin
			TS1 = protocol:template_fill_nth(TemplateSig,
					{scriptSig, lists:nth(N, Marks)},lists:nth(N,Indexes)),
			TS2 = protocol:template_fill_nth(TS1,
					{scriptSig, protocol:var_int(0)},any),
			B = protocol:template_to_binary(TS2),
			HT = lists:nth(N, HashTypes),
			<<B/binary, HT:32/little>> % HashType should be appended
			end
					) || N <- lists:seq(1,length(Indexes))],
	
	V = lists:zipwith3(fun(S,H,P) -> ecdsa:verify_signature(S,H,P) end,
		Signatures, SignedHashes, PublicKeys),
	lists:sort(fun({I1,_},{I2,_}) -> I1=<I2 end, 
		lists:zip(Indexes,V) ++ Delegated ++ CoinbaseResults).

%% Verify P2SH multisig
%% 
verify_signatures_in_Tx2({_TxIdStr, _TxVersion, TxIns, _TxOuts, _Witnesses, _LockTime, [{tx,Template}]}=Tx, Indexes) ->
	%io:format("input = ~p~n",[Indexes]),
	ToProcess = 
	[
		[Idx,Sigs,Re] || {Idx, _PreviousOutput, {scriptSig, {{multisig, Sigs},{redeemScript, Re}}}, _Sequence} <- TxIns
	],
	[Indexes1, MultiSignatures, RedeemScripts] =
		case ToProcess of
			[ ] -> [[],[],[]];
			 _  -> u:transpose(ToProcess)
		end,
	Delegated =
	if
		length(Indexes1) /= length(Indexes) ->
			Unfiltered = Indexes -- Indexes1,
			verify_signatures_in_Tx3(Tx, Unfiltered);
		length(Indexes1) == length(Indexes) -> []
	end,
	%% For P2SH scripts, the Mark used when signinig is RedeemScript.
	%% ref: http://www.soroushjp.com/2014/12/20/bitcoin-multisig-the-hard-way-understanding-raw-multisignature-bitcoin-transactions/
	% when serializing for singning witness-related slots are ignored
	TemplateSig = protocol:template_default_binary_for_slots(Template, 
		[tx_in, tx_out, scriptPubKey]),
	V = lists:zipwith3(fun(N,M,R)->verify_multisig(N,M,R,TemplateSig) end,
		Indexes1, MultiSignatures, RedeemScripts),
	lists:zip(Indexes1, V) ++ Delegated.




verify_multisig(SlotNo, Signatures, RedeemScript, TemplateSig) ->
		{p2sh_multisig, {Min_M,Total_N},PubKeys} = script:parse_redeemScript(RedeemScript),
		% length(PubKeys) should be equal to Total_N
		if
			length(PubKeys) == Total_N -> ok;
			length(PubKeys) /= Total_N -> throw(missing_pubkey)
		end,
		% hash to be signed
		% We only handle the case when HashType == 1.
		% redeemScript itself (without precedent push OP) is used for 
		% filling the pre-signed data when calculating hash.
		Hash =
			protocol:dhash(
				begin
				LengthBin = protocol:var_int(byte_size(RedeemScript)),
				Mark = <<LengthBin/binary, RedeemScript/binary>>,
				TS1 = protocol:template_fill_nth(
					TemplateSig, {scriptSig, Mark}, SlotNo),
				TS2 = protocol:template_fill_nth(
					TS1, {scriptSig, protocol:var_int(0)}, any),
				B = protocol:template_to_binary(TS2),
				HashType = 1, %NOTE: this is an assumption
				<<B/binary, HashType:32/little>> % HashType should be appended
				end),
		% OP_CHECKMULTISIG does not check the all the combinations of
		% signatures and public keys because of its behaviour on the
		% stack machine. Each signature on the top comsumes public keys
		% until it finds an ECDSA match. 
		% We emulate this behaviour.
		VerifyFunc =
			fun({sig, S, _HashType}, {pubKey, P}) ->
				ecdsa:verify_signature(S, Hash, P) end,
		V = emulate_OP_CHECKMULTISIG(VerifyFunc, Signatures, PubKeys),
		u:count(V,true) >= Min_M. % m-of-n check


%% check all the combinations of Sig/PubKey in multisig (for testing purpose)
verify_multisig_combinations(VerifyFunc, Signatures, PubKeys) ->
	[VerifyFunc(S,P) || S<-Signatures, P<-PubKeys].


%% a stack machine for OP_CHECKMULTISIG
emulate_OP_CHECKMULTISIG(VerifyFunc, Signatures, PubKeys) ->
	StackSig = lists:reverse(Signatures),
	StackPub = lists:reverse(PubKeys),

	run_CHECKMULTISIG([], VerifyFunc, StackSig, StackPub).

run_CHECKMULTISIG(Acc, _, [], _) -> lists:reverse(Acc);
run_CHECKMULTISIG(Acc, _, _, []) -> lists:reverse(Acc);
run_CHECKMULTISIG(Acc, VerifyFunc, [Sig|SigT]=StackSig, [Pub|PubT]) ->
	case VerifyFunc(Sig,Pub) of
		true ->  run_CHECKMULTISIG([true |Acc], VerifyFunc, SigT,     PubT);
		false -> run_CHECKMULTISIG([false|Acc], VerifyFunc, StackSig, PubT)
	end.

%% Verify Signature in Version 0 Witness
%% 
%% Hash value to be signed is very different from that in the older scheme.
%% ref: BIP-143
verify_signatures_in_Tx3({_TxIdStr, _TxVersion, TxIns, _TxOuts, _Witnesses, _LockTime, [{tx,_Template}]}=Tx, Indexes) ->
	%% SUPPORTED
	%%                asigned in script.erl
	%%                scriptSig      scriptPubKey
	%% native  P2WPKH native_witness native_p2wpkh_keyHash
	%% native  P2WSH  native_witness native_p2wsh_hash
	%% in-P2SH P2WPKH p2wpkh_keyHash nested_p2w_hash
	%% in-P2SH P2WSH  p2wsh_hash     nested_p2w_hash

	NestedP2WPKH_Indexes = [Idx || {Idx, _PrevOut, {scriptSig, {p2wpkh_keyHash, _KeyHash}},_Sequence} <- TxIns],
	NestedP2WSH_Indexes  = [Idx || {Idx, _PrevOut, {scriptSig, {p2wsh_hash, _Hash}},_Sequence} <- TxIns],
	%
	Native_Witness_Indexes = [Idx || {Idx, _PrevOut, {scriptSig, {native_witness, <<>>}},_Sequence} <- TxIns],

	ToProcessIndexes = NestedP2WPKH_Indexes ++ NestedP2WSH_Indexes ++ Native_Witness_Indexes,
	UnfilteredIndexes = Indexes -- ToProcessIndexes,
	Delegated =
		case UnfilteredIndexes of
			[ ] -> [];
			 L  -> throw({unknown_type_of_signatures_in_Tx, L})
		end,
	V4 = verify_nested_P2WSH_signatures_in_Tx(Tx, NestedP2WSH_Indexes),
	V4 ++ Delegated.


%% Witness = <> <Sig1> ... <SigX> <RedeemScript>
%% scriptCode = var_int(Len) <RedeemScript (witnessScript)>
%%
verify_nested_P2WSH_signatures_in_Tx({_TxIdStr, _TxVersion, _TxIns, _TxOuts, Witnesses, _LockTime, [{tx,_Template}]}=Tx, Indexes) ->
	Env = tester, % FIXME

	Ws = [lists:nth(I,Witnesses) || I <- Indexes],
	{Multisignatures, WitnessScripts} =
		lists:unzip([parse_witness_P2WSH(W) || W <- Ws]),
	ScriptCodes = [
		begin
			LengthBin = protocol:var_int(byte_size(W)),
			<<LengthBin/binary,W/binary>>
		end || W <- WitnessScripts
	],
	
	SigTypes = [1 || _ <- Multisignatures], % FIXME
	Hashes = hash_of_Tx_in_v0_witness_program(Tx,
		{Indexes, ScriptCodes, SigTypes}, Env),
	{M_of_Ns, MultiPubKeys} = lists:unzip(
		[
			{{Min_M,Total_N},PubKeys} ||
				{p2sh_multisig, {Min_M,Total_N},PubKeys} <- 
				[
					script:parse_redeemScript(W) || W <- WitnessScripts
				]
		]),
	% check the number of PubKeys matches <n>
	case lists:all(fun({{_M,N},MPK})-> N == length(MPK) end,
		lists:zip(M_of_Ns,MultiPubKeys)) of
		true  -> ok;
		false -> throw(missing_pubkeys)
	end,

	V = [
			begin
			VerifyFunc =
				fun({sig, S, _HashType}, {pubKey, P}) ->
					ecdsa:verify_signature(S, H, P) end,
			emulate_OP_CHECKMULTISIG(VerifyFunc, Signatures, PubKeys)
			%verify_multisig_combinations(VerifyFunc,Signatures,PubKeys))
			end
			|| {Signatures, H, PubKeys} <- lists:zip3(
				Multisignatures,
				Hashes,
				MultiPubKeys)
		],
	
	V1 = [ u:count(R,true) >= M || {R,{M,_N}} <- lists:zip(V, M_of_Ns) ],
	lists:zip(Indexes, V1).



% Witness = [<<>>,<<Sig1>>,<<Sig2>>,...,<<SigX>>,<<WitnessScript>>]
parse_witness_P2WSH(Witness) ->
	<<>> = hd(Witness), % OP_0 (for 'one-off bug')
	[WitnessScript|Most] = lists:reverse(Witness),
	SignatureBins = tl(lists:reverse(Most)), % in-between
	Signatures = [
		begin
		DERLen = byte_size(S) -1,
		<<DER:DERLen/binary,SigType>> = S,
		{sig, ecdsa:parse_signature_DER(DER), SigType}
		end
		|| S <- SignatureBins],
	{Signatures, WitnessScript}.	

% Witness = [<<Sig>><<PubKey>>]
parse_witness_P2WPKH(Witness) ->
	[S,P] = Witness,
	DERLen = byte_size(S)-1,
	<<DER:DERLen/binary,SigType>> = S,
	{
		{sig,    ecdsa:parse_signature_DER(DER), SigType},
		{pubKey, ecdsa:parse_public_key(P)}
	}.



%% Hashing for Version 0 Witness Program
%% 
%% dhash of
%%  1. TxVersion (4-byte little)
%%  2. hashPrevOuts (32-byte)
%%  3. hashSequence (32-byte)
%%  4. Outpoint (32-byte hash | 4-byte little)
%%  5. scriptCode of the input
%%  6. value of the output spent by this input (8-byte little)
%%  7. Sequence of the input
%%  8. hashOutputs (32-byte hash)
%%  9. LockTime (4-byte little)
%% 10. SigType (4-byte little)
%% 
%% ref: BIP-143
hash_of_Tx_in_v0_witness_program({_TxIdStr, TxVersion, TxIns, TxOuts, _Witnesses, LockTime, [{tx,Template}]}=Tx, {Indexes, ScriptCodes, SigTypes}, Env) ->
	HashPrevouts = protocol:dhash(
		list_to_binary([protocol:outpoint(Prevout) || {_,Prevout,_,_} <- TxIns])),
	HashSequence = protocol:dhash(
		list_to_binary([<<Sequence:32/little>> || {_,_,_,Sequence} <- TxIns])),
	% serializations of (<OutputValue><scriptPubKey>)*n
	T1 = protocol:template_default_binary_for_slots(Template,[tx_out]),
	ScriptPubKeys = [B || {scriptPubKey,B} <- T1],
	HashOutput   = protocol:dhash(
		list_to_binary([
			begin
			OutputValue = protocol:tx_output_value(Tx, I),
			ScriptPK    = lists:nth(I, ScriptPubKeys),
			<<OutputValue:64/little, ScriptPK/binary>>
			end
			|| I <- lists:seq(1,length(TxOuts))
		])),
	
	Hashes =
	[protocol:dhash(
		begin
		% for this input
		{I,Prevout,_,Sequence} = lists:nth(I,TxIns),
		SpentAmount = protocol:tx_input_value(Tx, I, Env),

		list_to_binary([
			<<TxVersion:32/little>>,    % 1.
			HashPrevouts,               % 2.
			HashSequence,               % 3.
			protocol:outpoint(Prevout), % 4.
			SC,                         % 5.
			<<SpentAmount:64/little>>,  % 6.
			<<Sequence:32/little>>,     % 7.
			HashOutput,                 % 8.
			<<LockTime:32/little>>,     % 9.
			<<ST:32/little>>            % 10.
		])
		end
	) || {I,SC,ST} <- lists:zip3(Indexes, ScriptCodes, SigTypes)
	],

	Hashes.





verify_merkle_root({{_BlockHash, _BlockVersion, _PrevBlockHash, MerkleRootHash, _Time, _Bits, _Nonce, _TxnCount}, Txns}) ->
	Txids = [protocol:hash(TxidStr) || {{TxidStr,_},_,_,_,_,_,_} <- Txns],
	protocol:hash(MerkleRootHash) == protocol:merkle_hash(Txids).


%% Witness root hash (Merkle hash of the wTxid tree) is concatenated with
%% Witness reserved value and double-sha256 hashed to obtain Commitment hash,
%% which is stored in coinbase's scriptPubKey
%% for backward compatibility reasons.
%% wTxid of coinbase is assumed to be <<0,...,0>>.
%% ref: BIP-141
%% which completely resolves Trasaction Malleability problem
witness_root_hash({{_BlockHash, _BlockVersion, _PrevBlockHash, _MerkleRootHash, _Time, _Bits, _Nonce, _TxnCount}, Txns}) ->
	WTxids  = [protocol:hash(WTxidStr) || {{_,WTxidStr},_,_,_,_,_,_} <- Txns],
	WTxids1 = [protocol:hash(?HASH256_ZERO_STR)|tl(WTxids)],
	protocol:merkle_hash(WTxids1).

verify_witness_root({CommitmentHash, WitnessReservedValue}, Block) ->
	WitnessRootHash = witness_root_hash(Block),
	protocol:dhash(<<WitnessRootHash/binary, WitnessReservedValue/binary>>) == CommitmentHash.




%% Difficulty-1 (the minimum allowed difficulty)
minimum_difficulty_target(mainnet) ->
	protocol:parse_difficulty_target(16#1d00ffff);
minimum_difficulty_target(testnet) ->
	protocol:parse_difficulty_target(16#1d00ffff);
minimum_difficulty_target(regtest) ->
	protocol:parse_difficulty_target(16#207fffff).


%% Value (in satoshi)
total_output_value(TxOuts) ->
	Values = [V || {_Idx,V,_Script} <- TxOuts],
	lists:sum(Values).

%total_input_value(TxIns, BlockChain) ->


%% ref: https://en.bitcoin.it/wiki/Protocol_rules
%% To check the validity of Tx, we need access to the blockchain.
%check_Tx({}=Tx, BlockChain) ->
%	C1 = {tx_in_counts,  length(TxIns)>0},
%	C2 = {tx_out_counts, length(TxOuts)>0},
%	C3 = {


default_port(mainnet) -> ?DEFAULT_MAINNET_INCOMING_PORT;
default_port(testnet) -> ?DEFAULT_TESTNET_INCOMING_PORT;
default_port(regtest) -> ?DEFAULT_REGTEST_INCOMING_PORT.


genesis_block_hash(regtest) -> ?REGTEST_GENESIS_BLOCK_HASH_BIN;
genesis_block_hash(testnet) -> ?TESTNET_GENESIS_BLOCK_HASH_BIN.


max_block_byte_size() -> ?MAX_BLOCK_SERIALIZED_SIZE.


-ifdef(EUNIT).

%%FIXME, protocol:read_blockdump has been removed.
%% P2PKH
%verify_signatures_in_Tx_sub() ->
%	BlockFilePath = filename:join(os:getenv("HOME"), ".bitcoin/testnet3/blocks/blk00002.dat"),
%	{ok, Bin} = file:read_file(BlockFilePath),
%	{_,Block,_}=protocol:read_blockdump(Bin),
%	{{_BlockHeader, Txs}, _Rest} = Block, 
%	[_T1,T2,_T3,_T4,_T5,_T6,_T7] = Txs,
%	?assert(lists:all(fun({_,X})->X end, verify_signatures_in_Tx(T2))),
%	ok.
%
%verify_signatures_in_Tx_test_() ->
%	[
%		{timeout, 10, fun verify_signatures_in_Tx_sub/0}
%	].


-endif.

