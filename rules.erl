%% Concensus and obiligatory rules for the integrity of the Bitcoin Block Chain
%%
-module(rules).
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).


%% Critical limitations
%% bitcoin/src/consensus/consensus.h
%%-define(


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

	[Indexes, Signatures, HashTypes, PublicKeys] = u:transpose([
		[Idx,S,1,P] || {Idx, _PreviousOutput, {scriptSig, {{sig, S, 1},{pubKey, P}}}, _Sequence} <- TxIns
	]),
	Delegated =
	if
		length(Signatures) /= N_TxIns ->
			Unfiltered = u:subtract_range(lists:seq(0,N_TxIns), Indexes),
			[Unfiltered, verify_signatures_in_Tx2(Tx, Unfiltered)];
		length(Signatures) == N_TxIns -> [[],[]]
	end,
	
	%% This is what fills in scriptSig slots when signing.
	%% FIXME
	%% In the original implementation, the slots are filled
	%% by signaturePubKey in the previous outputs (in prev Tx).
	%% But here, I only uses the most common P2PKH scriptPubKey as
	%% an easy alternative.
	Marks = [protocol:start_with_var_int(script:create_P2PKH_scriptPubKey(P,compressed)) || P <- PublicKeys],

	T1 = protocol:template_fill_nth(Template, {tx_in,  fun(X)->X end}, any),
	T2 = protocol:template_fill_nth(T1      , {tx_out, fun(X)->X end}, any),
	% makes scriptPubKey slots are filled by the original binaries
	TemplateSig = protocol:template_fill_nth(T2, {scriptPubKey, fun(X)->X end}, any),
	SignedHashes =
		[protocol:dhash(
			%% procedure when HashType == SIGHASH_ALL(1)
			begin
			T3 = protocol:template_fill_nth(TemplateSig,
					{scriptSig, lists:nth(N, Marks)},N),
			T4 = protocol:template_fill_nth(T3,
					{scriptSig, protocol:var_int(0)},any),
			B = protocol:template_to_binary(T4),
			HT = lists:nth(N, HashTypes),
			<<B/binary, HT:32/little>> % HashType should be appended
			end
					) || N <- Indexes],
	
	V = lists:zipwith3(fun(S,H,P) -> ecdsa:verify_signature(S,H,P) end,
		Signatures, SignedHashes, PublicKeys),
	lists:sort(fun({I1,_},{I2,_}) -> I1=<I2 end, 
		lists:zip(Indexes,V) ++ apply(lists,zip,Delegated)).

%% Verify P2SH signatures
%% 
%% For P2SH scripts, the Mark used when signinig is RedeemScript.
%% ref: http://www.soroushjp.com/2014/12/20/bitcoin-multisig-the-hard-way-understanding-raw-multisignature-bitcoin-transactions/
verify_signatures_in_Tx2({_TxIdStr, _TxVersion, TxIns, _TxOuts, _Witnesses, _LockTime, [{tx,Template}]}=Tx, Indexes) ->
	ok.





verify_merkle_root({{_BlockHash, _BlockVersion, _PrevBlockHash, MerkleRootHash, _Time, _Bits, _Nonce, _TxnCount}, Txns}) ->
	Txids = [protocol:hash(TxidStr) || {{TxidStr,_},_,_,_,_,_,_} <- Txns],
	protocol:hash(MerkleRootHash) == protocol:merkle_hash(Txids).


%% Merkle hash of the wTxid tree is stored in coinbase's scriptPubKey
%% for backward compatibility reasons.
%% wTxid of coinbase is assumed to be 0.
%% ref: BIP-141
%% which completely resolves Trasaction Malleability problem
verify_witness_root(WitnessRootHash, {{_BlockHash, _BlockVersion, _PrevBlockHash, _MerkleRootHash, _Time, _Bits, _Nonce, _TxnCount}, Txns}) ->
	WTxids  = [protocol:hash(WTxidStr) || {{_,WTxidStr},_,_,_,_,_,_} <- Txns],
	WTxids1 = [0|tl(WTxids)],
	protocol:hash(WitnessRootHash) == protocol:merkle_hash(WTxids1).


%% Difficulty-1 (the minimum allowed difficulty)
minimum_difficulty_target(mainnet) ->
	protocol:parse_difficulty_target(16#1d00ffff);
minimum_difficulty_target(testnet) ->
	protocol:parse_difficulty_target(16#1d00ffff);
minimum_difficulty_target(regtest) ->
	protocol:parse_difficulty_target(16#207fffff).

-ifdef(EUNIT).

verify_signatures_in_Tx_sub() ->
	{ok, Bin} = file:read_file("/home/kanso/.bitcoin/testnet3/blocks/blk00002.dat"),
	{_,Block,_}=protocol:read_blockdump(Bin),
	{{_BlockHeader, Txs}, _Rest} = Block, 
	[_T1,T2,_T3,_T4,_T5,_T6,_T7] = Txs,
	?assertEqual(lists:all(fun({_,X})->X end, verify_signatures_in_Tx(T2)), true),
	ok.

verify_signatures_in_Tx_test_() ->
	[
		{timeout, 10, fun verify_signatures_in_Tx_sub/0}
	].



-endif.

