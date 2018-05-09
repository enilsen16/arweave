-module(ar_bridge).
-export([start/0, start/1, start/2, start/3]).
-export([add_tx/2, add_block/4]). % Called from ar_http_iface
-export([add_remote_peer/2, add_local_peer/2]).
-export([get_remote_peers/1]).
-export([start_link/1]).
-export([ignore_id/2]).
-export([ignore_peer/2]).
-include("ar.hrl").

%%% Represents a bridge node in the internal gossip network
%%% to the external message passing interfaces.

%% Internal state definition.
-record(state, {
	protocol = http, % Interface to bridge across
	gossip, % Gossip state
	external_peers, % Peers to send message to.
	processed = [], % IDs to ignore.
	firewall = ar_firewall:start(),
	port,
	ignored_peers = []
}).

%%@doc Start a node, linking to a supervisor process
start_link(Args) ->
	PID = erlang:apply(ar_bridge, start, Args),
	{ok, PID}.

%% Launch a bridge node.
start() -> start([]).
start(ExtPeers) -> start(ExtPeers, []).
start(ExtPeers, IntPeers) -> start(ExtPeers, IntPeers, ?DEFAULT_HTTP_IFACE_PORT).
start(ExtPeers, IntPeers, Port) ->
    PID =
		spawn(
			fun() ->
				server(
					#state {
						gossip = ar_gossip:init(IntPeers),
						external_peers = ExtPeers,
						port = Port
					}
				)
			end
		),
	reset_timer(PID, get_more_peers),
	PID.

%% Get a list of remote peers
get_remote_peers(PID) ->
	PID ! {get_peers, remote, self()},
	receive
		{remote_peers, ExternalPeers} ->
			ExternalPeers
	end.

%% Notify the bridge of a new external block.
%% TODO: Add peer sending to bridge implementation.
add_block(PID, OriginPeer, Block, RecallBlock) ->
	PID ! {add_block, OriginPeer, Block, RecallBlock}.

%% Notify the bridge of a new external block.
add_tx(PID, TX) ->
	PID ! {add_tx, TX}.

%% Add a remote HTTP peer.
add_remote_peer(PID, Node) ->
	PID ! {add_peer, remote, Node}.

%% Add a local gossip peer.
add_local_peer(PID, Node) ->
	PID ! {add_peer, local, Node}.

%% Ignore messages matching the given ID.
ignore_id(PID, ID) ->
	PID ! {ignore_id, ID}.

%% Schedule a message timer.
reset_timer(PID, get_more_peers) ->
	erlang:send_after(?GET_MORE_PEERS_TIME, PID, {get_more_peers, PID}).

ignore_peer(_PID, []) -> ok;
ignore_peer(PID, Peer) ->
	PID ! {ignore_peer, Peer}.


%%% INTERNAL FUNCTIONS

