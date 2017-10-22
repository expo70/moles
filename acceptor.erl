-module(acceptor).

-behaviour(gen_server).

-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {}).


%% API
start_link(Port) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [Port], []).


%% callbacks
init([]) ->
	{ok, #state{}}.

handle_call(_Request, _From, S) ->
	{reply, ignored, S}.

handle_cast(_Msg, S) ->
	{noreply, S}.

handle_info(_Info, S) ->
	{noreply, S}.

terminate(_Reason, _S) ->
	ok.

code_change(_OldVsn, S, _Extra) ->
	{ok, S}.

%% Internal functions

