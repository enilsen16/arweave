-module(ar_tx).
-export([new/0, new/1, new/2, new/3, new/4, sign/2, sign/3, to_binary/1, verify/3, verify_txs/3]).
-export([calculate_min_tx_cost/2, tx_cost_above_min/2, check_last_tx/2]).
-export([tags_to_binary/1]).
-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% Transaction creation, signing and verification for Archain.

%% @doc Generate a new transaction for entry onto a weave.
new() ->
	#tx { id = generate_id() }.
new(Data) ->
	#tx { id = generate_id(), data = Data }.
new(Data, Reward) ->
	#tx { id = generate_id(), data = Data, reward = Reward }.
new(Data, Reward, Last) ->
	#tx { id = generate_id(), last_tx = Last, data = Data, reward = Reward }.
new(Dest, Reward, Qty, Last) when bit_size(Dest) == ?HASH_SZ ->
	#tx {
		id = generate_id(),
		last_tx = Last,
		quantity = Qty,
		target = Dest,
		data = <<>>,
		reward = Reward
	};
new(Dest, Reward, Qty, Last) ->
	% Convert wallets to addresses before building transactions.
	new(ar_wallet:to_address(Dest), Reward, Qty, Last).

%% @doc Create an ID for an object on the weave.
generate_id() -> crypto:strong_rand_bytes(32).

