-module(seeder).

-export(seeds/0)

ns_lookup(Name, Class, Type) ->
	case inet_res:resolve(Name, Class, Type) of
		{ok,Msg} ->
			[inet_dns:rr(RR, data)
			|| RR <- inet_dns:msg(Msg, anlist),
				inet_dns:rr(RR, type) =:= Type,
				inet_dns:rr(RR, class) =:= Class];
		{error,_} ->
			[]
	end.

seeds() ->
	ns_lookup("testnet-seed.bitcoin.schildbach.de", in, a).
