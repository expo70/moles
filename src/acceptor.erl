%%
%% Listen and accept (incoming communications)
%%
%% Erlang's gen_tcp module only supports blocking accept call.
%% On the other hand, OTP compilent processes require non-blocking message
%% passings. Asynchronous TCP acceptor thus cannot be implemented using
%% curently documented OTP framework.
%% ref: http://www2.erlangcentral.org/wiki/?title=Building_a_Non-blocking_TCP_server_using_OTP_principles
%%
%% Here we spawn raw temporary process for asynchronous accepts. The connected
%% socket is transfered to the acceptor process and then to a new comm process.
%% This is important because sockets are owned by a process and closed when the
%% process (controlling process) is shut down.
%%
%% This process listens a port and accepts one by one.
-module(acceptor).

-behaviour(gen_server).

-record(state,
	{
		net_type,
		port,
		listen_socket,
		socket % (continue to be overwritten)
	}).

%% API
-export([start_link/1, request_control/2]).

%% gen_server callback
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).


%%-----------------------------------------------------------------------------
%% API
%%-----------------------------------------------------------------------------
start_link(NetType) ->
	Args = [NetType],
	gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

request_control(Socket, CallingPid) ->
	gen_server:call(?MODULE, {request_control, Socket, CallingPid}).



%%-----------------------------------------------------------------------------
%% gen_server callback
%%-----------------------------------------------------------------------------
init([NetType]) ->
	Port = rules:default_port(NetType),
	% non-blocking
	case gen_tcp:listen(Port, [binary, {packet,0}, {active, false}]) of
		{ok, ListenSocket} ->
			InitialState = #state{
				net_type = NetType,
				port = Port,
				listen_socket = ListenSocket
				},
			start_child_acceptor(ListenSocket),
			{ok, InitialState};
		{error, Reason} ->
			{stop, {listen_failed, Reason}}
	end.


handle_call({request_control, Socket, CallingPid}, _From, S) ->
	{reply,
		% makes CallingPid the controling process of the Socket
		gen_tcp:controlling_process(Socket, CallingPid),
		S}.


handle_cast({accept, Socket}, S) ->
	NetType = S#state.net_type,
	Port = S#state.port,
	io:format("Port ~w accepted incoming connection ~p~n", [Port, Socket]),
	
	comm_sup:add_comm(NetType, {incoming, Socket}),
	
	{noreply, S#state{socket=Socket}}.


handle_info(_Info, S) ->
	{noreply, S}.


%%-----------------------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------------------
start_child_acceptor(ListenSocket) ->
	MyPid = self(),
	_Pid = spawn_link(fun() -> accept_once(MyPid, ListenSocket) end).


% child process
accept_once(ParentPid, ListenSocket) ->
	% blocking
	case gen_tcp:accept(ListenSocket) of
		{ok, Socket} ->
			ok = gen_tcp:controlling_process(Socket, ParentPid),
			gen_server:cast(?MODULE, {accept, Socket});
		{error, Reason} ->
			io:format("gen_tcp:accept() failed: Reason = ~w~n", [Reason]),
			ok
	end,
	start_child_acceptor(ListenSocket).