%% @doc Generate a hashable binary from a #tx object.
to_binary(T) ->
	<<
		(T#tx.owner)/binary,
		(T#tx.target)/binary,
		(T#tx.data)/binary,
		(list_to_binary(integer_to_list(T#tx.quantity)))/binary,
		(list_to_binary(integer_to_list(T#tx.reward)))/binary,
		(T#tx.last_tx)/binary
	>>.

%% @doc Sign ('claim ownership') of a transaction. After it is signed, it can be
%% placed onto a block and verified at a later date.
sign(TX, {PrivKey, PubKey}) -> sign(TX, PrivKey, PubKey).
sign(TX, PrivKey, PubKey) ->
	NewTX = TX#tx{ owner = PubKey },
	Sig = ar_wallet:sign(PrivKey, to_binary(NewTX)),
	ar:d(Sig),
	ID = crypto:hash(?HASH_ALG, <<Sig/binary>>),
	NewTX#tx {
		signature = Sig, id = ID
	}.

%% @doc Ensure that a transaction's signature is valid.
%% TODO: Ensure that DEBUG is false in production releases(!!!)
-ifdef(DEBUG).
verify(#tx { signature = <<>> }, _, _) -> true;
verify(TX, Diff, WalletList) ->
	ar:report(
		[
			{validate_tx, ar_util:encode(TX#tx.id)},
			{tx_wallet_verify, ar_wallet:verify(TX#tx.owner, to_binary(TX), TX#tx.signature)},
			{tx_above_min_cost, tx_cost_above_min(TX, Diff)},
			{tx_field_size_verify, tx_field_size_limit(TX)},
			{tx_tag_field_legal, tag_field_legal(TX)},
			{tx_last_tx_legal, check_last_tx(WalletList, TX)},
			{tx_verify_hash, tx_verify_hash(TX)}
		]
	),
	ar_wallet:verify(TX#tx.owner, to_binary(TX), TX#tx.signature) and
	tx_cost_above_min(TX, Diff) and
	tx_field_size_limit(TX) and
	tag_field_legal(TX) and
	check_last_tx(WalletList, TX) and
	tx_verify_hash(TX).
-else.
verify(TX, Diff, WalletList) ->
	ar:report(
		[
			{validate_tx, ar_util:encode(ar_wallet:to_address(TX#tx.owner))},
			{tx_wallet_verify, ar_wallet:verify(TX#tx.owner, to_binary(TX), TX#tx.signature)},
			{tx_above_min_cost, tx_cost_above_min(TX, Diff)},
			{tx_field_size_verify, tx_field_size_limit(TX)},
			{tx_tag_field_legal, tag_field_legal(TX)},
			{tx_lasttx_legal, check_last_tx(WalletList, TX)},
			{tx_verify_hash, tx_verify_hash(TX)}
		]
	),
	ar_wallet:verify(TX#tx.owner, to_binary(TX), TX#tx.signature) and
	tx_cost_above_min(TX, Diff) and
	tx_field_size_limit(TX) and
	tag_field_legal(TX) and
	check_last_tx(WalletList, TX) and
	tx_verify_hash(TX).
-endif.

%% @doc Ensure that all TXs in a list verify correctly.
verify_txs([], _, _) ->
	true;
verify_txs(TXs, Diff, WalletList) ->
	do_verify_txs(TXs, Diff, WalletList).
do_verify_txs([], _, _) ->
	true;
do_verify_txs([T|TXs], Diff, WalletList) ->
	case verify(T, Diff, WalletList) of
		true -> do_verify_txs(TXs, Diff, ar_node:apply_tx(WalletList, T));
		false -> false
	end.

%% @doc Transaction cost above proscribed minimum.
tx_cost_above_min(TX, Diff) ->
	TX#tx.reward >= calculate_min_tx_cost(byte_size(TX#tx.data), Diff).

%Calculate the minimum transaction cost for a TX with data size Size
%the constant 3208 is the max byte size of each of the other fields
%Cost per byte is static unless size is bigger than 10mb, at which
%point cost per byte starts increasing linearly.
calculate_min_tx_cost(Size, Diff) when Size < 10*1024*1024 ->
	((Size+3208) * ?COST_PER_BYTE * ?DIFF_CENTER) div Diff;
calculate_min_tx_cost(Size, Diff) ->
	(Size*(Size+3208) * ?COST_PER_BYTE * ?DIFF_CENTER) div (Diff*10*1024*1024).

tx_field_size_limit(TX) ->
	case tag_field_legal(TX) of
		true ->
			(byte_size(TX#tx.id) =< 32) and
			(byte_size(TX#tx.last_tx) =< 32) and
			(byte_size(TX#tx.owner) =< 512) and
			(byte_size(list_to_binary(TX#tx.tags)) =< 2048) and
			(byte_size(TX#tx.target) =< 32) and
			(byte_size(integer_to_binary(TX#tx.quantity)) =< 21) and
			(byte_size(TX#tx.signature) =< 512) and
			(byte_size(integer_to_binary(TX#tx.reward)) =< 21);
		false -> false
	end.

tx_verify_hash(#tx {signature = Sig, id = ID}) ->
	ID == crypto:hash(
		?HASH_ALG,
		<<Sig/binary>>
	).

tag_field_legal(TX) ->
	lists:all(
		fun(X) ->
			case X of
				{_, _} -> true;
				_ -> false
			end
		end,
		TX#tx.tags
	).

tags_to_binary(Tags) ->
	list_to_binary(
		lists:foldr(
			fun({Name, Value}, Acc) ->
				[Name, Value | Acc]
			end,
			[],
			Tags
		)
	).

-ifdef(DEBUG).
check_last_tx([], _) ->
	true;
check_last_tx(_WalletList, TX) when TX#tx.owner == <<>> -> true;
check_last_tx(WalletList, TX) ->
	Address = ar_wallet:to_address(TX#tx.owner),
	case lists:keyfind(Address, 1, WalletList) of
		{Address, _Quantity, Last} ->
			Last == TX#tx.last_tx;
		_ -> false
	end.
-else.
check_last_tx([], _) ->
	true;
check_last_tx(WalletList, TX) ->
	Address = ar_wallet:to_address(TX#tx.owner),
	case lists:keyfind(Address, 1, WalletList) of
		{Address, _Quantity, Last} -> Last == TX#tx.last_tx;
		_ -> false
	end.
-endif.
% check_last_tx(WalletList, TX) ->
% 	ar:d({walletlist, WalletList}),
% 	ar:d({tx, TX#tx.last_tx, ar_util:encode(TX#tx.last_tx)}),
% 	ar:d(lists:keymember(
% 		TX#tx.last_tx,
% 		3,
% 		WalletList
% 	)),
% 	lists:keymember(
% 		TX#tx.last_tx,
% 		3,
% 		WalletList
% 	).


%%% Tests
%% TODO: Write a more stringent reject_tx_below_min test

sign_tx_test() ->
	NewTX = new(<<"TEST DATA">>, ?AR(10)),
	{Priv, Pub} = ar_wallet:new(),
	true = verify(sign(NewTX, Priv, Pub), 1, []).

forge_test() ->
	NewTX = new(<<"TEST DATA">>, ?AR(10)),
	{Priv, Pub} = ar_wallet:new(),
	false = verify((sign(NewTX, Priv, Pub))#tx { data = <<"FAKE DATA">> }, 1, []).

tx_cost_above_min_test() ->
	TestTX = new(<<"TEST DATA">>, ?AR(10)),
	true = tx_cost_above_min(TestTX, 1).

reject_tx_below_min_test() ->
	TestTX = new(<<"TEST DATA">>, 1),
	false = tx_cost_above_min(TestTX, 10).

check_last_tx_test() ->
	ar_storage:clear(),
	{Priv1, Pub1} = ar_wallet:new(),
	{_Priv2, Pub2} = ar_wallet:new(),
	{_Priv3, Pub3} = ar_wallet:new(),
	TX = ar_tx:new(Pub2, ?AR(1), ?AR(500), <<>>),
	TX2 = ar_tx:new(Pub3, ?AR(1), ?AR(400), TX#tx.id),
	% SignedTX = ar_tx:sign(TX, Priv1, Pub1),
	% SignedTX2 = ar_tx:sign(TX2, Priv1, Pub1),
	WalletList =
		[
			{ar_wallet:to_address(Pub1), 1000, <<>>},
			{ar_wallet:to_address(Pub2), 2000, TX#tx.id},
			{ar_wallet:to_address(Pub3), 3000, <<>>}
		],
	check_last_tx(WalletList, TX2).
