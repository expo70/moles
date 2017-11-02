%% Utility module
%%
%% functions for general use
-module(u).

-compile(export_all).


%% Boolean
%%
%% NOTE: you can use lists:all/lists:any for similar purpose
all_true([Bool]) when is_boolean(Bool) -> Bool;
all_true([H|T])  when is_boolean(H) -> H andalso all_true(T).

any_true([Bool]) when is_boolean(Bool) -> Bool;
any_true([H|T])  when is_boolean(H) -> H orelse any_true(T).


%% Hex string (Octets)
%%
bin_to_hexstr(Bin) -> error.

bin_to_hexstr(Bin, big_endian) -> bin_to_hexstr(Bin);
bin_to_hexstr(Bin, little_endian) -> bin_to_hexstr(
	list_to_binary(lists:reverse(binary_to_list(Bin)))).

hexstr_to_bin("") -> <<>>;
hexstr_to_bin(Str) ->
	T = partition(Str, 2),
	list_to_binary([list_to_integer(S,16) || S <- T]).

hexstr_to_bin(Str,Sep) ->
	T = string:tokens(Str,Sep),
	list_to_binary([list_to_integer(S,16) || S <- T]).

read_rawhex_file(Path) ->
	{ok,Bin} = file:read_file(Path),
	L = [Byte || Byte <- binary_to_list(Bin), lists:member(Byte,[$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,$a,$b,$c,$d,$e,$f,$A,$B,$C,$D,$E,$F])],
	hexstr_to_bin(L).



%% Matrix (= list of list) transpose
%% ref: https://stackoverflow.com/questions/5389254/transposing-a-2-dimensional-matrix-in-erlang
transpose([]) -> error(empty_matrix); % to prevent infinity loop
transpose([[]|_]) -> [];
transpose(M) ->
  [lists:map(fun hd/1, M) | transpose(lists:map(fun tl/1, M))].

%% Ranges
% A - B
range(Max) when is_integer(Max), Max>0 ->
	lists:seq(1,Max).

subtract_range(RangeA, RangeB) ->
	[Elm || Elm <- RangeA, not lists:member(Elm, RangeB)].

%% Partition
% from https://stackoverflow.com/questions/31395608/how-to-split-a-list-of-strings-into-given-number-of-lists-in-erlang
partition(L, N) when is_integer(N), N > 0 ->
	partition(N, 0, L, []).

partition(_, _, [], Acc) ->
	[lists:reverse(Acc)];
partition(N, N, L, Acc) ->
	[lists:reverse(Acc) | partition(N, 0, L, [])];
partition(N, X, [H|T], Acc) ->
	partition(N, X+1, T, [H|Acc]).


%% Count
%% count specific item in a list
count(L, Item) -> count(0, L, Item).

count(Count, [], Item) -> Count;
count(Count, [H|T], Item) ->
	case H of
		Item -> count(Count+1,T,Item);
		_    -> count(Count,  T,Item)
	end.

