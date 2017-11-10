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


%%
%% Entry = {Type, JobSpec, ExpirationTime, Stamps}
handle_call({find_job, IP_Address}, _From, S) ->
	Tid = S#state.tid_jobs,
	
	case ets:lookup(Tid, IP_Address) of
		[Job|_T] ->
			ets:delete_object(Job);
		[] ->
			case ets:lookup(Tid, all) of
				[Job|_T] ->
					{all, JobSpec, ExpirationTime, Stamps} = Job,
					case lists:member(IP_Address, Stamps) of
						true ->
							case ets:lookup(Tid, any) of
								[Job|_T] ->
									ets:delete_object(Job);
								[] -> Job = []
							end;
						false ->
							ets:delete_object(Job),
							UpdatedJob = {all, JobSpec, ExpirationTime,
								[IP_Address|Stamps]},
							ets:insert_new(Tid, UpdatedJob)
					end;
				[] ->
					case ets:lookup(Tid, any) of
						[Job|_T] ->
							ets:delete_object(Job);
						[] -> Job = []
					end
			end
	end,

	{reply, Job, S}.


handle_cast({add_job, Job}, S) ->
	Tid = S#state.tid_jobs,

	true = ets:insert(Tid, Job),
	{noreply, S}.


handle_info(check_expiration, S) ->
	Tid = S#state.tid_jobs,

	CurrentTime = erlang:system_time(second),
	% delete expired jobs
	_N_Entries = ets:select_delete(Tid, [{{'_','_','$1','_'},[{'<','$1',CurrentTime}],[true]}]),
	{noreply, S}.


%% ----------------------------------------------------------------------------
%% Internal functions
%% ----------------------------------------------------------------------------



