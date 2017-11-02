%% Concensus and obiligatory rules for the integrity of the Bitcoin Block Chain
%%
-module(rules).
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-define(HASH256_ZERO, "0000000000000000000000000000000000000000000000000000000000000000").

%% Critical limitations
%% bitcoin/src/consensus/consensus.h
%%-define(
-define(COINBASE_MATURITY, 100).


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
	Delegated =
	if
		length(Signatures) /= N_TxIns ->
			Unfiltered = u:subtract_range(u:range(N_TxIns), Indexes),
			verify_signatures_in_Tx2(Tx, Unfiltered);
		length(Signatures) == N_TxIns -> []
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
					{scriptSig, lists:nth(N, Marks)},N),
			TS2 = protocol:template_fill_nth(TS1,
					{scriptSig, protocol:var_int(0)},any),
			B = protocol:template_to_binary(TS2),
			HT = lists:nth(N, HashTypes),
			<<B/binary, HT:32/little>> % HashType should be appended
			end
					) || N <- Indexes],
	
	V = lists:zipwith3(fun(S,H,P) -> ecdsa:verify_signature(S,H,P) end,
		Signatures, SignedHashes, PublicKeys),
	lists:sort(fun({I1,_},{I2,_}) -> I1=<I2 end, 
		lists:zip(Indexes,V) ++ Delegated).

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
			[ ] -> [[],[],[],[]];
			 _  -> u:transpose(ToProcess)
		end,
	Delegated =
	if
		length(Indexes1) /= length(Indexes) ->
			Unfiltered = u:subtract_range(Indexes, Indexes1),
			%[Unfiltered, verify_signatures_in_Tx3(Tx, Unfiltered)];
			%throw(Unfiltered);
			%FIXME
			[];

		length(Indexes1) == length(Indexes) -> []
	end,
	%% For P2SH scripts, the Mark used when signinig is RedeemScript.
	%% ref: http://www.soroushjp.com/2014/12/20/bitcoin-multisig-the-hard-way-understanding-raw-multisignature-bitcoin-transactions/
	Marks = RedeemScripts,
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
		% OP_CHECKMULTISIG does not check the all the combinations of
		% signatures and public keys because of its behaviour on the
		% stack machine. Each signature on the top comsumes public keys
		% until it finds an ECDSA match. 
		% We emulate this behaviour.
		VerifyFunc =
		fun({sig, S, HashType}, {pubKey, P}) ->
		ecdsa:verify_signature(
			S,
			% We only handle the case when HashType == 1.
			% redeemScript itself (without precedent push OP) is used for 
			% filling the pre-signed data when calculating hash.
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
			P
			)
		end,
		V = emulate_OP_CHECKMULTISIG(VerifyFunc, Signatures, PubKeys),
		u:count(V,true) >= Min_M. % m-of-n check


% a stack machine for OP_CHECKMULTISIG
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
	WTxids1 = [protocol:hash(?HASH256_ZERO)|tl(WTxids)],
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



-ifdef(EUNIT).

%% P2PKH
verify_signatures_in_Tx_sub() ->
	BlockFilePath = filename:join(os:getenv("HOME"), ".bitcoin/testnet3/blocks/blk00002.dat"),
	{ok, Bin} = file:read_file(BlockFilePath),
	{_,Block,_}=protocol:read_blockdump(Bin),
	{{_BlockHeader, Txs}, _Rest} = Block, 
	[_T1,T2,_T3,_T4,_T5,_T6,_T7] = Txs,
	?assert(lists:all(fun({_,X})->X end, verify_signatures_in_Tx(T2))),
	ok.

verify_signatures_in_Tx_test_() ->
	[
		{timeout, 10, fun verify_signatures_in_Tx_sub/0}
	].

%% P2SH & multisig
verify_signatures_in_Tx_sub2() ->
	TxFilePath = filename:join(os:getenv("HOME"), "moles/test-txs/e0d9e3f42b5bc6ef100514428c0a6306d073a0070035659c6e1b33dcd5827176.rawhex"),
	{T,_} = protocol:read_tx(u:read_rawhex_file(TxFilePath)),

	ok.



-endif.

