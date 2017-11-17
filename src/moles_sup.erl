-module(moles_sup).

-behaviour(supervisor).

-export([init/1]).

-export([start_link/1]).


start_link(NetType) ->
	Args = [NetType],
	supervisor:start_link({local,?MODULE}, ?MODULE, Args).


init([NetType]) ->
	SupFlags = #{strategy => one_for_one},

	ChildSpec0 = #{id => tx,
		start => {tx, start_link, [NetType]},
		restart => permanent,
		shutdown => 3000, %timeout value
		type => worker,
		modules => [tx]},
	ChildSpec1 = #{id => blockchain,
		start => {blockchain, start_link, [NetType]},
		restart => permanent,
		shutdown => 3000, %timeout value
		type => worker,
		modules => [blockchain]},
	ChildSpec2= #{id => peer_finder,
		start => {peer_finder, start_link, [NetType]},
		restart => permanent,
		shutdown => 3000, %timeout value
		type => worker,
		modules => [peer_finder]},
	ChildSpec3 = #{id => jobs,
		start => {jobs, start_link, []},
		restart => permanent,
		shutdown => 3000, %timeout value
		type => worker,
		modules => [jobs]},
	ChildSpec4 = #{id => comm_sup,
		start => {comm_sup, start_link, []},
		restart => permanent,
		shutdown => 3000, %timeout value
		type => supervisor,
		modules => [comm_sup]},
	ChildSpec5 = #{id => strategy,
		start => {strategy, start_link, [NetType]},
		restart => permanent,
		shutdown => 3000, %timeout value
		type => worker,
		modules => [strategy]},
	ChildSpec6 = #{id => acceptor,
		start => {acceptor, start_link, [NetType]},
		restart => permanent,
		shutdown => 3000, %timeout value
		type => worker,
		modules => [acceptor]},
	
	{ok,{SupFlags,
		[
		ChildSpec0,
		ChildSpec1,
		ChildSpec2,
		ChildSpec3,
		ChildSpec4,
		ChildSpec5,
		ChildSpec6
		]}}.

