%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(merge_index_backend).
-behavior(riak_search_backend).

-export([
    start/2,
    stop/1,
    index/2,
    delete/2,
    stream/6,
    info/5,
    fold/3,
    is_empty/1,
    drop/1
]).

-import(riak_search_utils, [to_binary/1]).
-include_lib("riak_search/include/riak_search.hrl").

% @type state() = term().
-record(state, {partition, pid}).

%% @spec start(Partition :: integer(), Config :: proplist()) ->
%%          {ok, state()} | {{error, Reason :: term()}, state()}
%% @doc Start this backend.
start(Partition, _Config) ->
    PartitionStr = lists:flatten(io_lib:format("~p", [Partition])),
    {ok, Root} = application:get_env(merge_index, data_root),
    PartitionRoot = filename:join([Root, PartitionStr]),
    {ok, Pid} = merge_index:start_link(PartitionRoot),
    {ok, #state { partition=Partition, pid=Pid }}.

%% @spec stop(state()) -> ok | {error, Reason :: term()}
stop(State) ->
    Pid = State#state.pid,
    ok = merge_index:stop(Pid).

index(IFTVPKList, State) ->
    Pid = State#state.pid,
    merge_index:index(Pid, IFTVPKList),
    %% F = fun(IFTVPK) ->
    %%             {Index, Field, Term, DocId, Props, KeyClock} = IFTVPK,
    %%             merge_index:index(Pid, Index, Field, Term, DocId, Props, KeyClock)
    %% end,
    %% [F(X) || X <- IFTVPKList],
    {reply, {indexed, node()}, State}.

delete(IFTVKList, State) ->
    Pid = State#state.pid,
    IFTVKList1 = [{I,F,T,V,undefined,K} || {I,F,T,V,K} <- IFTVKList],
    merge_index:index(Pid, IFTVKList1),
    {reply, {deleted, node()}, State}.

info(Index, Field, Term, Sender, State) ->
    Pid = State#state.pid,
    {ok, Info} = merge_index:info(Pid, to_binary(Index), to_binary(Field), to_binary(Term)),
    Info1 = [{Term, node(), Count} || {_, Count} <- Info],
    riak_search_backend:info_response(Sender, Info1),
    noreply.

stream(Index, Field, Term, FilterFun, Sender, State) ->
    Pid = State#state.pid,
    OutputRef = make_ref(),
    OutputPid = spawn_link(fun() -> stream_loop(OutputRef, Sender) end),
    merge_index:stream(Pid, to_binary(Index), to_binary(Field), to_binary(Term), OutputPid, OutputRef, FilterFun),
    noreply.

stream_loop(Ref, Sender) ->
    receive
        {result, {DocID, Props}, Ref} ->
            riak_search_backend:stream_response_results(Sender, [{DocID, Props}]),
            stream_loop(Ref, Sender);
        {result_vec, ResultVec, Ref} ->
            riak_search_backend:stream_response_results(Sender, ResultVec),
            stream_loop(Ref, Sender);
        {result, '$end_of_table', Ref} ->
            riak_search_backend:stream_response_done(Sender);
        Other ->
            ?PRINT({unexpected_result, Other}),
            stream_loop(Ref, Sender)
    end.

is_empty(State) ->
    Pid = State#state.pid,
    merge_index:is_empty(Pid).

fold(FoldFun, Acc, State) ->
    %% Copied almost verbatim from riak_search_ets_backend.
    Fun = fun
        (I,F,T,V,P,K, {OuterAcc, {{I,{F,T}},InnerAcc}}) ->
            %% same IFT, just accumulate doc/props/clock
            {OuterAcc, {{I,{F,T}},[{V,P,K}|InnerAcc]}};
        (I,F,T,V,P,K, {OuterAcc, {FoldKey, VPKList}}) ->
            %% finished a string of IFT, send it off
            %% (sorted order is assumed)
            NewOuterAcc = FoldFun(FoldKey, VPKList, OuterAcc),
            {NewOuterAcc, {{I,{F,T}},[{V,P,K}]}};
        (I,F,T,V,P,K, {OuterAcc, undefined}) ->
            %% first round through the fold - just start building
            {OuterAcc, {{I,{F,T}},[{V,P,K}]}}
        end,
    Pid = State#state.pid,
    {ok, {OuterAcc0, Final}} = merge_index:fold(Pid, Fun, {Acc, undefined}),
    OuterAcc = case Final of
        {FoldKey, VPKList} ->
            %% one last IFT to send off
            FoldFun(FoldKey, VPKList, OuterAcc0);
        undefined ->
            %% this partition was empty
            OuterAcc0
    end,
    {reply, OuterAcc, State}.

drop(State) ->
    Pid = State#state.pid,
    merge_index:drop(Pid).
