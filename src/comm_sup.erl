%% Supervisor of comm
%%
-module(comm_sup).

-behaviour(supervisor).

% API
-export([start_link/0, add_comm/2]).

% supervisor callback
-export([init/1]).


%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link() ->
	Args = [],
	supervisor:start_link({local,?MODULE}, ?MODULE, Args).

add_comm(NetType, {CommType, CommTarget}) ->
	% Children are started by 
	% comm:start_link([]+[NetType, {CommType, CommTarget}]).
	supervisor:start_child(?MODULE, [NetType, {CommType, CommTarget}]).


%% ----------------------------------------------------------------------------
%% supervisor callback
%% ----------------------------------------------------------------------------
init([]) ->
	SupFlags = #{strategy => simple_one_for_one
		%intensity =>,
		%period =>
		},
	ChildSpec = #{id => comm,
		start => {comm, start_link, []}, % actual Args are defined in init() after start_child for simple_one_for_one processes
		restart => temporary, % i.e. never restarted
		shutdown => 1000, % 1 sec.
		type => worker,
		modules => [comm]
		},
	
	{ok,{SupFlags,[ChildSpec]}}.


	

