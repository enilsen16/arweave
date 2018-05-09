-module(ar_test_sup).
-export([start/0, start/1]).
-include("ar_network_tests.hrl").

%%% Manages the execution of long-term, full network (with simulated clients)
%%% tests. These tests run indefinitely, only reporting when they fail.

-record(state, {
	tests = [],
	finished = []
}).

%% The maximum amount of time to wait between asking nodes to start mining.
%% Setting this to a non-zero value helps better ensure an unsynchonised simulated
%% network.
-define(STAGGER_TIME, 3000).

%% @doc Starts all or a list of tests for ar_network_tests.hrl.
start() -> start(?NETWORK_TESTS).
start(TestName) when is_atom(TestName) -> start([TestName]);
start(Tests) ->
	{{Yr, Mo, Da}, {Hr, Mi, Se}} = erlang:universaltime(),
	error_logger:logfile(close),
	error_logger:logfile(
		{open,
			LogFile =
				lists:flatten(
					io_lib:format(
						"~s/test_run_"
							"~4..0b-~2..0b-~2..0b_~2..0b-~2..0b-~2..0b.log",
						[?LOG_DIR, Yr, Mo, Da, Hr, Mi, Se]
					)
				)
		}
	),
	ar:report_console([{test_log_file, LogFile}, {test_count, length(Tests)}]),
	spawn(
		fun() ->
			server(#state { tests = lists:map(fun start_test/1, Tests) })
		end
	).

%% @doc Main server loop
server(S = #state { tests = Tests, finished = Finished }) ->
	receive
		{test_report, MonitorPID, stopped, Log} ->
			Test =
				(lists:keyfind(MonitorPID, #test_run.monitor, Tests))#test_run {
					fail_time = erlang:universaltime(),
					log = Log
				},
			ar:report_console(
				[
					{name, Test#test_run.name},
					{start_time, Test#test_run.start_time},
					{failure_time, Test#test_run.fail_time},
					{log_file, ar_logging:save_log(Test)}
				]
			),
			server(
				S#state {
					tests = [start_test(Test#test_run.name)|(Tests -- [Test])],
					finished = [Test|Finished]
				}
			);
		stop ->
			lists:foreach(fun stop_test/1, Tests),
			error_logger:logfile(close)
	end.

%%% Utility functions

%% @doc Start a test, given a #network_test or test name.
%% Returns a #test_run.
start_test(RawT) when is_record(RawT, network_test) ->
	T = preprocess_test(RawT),
	Miners =
		ar_network:start(
			T#network_test.num_miners,
			T#network_test.miner_connections,
			T#network_test.miner_loss_probability,
			T#network_test.miner_max_latency,
			T#network_test.miner_xfer_speed,
			T#network_test.miner_delay
		),
	MonitorPID =
		ar_test_monitor:start(
			Miners,
			self(),
			T#network_test.check_time,
			T#network_test.failure_time
		),
	ar:report_console(starting_to_mine),
	ar_network:automine_staggered(Miners, T#network_test.stagger_time),
	ar:report_console(mining),
	#test_run {
		name = T#network_test.name,
		monitor = MonitorPID,
		miners = Miners,
		clients =
			[
				ar_sim_client:start(
					Miners,
					T#network_test.client_action_time,
					T#network_test.client_max_tx_len,
					T#network_test.client_connections
				)
			||
				_ <- lists:seq(1, T#network_test.num_clients)
			]
	};
start_test(Name) ->
	case lists:keyfind(Name, #network_test.name, ?NETWORK_TESTS) of
		false -> not_found;
		Test -> start_test(Test)
	end.

%% @doc Calculate sensible bvalues for fields left with 'calculate' atoms.
preprocess_test(T = #network_test { miner_delay = calculate }) ->
	preprocess_test(
		T#network_test {
			miner_delay = T#network_test.num_miners * ?DEFAULT_MINING_DELAY
		}
	);
preprocess_test(T) -> T.

%% @doc Stop a test run (including the clients, miners, and monitor).
stop_test(#test_run{ miners = Miners, clients = Clients, monitor = Monitor }) ->
	% Kill the clients
	lists:foreach(fun ar_sim_client:stop/1, Clients),
	% Kill the miners
	lists:foreach(fun ar_node:stop/1, Miners),
	% Cut the monitor!
	ar_test_monitor:stop(Monitor).
