-module(moles_app).

-behaviour(application).

-export([start/2, stop/1]).

-export([start/0, stop/0]).

%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start() -> {ok,_} = application:ensure_all_started(moles).

stop() -> application:stop(moles).


%% ----------------------------------------------------------------------------
%% application callback
%% ----------------------------------------------------------------------------
start(_StartType, KeyMod) ->
	[NetType] = KeyMod,
	moles_sup:start_link(NetType).

stop(_S) ->
	ok.
