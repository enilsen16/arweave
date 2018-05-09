-module(ar_firewall).
-export([start/0, scan/3]).
-include("ar.hrl").
-include("av/av_recs.hrl").
-include_lib("eunit/include/eunit.hrl").
%%% Archain firewall implementation.
%%% TODO: Call out to av_* functions.

%% State definition. Should store compiled
%% binary scan objects.
-record(state, {
	sigs = []
}).

%% Start a firewall node.
start() ->
	spawn(
		fun() ->
			server(#state {
				sigs = av_sigs:all()
			})
		end
	).

%% Check that a received object does not match
%% the firewall rules.
scan(PID, Type, Data) ->
	PID ! {scan, self(), Type, Data},
	receive
		{scanned, Obj, Response} -> Response
	end.

server() -> server(#state{}).
server(S = #state{ sigs = Sigs}) ->
	receive
		{scan, PID, Type, Data} ->
			Pass = case Type of
				block -> true;
				tx -> (not scan_transaction(Data, Sigs));
				_ -> false
			end,
			PID ! {scanned, Data, Pass},
			server(S)
	end.

scan_transaction(TX, Sigs) ->
	av_detect:is_infected(TX#tx.data, Sigs).

blacklist_transaction_test() ->
Sigs = #sig{
	name = "Test",
	type = binary,
	data = #binary_sig{
		target_type = "0",
		offset = any,
		binary = <<"badstuff">>
	}
},
{true, _} = scan_transaction(ar_tx:new(<<"badstuff">>), [Sigs]),
false = scan_transaction(ar_tx:new(<<"goodstuff">>), [Sigs]).