%% Main server loop.
server(S = #state { gossip = GS0, external_peers = ExtPeers }) ->
	try (receive
		% TODO: Propagate external to external nodes.
		{ignore_peer, Peer} ->
			timer:send_after(?IGNORE_PEERS_TIME, {unignore_peer, Peer}),
			server(S#state { ignored_peers = [Peer|S#state.ignored_peers] });
		{unignore_peer, Peer} ->
			server(S#state { ignored_peers = lists:delete(Peer, S#state.ignored_peers) });
		{ignore_id, ID} ->
			server(S#state {processed = [ID|S#state.processed]});
		{add_tx, TX} ->
			server(maybe_send_to_internal(S, tx, TX));
		{add_block, OriginPeer, Block, RecallBlock} ->
			% TODO: Call from HTTP iface
			case lists:member(OriginPeer, S#state.ignored_peers) of
				true -> server(S);
				false -> server(maybe_send_to_internal(S, block, {OriginPeer, Block, RecallBlock}))
			end;
		{add_peer, remote, Peer} ->
			server(S#state { external_peers = [Peer|ExtPeers]});
		{add_peer, local, Peer} ->
			server(S#state { gossip = ar_gossip:add_peers(GS0, Peer)});
		{get_peers, remote, Peer} ->
			Peer ! {remote_peers, S#state.external_peers},
			server(S);
		{update_peers, remote, Peers} ->
			server(S#state {external_peers = Peers});
		Msg when is_record(Msg, gs_msg) ->
			case ar_gossip:recv(GS0, Msg) of
				{_, ignore} ->
					server(S);
				Gossip ->
					server(do_send_to_external(S, Gossip))
			end;
		{get_more_peers, PID} ->
			spawn(
				fun() ->
					Peers = ar_manage_peers:update(S#state.external_peers),
					lists:map(fun ar_http_iface:add_peer/1, Peers),
					PID ! {update_peers, remote, Peers},
					reset_timer(PID, get_more_peers)
				end
			),
			server(S)
	end)
	catch
		throw:Term ->
			ar:report(
				[
					{'EXCEPTION', {Term}}
				]
			),
			server(S);
		exit:Term ->
			ar:report(
				[
					{'EXIT', Term}
				]
			);
		error:Term ->
			ar:report(
				[
					{'EXIT', {Term, erlang:get_stacktrace()}}
				]
			),
			server(S)
	end.
%% Potentially send a message to internal processes.
maybe_send_to_internal(
		S = #state {
			gossip = GS,
			firewall = FW,
			processed = Procd
		},
		Type,
		Data) ->
	case
		(not already_processed(Procd, Type, Data)) andalso
		ar_firewall:scan(FW, Type, Data)
	of
		false ->
			% If the data does not pass the scan, ignore the message.
			S;
		true ->
			% The message is at least valid, distribute it.
			{NewGS, _} =
				ar_gossip:send(
					GS,
					Msg = case Type of
						tx -> {add_tx, Data};
						block ->
							{OriginPeer, NewB, RecallB} = Data,
							{new_block,
								OriginPeer,
								NewB#block.height,
								NewB,
								RecallB
							}
					end),
			send_to_external(S, Msg),
			S#state {
				gossip = NewGS,
				processed = add_processed(Type, Data, Procd)
			}
	end.

%% Add the ID of a new TX/block to a processed list.
add_processed({add_tx, TX}, Procd) ->
	add_processed(tx, TX, Procd);
add_processed({new_block, _OriginPeer, _, B, _}, Procd) ->
	add_processed(block, B, Procd);
add_processed(X, Procd) ->
	ar:report(
		[
			{could_not_ignore, X},
			{record, X}
		]),
	Procd.
add_processed(tx, #tx { id = ID }, Procd) -> [ID|Procd];
add_processed(block, #block { indep_hash = Hash }, Procd) ->
	[Hash|Procd];
add_processed(block, {_, B, _}, Procd) ->
	add_processed(block, B, Procd);
add_processed(X, Y, Procd) ->
	ar:report(
		[
			{could_not_ignore, X},
			{record, Y}
		]),
	Procd.

%% Find the ID of a 'data', from type.
get_id(tx, #tx { id = ID}) -> ID;
get_id(block, B) when ?IS_BLOCK(B) -> B#block.indep_hash;
get_id(block, {_OriginPeer, #block { indep_hash = Hash}, _}) -> Hash.

%% Send an internal message externally
%% TODO: add Peer functionality in the same way that blocks do
send_to_external(S = #state {external_peers = Peers}, {add_tx, TX}) ->
	spawn(
		fun() ->
			lists:foreach(
				fun(Peer) ->
					ar_http_iface:send_new_tx(Peer, TX)
				end,
				[ IP || IP <- Peers, not already_processed(S#state.processed, tx, TX, IP) ]
			)
		end
	),
	S;
send_to_external(
		S = #state {external_peers = Peers, port = Port},
		{new_block, _Peer, _Height, NewB, RecallB}) ->
	spawn(
		fun() ->
			lists:foreach(
				fun(Peer) ->
					ar_http_iface:send_new_block(Peer, Port, NewB, RecallB)
				end,
				[ IP || IP <- Peers, not already_processed(S#state.processed, block, NewB, IP) ]
			)
		end
	),
	S;

send_to_external(S, {NewGS, Msg}) ->
	send_to_external(S#state { gossip = NewGS }, Msg).

%% Possibly send a new message to external peers.
do_send_to_external(S = #state { processed = Procd }, {NewGS, Msg}) ->
	(send_to_external(S#state { gossip = NewGS }, Msg))#state {
		processed = add_processed(Msg, Procd)
	}.

%% Check whether a message has already been seen.
already_processed(_Procd, _Type, {_, not_found, _}) ->
	true;
already_processed(_Procd, _Type, {_, unavailable, _}) ->
	true;
already_processed(Procd, Type, Data) ->
	already_processed(Procd, Type, Data, undefined).
already_processed(Procd, Type, Data, IP) ->
	lists:member(get_id(Type, Data), Procd)
	or (lists:member({get_id(Type, Data), IP}, Procd)).
