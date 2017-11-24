%%
%% Job server
%%
-module(jobs).

-behaviour(gen_server).

-record(state,
	{
		tid_jobs
	}).

%% API
-export([start_link/0, add_job/1, find_job/1]).

%% gen_server callback
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CHECK_EXPIRATION_INTERVAL, 10*1000).



%% ----------------------------------------------------------------------------
%% API
%% ----------------------------------------------------------------------------
start_link() ->
	Args = [],
	gen_server:start_link({local,?MODULE}, ?MODULE, Args, []).

add_job(Job) ->
	gen_server:cast(?MODULE, {add_job, Job}).

find_job(IP_Address) ->
	gen_server:call(?MODULE, {find_job, IP_Address}).


%% ----------------------------------------------------------------------------
%% gen_server callback
%% ----------------------------------------------------------------------------
init([]) ->
	Tid = ets:new(jobs, [bag]),
	
	InitialState = #state{tid_jobs=Tid},

	erlang:send_after(?CHECK_EXPIRATION_INTERVAL, self(), check_expiration),
	{ok, InitialState}.


%% Priority: all > IP_Address > any
%%
%% Entry = {Target, JobSpec, ExpirationTime, Stamps}
handle_call({find_job, IP_Address}, _From, S) ->
	Tid = S#state.tid_jobs,
	
	case ets:lookup(Tid, all) of
		[Job|_] ->
			{all, JobSpec, ExpirationTime, Stamps} = Job,
			case lists:member(IP_Address, Stamps) of
				true -> Job1 = not_available;
				false ->
					ets:delete_object(Tid, Job),
					UpdatedJob = {all, JobSpec, ExpirationTime,
					[IP_Address|Stamps]},
					ets:insert_new(Tid, UpdatedJob),
					Job1 = Job
			end;
		[] -> Job1 = not_available
	end,

	case Job1 of
		not_available ->
			case ets:lookup(Tid, IP_Address) of
				[Job2|_] ->
					ets:delete_object(Tid, Job2);
				[] -> Job2 = not_available
			end;
		_ -> Job2 = Job1
	end,

	case Job2 of
		not_available ->
			case ets:lookup(Tid, any) of
				[Job3|_] ->
					ets:delete_object(Tid, Job3);
				[] -> Job3 = not_available
			end;
		_ -> Job3 = Job2
	end,

	{reply, Job3, S}.


handle_cast({add_job, {{except, IP_Address},JobSpec,DurationInSec}}, S) ->
	Tid = S#state.tid_jobs,
	Job = {all, JobSpec, erlang:system_time(second)+DurationInSec,
		[IP_Address]},
	
	true = ets:insert(Tid, Job),
	{noreply, S};
handle_cast({add_job, {Target,JobSpec,DurationInSec}}, S) ->
	Tid = S#state.tid_jobs,
	Job = {Target, JobSpec, erlang:system_time(second)+DurationInSec, []},

	true = ets:insert(Tid, Job),
	{noreply, S}.


handle_info(check_expiration, S) ->
	Tid = S#state.tid_jobs,

	CurrentTime = erlang:system_time(second),
	% delete expired jobs
	N_Entries = ets:select_delete(Tid, [{{'_','_','$1','_'},
		[{'<','$1',CurrentTime}],[true]}]),
	case N_Entries of
		0 -> ok;
		_ -> io:format("~w jobs were discarded.~n", [N_Entries])
	end,
	
	erlang:send_after(?CHECK_EXPIRATION_INTERVAL, self(), check_expiration),
	{noreply, S}.


%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------



