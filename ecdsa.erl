%% ECDSA (Elliptic Curve Digital Signature Algorithm
-module(ecdsa).

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

% PrivateKey - integer K
signature(Hash, K) ->
	H = bits2int(Hash),
	{R1, _} = scalar_multiply_point(K, ?G),
	R = mod(R1, ?ORDER),
	case R of
		0 -> signature(Hash, K+1);
		_ ->
			S = mod((H+mod(K*R,?ORDER))*inverse_mod(K,?ORDER),?ORDER),
			case S of
				0 -> signature(Hash, K+1);
				_ -> {R,S}
			end
	end.

% PublicKey - Point Q
% Signature - (r,s)
verify_signature({R,S}, Hash, Q) ->
	if
		R < 1 orelse ?ORDER-1 < R orelse S < 1 orelse ?ORDER-1 < S ->
			throw(bad_r_s);
		true ->
			% TODO: check Q is on E
			% TODO: check n*Q == O
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

