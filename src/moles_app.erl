-module(moles_app).

-behaviour(application).

-export([start/2, stop/1]).


start(_StartType, KeyMod) ->
	NetType = KeyMod,
	moles_sup:start_link(NetType).

stop(_S) ->
	ok.
