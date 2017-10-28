%% ECDSA (Elliptic Curve Digital Signature Algorithm
-module(ecdsa).
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

%% Elliptic curve parameters for secp256k1
%% y^2 = x^3 + 7 over modulo p, p is a big prime
-define(P, 16#fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f).
-define(G, {
	16#79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798,
	16#483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8
	}).
% n (or q) in the literature
-define(ORDER, 16#fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141).
% bit length of ORDER
-define(ORDER_BITS, 256).


is_on_elliptic_curve({X,Y}) ->
	% Y*Y == X*X*X + 7
	mod(mod(Y*Y,?P) - mod(X*X*X,?P) - 7, ?P) == 0.


public_key(PrivateKey) when (1 =< PrivateKey) andalso (PrivateKey =< ?ORDER-1) ->
	scalar_multiply_point(PrivateKey, ?G).


%% according to the notation in RFC6979
%% NOTE: only supports when qlen % 8 == 0 (thereby qlen == blen)
bits2int(Bin) when is_binary(Bin) ->
	ByteSize = ?ORDER_BITS div 8,
	if
		ByteSize <  byte_size(Bin) ->
			<<Bin1:ByteSize/binary, _/binary>> = Bin;
		ByteSize >= byte_size(Bin) ->
			Bin1 = <<Bin/binary,0:(8*(ByteSize - byte_size(Bin)))>>
	end,
	<<Integer:?ORDER_BITS/big-unsigned>> = Bin1,
	Integer.

int2octets(Int, ?ORDER_BITS) when is_integer(Int) andalso Int<?ORDER ->
	<<Int:?ORDER_BITS/big-unsigned>>.
	

% Rondom integer - K
signature(Hash, PrivateKey, K) ->
	H = bits2int(Hash),
	{R1, _} = scalar_multiply_point(K, ?G),
	R = mod(R1, ?ORDER),
	case R of
		0 -> signature(Hash, PrivateKey, K+1);
		_ ->
			S = mod((H+mod(R*PrivateKey,?ORDER))*inverse_mod(K,?ORDER),?ORDER),
			case S of
				0 -> signature(Hash, PrivateKey, K+1);
				_ -> {R,S}
			end
	end.


% PublicKey - Point Q
% Signature - (r,s)
verify_signature({R,S}, Hash, Q) ->
	OnEC = is_on_elliptic_curve(Q),
	if
		R < 1 orelse ?ORDER-1 < R orelse S < 1 orelse ?ORDER-1 < S ->
			throw(bad_r_s);
		not OnEC ->
			throw(bad_Q);
		% TODO: check n*Q == O
		true ->
			H = bits2int(Hash),
			W = inverse_mod(S,?ORDER),
			U1 = mod(H*W,?ORDER),
			U2 = mod(R*W,?ORDER),
			P1 = scalar_multiply_point(U1,?G),
			P2 = scalar_multiply_point(U2,Q),
			{X,_} = plus_point(P1,P2),
			mod(X,?ORDER) == R
	end.

%% point calculations on an elliptic carve
double_point({X,Y}) when Y>0 ->
	Phi = mod(mod(3*X*X, ?P)*inverse_mod(2*Y, ?P), ?P),
	Psi = mod((-3*mod(X*X*X, ?P) + 2*mod(Y*Y, ?P))*inverse_mod(2*Y, ?P), ?P),
	X1 = mod(mod(Phi*Phi, ?P)-2*X, ?P),
	Y1 = mod(-Phi*X1-Psi, ?P),
	{X1,Y1}.

plus_point(pointO, {X,Y}) -> {X,Y};
plus_point({X1,Y1},{X2,Y2}) when (X1==X2) andalso (Y1==Y2) ->
	double_point({X1,Y1});
plus_point({X1,Y1},{X2,Y2}) when X1 > X2 ->
	plus_point({X2,Y2},{X1,Y1});
plus_point({X1,Y1},{X2,Y2}) when X1 < X2 ->
	Phi = mod((Y2-Y1)*inverse_mod(X2-X1, ?P), ?P),
	Psi = mod((mod(Y1*X2, ?P)-mod(Y2*X1, ?P))*inverse_mod(X2-X1, ?P), ?P),
	X3 = mod(mod(Phi*Phi, ?P)-X1-X2, ?P),
	Y3 = mod(-Phi*X3-Psi, ?P),
	{X3,Y3}.

%% scalar multiplication
%% by binary method
scalar_multiply_point(N, {X,Y}) when is_integer(N), N>0 -> scalar_multiply_point(pointO, N, {X, Y}).

scalar_multiply_point(AccPt, 0, _Pt) -> AccPt;
scalar_multiply_point(AccPt, N, Pt) ->
	{AccPt1, Pt1} = case N rem 2 of
		0 -> {AccPt,                double_point(Pt)};  
		1 -> {plus_point(AccPt,Pt), double_point(Pt)}
	end,
	scalar_multiply_point(AccPt1, N div 2, Pt1).


%% RFC6979 - Deterministic Usage of the DSA and ECDSA
%% to genratte of secure k without accessing to a souce of high-quality randomness
%% ref: https://tools.ietf.org/html/rfc6979
generate_k_on_message(M, PrivateKey) ->
	HashType = sha256,
	HashByteSize = 256 div 8,

	H = crypto:hash(HashType, M), % step a
	X_Bin = int2octets(PrivateKey, ?ORDER_BITS),
	V0 = list_to_binary(lists:duplicate(HashByteSize,16#01)), % step b
	K0 = list_to_binary(lists:duplicate(HashByteSize,16#00)), % step c

	K1 = crypto:hmac(HashType, K0,
		<<V0/binary, 16#00, X_Bin/binary, H/binary>>), % step d
	V1 = crypto:hmac(HashType, K1, V0), % step e
	K2 = crypto:hmac(HashType, K1,
		<<V1/binary, 16#01, X_Bin/binary, H/binary>>), % step f
	V2 = crypto:hmac(HashType, K2, V1), % step g
	
	until_finding_k(HashType, <<>>, K2, V2).

until_finding_k(HashType, T, K, V) when byte_size(T) < (?ORDER_BITS/8) ->
	V1 = crypto:hmac(HashType, K, V),
	until_finding_k(HashType, <<T/binary,V1/binary>>, K, V1);
until_finding_k(HashType, T, K, V) ->
	Final_k = bits2int(T),
	if
		1 =< Final_k andalso Final_k =< ?ORDER-1 ->
			Final_k;
		true ->
			K1 = crypto:hmac(HashType, K, <<V/binary, 16#00>>),
			V1 = crypto:hmac(HashType, K1, V),
			until_finding_k(HashType, T, K1, V1)
	end.


%% signature serialized usgin DER
signature_DER({R,S}) ->
	% DER Signed Integer - 0x02
	% DER Compound Structure - 0x30
	R_Bin = <<R:?ORDER_BITS/big>>,
	<<R_FirstBit:1, _/bitstring>> = R_Bin,
	R_Bin1 = case R_FirstBit of
		0 -> R_Bin;
		1 -> <<0:8, R_Bin/binary>> % make it positive
	end,
	S_Bin = <<S:?ORDER_BITS/big>>,
	<<S_FirstBit:1, _/bitstring>> = S_Bin,
	S_Bin1 = case S_FirstBit of
		0 -> S_Bin;
		1 -> <<0:8, S_Bin/binary>>
	end,
	R_ByteLen = byte_size(R_Bin1),
	S_ByteLen = byte_size(S_Bin1),
	R_DER = <<16#02, R_ByteLen:8, R_Bin1/binary>>,
	S_DER = <<16#02, S_ByteLen:8, S_Bin1/binary>>,
	CompoundLen = byte_size(R_DER) + byte_size(S_DER),
	<<16#30, CompoundLen:8, R_DER/binary, S_DER/binary>>.

parse_signature_DER(<<16#30, CompoundLen:8, Rest:CompoundLen/binary>>) ->
	<<16#02, R_ByteLen:8, R_Bin:R_ByteLen/binary, Rest1/binary>> = Rest,
	<<16#02, S_ByteLen:8, S_Bin:S_ByteLen/binary, _Rest2/binary>> = Rest1,
	
	%<<R:(R_ByteLen*8)/big>> = R_Bin,
	%<<S:(S_ByteLen*8)/big>> = S_Bin,
	R_ZeroBitLen = 8*R_ByteLen - ?ORDER_BITS,
	S_ZeroBitLen = 8*S_ByteLen - ?ORDER_BITS,
	<<0:R_ZeroBitLen, R:?ORDER_BITS/big>> = R_Bin,
	<<0:S_ZeroBitLen, S:?ORDER_BITS/big>> = S_Bin,

	{R,S}.

%% ref: https://bitcoin.org/en/developer-guide#public-key-formats
%% uncompressed format - 0x04 <X> <Y>
%% compressed format -   0x02 <X> when Y is even num.
%%                       0x03 <X> when Y is odd num.
parse_public_key(<<16#04, X:256/big, Y:256/big>>) -> {X,Y};
parse_public_key(<<16#02, X:256/big>>) ->
	{Y1,Y2} = qy_from_qx(X),
	case Y1 rem 2 of
		0 -> {X,Y1};
		1 -> {X,Y2}
	end;
parse_public_key(<<16#03, X:256/big>>) ->
	{Y1,Y2} = qy_from_qx(X),
	case Y1 rem 2 of
		0 -> {X,Y2};
		1 -> {X,Y1}
	end.



%% obtain Qy of public key from Qx
%% E: y^2 == x^3 + 7 mod P
qy_from_qx(X) ->
	sqrt_mod(mod(mod(X*X,?P)*X+7,?P), ?P).


%% Euler's criterion
%% P - odd prime
%% evaluate N^((P-1)/2) mod P
euler_criterion(N, P) ->
	Eu = modpow(N, (P-1) div 2, P),
	if
		Eu == P-1 -> -1;
		true -> Eu
	end.

%% N = Q 2^S
obtain_Q_2S(N) -> obtain_Q_2S(N, 0).

obtain_Q_2S(Q, S) ->
	case Q rem 2 of
		0 -> obtain_Q_2S(Q div 2, S+1);
		1 -> {Q, S}
	end.

%% P - odd prime
find_quadratic_non_residue(P) -> find_quadratic_non_residue(2, P).

find_quadratic_non_residue(Z, P) when Z < P ->
	case euler_criterion(Z, P) of
		-1 -> Z;
		 1 -> find_quadratic_non_residue(Z+1, P)
	end.

%% T^(2^I) == 1 mod P
find_2pI(T, P) when T/=0 -> find_2pI({T, 0}, T, P).

find_2pI({Acc, I}, T, P) ->
	case mod(Acc, P) of
		1 -> I;
		_ -> find_2pI({mod(Acc*Acc,P), I+1}, T, P)
	end.

%% 2^N
pow2(N) when is_integer(N) andalso N>=0 -> pow2(1, N).

pow2(Acc, 0) -> Acc;
pow2(Acc, N) -> pow2(2*Acc, N-1).

%% obtaining modular square root of n
%% by using Tonelli-Shanks algorithm
%% ref: https://en.wikipedia.org/wiki/Tonelli%E2%80%93Shanks_algorithm
%% P - odd prime
sqrt_mod(N, P) ->
	case euler_criterion(N, P) of
		 0 -> 0;
		-1 -> throw(is_a_quadratic_non_residue);
		 1 ->
			{Q, S} = obtain_Q_2S(P-1),
		 	Z = find_quadratic_non_residue(P),
			R = sqrt_mod_loop(
				{
					S, 
					modpow(Z, Q, P),
					modpow(N, Q, P),
					modpow(N, (Q+1) div 2, P)
				}, P),
			{R, P-R}
	end.

sqrt_mod_loop({M, C, T, R}, P) ->
	case T of
		1 -> R;
		_ ->
			I = find_2pI(T, P),
			B = modpow(C, pow2(M-I-1), P),
			sqrt_mod_loop(
			{
				I,
				mod(B*B, P),
				mod(T*B*B, P),
				mod(R*B, P)
			}, P)
	end.


%% Modular
mod(A, M) when is_integer(A), is_integer(M), A>=0, M>0 ->
	A rem M;
mod(A, M) when is_integer(A), is_integer(M), A<0, M>0 ->
	A rem M + M.


%% Inverse Modular
%% by Extended Euclidean algirithm
euclidean_div(R0, 0,  S0, _S1, T0, _T1) when R0 > 0 -> {R0, S0, T0};
euclidean_div(R0, R1, S0, S1, T0, T1) when R0 > R1 ->
	Q = R0 div R1,
	euclidean_div(R1, R0-Q*R1, S1, S0-Q*S1, T1, T0-Q*T1);
euclidean_div(R0, R1, S0, S1, T0, T1) when R0 < R1 ->
	euclidean_div(R1, R0, S1, S0, T1, T0).

inverse_mod(A, M) when is_integer(A), is_integer(M), A>0, M>0 ->
	{GDC, InvMod, _} = euclidean_div(A, M, 1, 0, 0, 1),
	case GDC of
		1 -> mod(InvMod, M); % for possible negative value
		_ -> throw(no_inverse_mod)
	end.

%% N^P mod M
%% by using binary method
%% 
%% Erlang's crypto:mod_pow() returnes binary
%% <<R/big>> = crypto:mod_pow(N, P, M), % doesn't work for large integers
modpow(N, P, M) when is_integer(P) andalso P>0 -> modpow(1, N, P, M).

modpow(Acc, _, 0, _) -> Acc;
modpow(Acc, N, P, M) ->
	{Acc1, N1} = case P rem 2 of
		0 -> {Acc,           mod(N*N, M)};
		1 -> {mod(Acc*N, M), mod(N*N, M)}
	end,
	modpow(Acc1, N1, P div 2, M).



-ifdef(EUNIT).


parse_signature_DER_test_() ->
[
	?_assertEqual(parse_signature_DER(protocol:hexstr_to_bin("30450221009eb819743dc981250daaaab0ad51e37ba47f7fb4ace61f6a69111850d6f2990502206b6e59e1c002a4e35ba2be4d00366ea0f3e0b14c829907920705bce336ab2945")),
	{16#9eb819743dc981250daaaab0ad51e37ba47f7fb4ace61f6a69111850d6f29905,
	16#6b6e59e1c002a4e35ba2be4d00366ea0f3e0b14c829907920705bce336ab2945})
].


-endif.
