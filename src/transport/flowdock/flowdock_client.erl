%%%-----------------------------------------------------------------------------
%%% @author 0xAX <anotherworldofworld@gmail.com>
%%% @doc
%%% Ybot flowdock chat client.
%%% @end
%%%-----------------------------------------------------------------------------
-module (flowdock_client).

-behaviour(gen_server).
 
-export([start_link/6]).
 
%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    % incoming message handler pid
    callback,
    % request id
    req_id,
    % flowdock organization
    org,
    % flow
    flow,
    % flowdock login
    login,
    % flowdock password
    password,
    % reconnect timeout in microseconds
    reconnect_timeout = 0
    }).

start_link(Callback, FlowDockOrg, Flow, Login, Password, ReconnectTimeout) ->
    gen_server:start_link(?MODULE, [Callback, FlowDockOrg, Flow, Login, Password, ReconnectTimeout], []).
 
init([Callback, FlowDockOrg, Flow, Login, Password, ReconnectTimeout]) ->
    % Start http stream
    gen_server:cast(self(), stream),
    % init state
    {ok, #state{callback = Callback, org = FlowDockOrg, flow = Flow, login = Login, password = Password, reconnect_timeout = ReconnectTimeout}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

%% @doc send message to flowdock
handle_cast({send_message, _From, Message}, State) ->
    % Make url
    Url = "https://api.flowdock.com/flows/" ++ binary_to_list(State#state.org) ++ "/" ++ binary_to_list(State#state.flow) ++ "/messages",
    % Send message
    ibrowse:send_req(Url, [{"Content-Type", "multipart/form-data"}, 
        {basic_auth, {binary_to_list(State#state.login), binary_to_list(State#state.password)}}], post, 
        ["event=message&content=" ++ Message]),
    % return
    {noreply, State};

%% @doc Start http streaming
handle_cast(stream, State) ->
    % Make url request
    Url = "https://stream.flowdock.com/flows/" ++ binary_to_list(State#state.org) ++ "/" ++ binary_to_list(State#state.flow) ++ "?active=true",
    % Send request
    {_, ReqId} = ibrowse:send_req(Url, [{"Content-Type", "application/json"}], get, [], 
        [{basic_auth, {binary_to_list(State#state.login), binary_to_list(State#state.password)}}, {stream_to, {self(), once}}], infinity),
    % save request id and return
    {noreply, State#state{req_id = ReqId}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ibrowse_async_headers, ReqId, _Status, _Headers}, State) ->
    % Next stream
    ibrowse:stream_next(ReqId),
    % return
    {noreply, State};

handle_info({ibrowse_async_response, _OldReqId, {error, req_timedout}}, State) ->
    % Make url request
    Url = "https://stream.flowdock.com/flows/" ++ binary_to_list(State#state.org) ++ "/" ++ binary_to_list(State#state.flow) ++ "?active=true",
    % Send request
    {_, ReqId} = ibrowse:send_req(Url, [{"Content-Type", "application/json"}], get, [], 
        [{basic_auth, {binary_to_list(State#state.login), binary_to_list(State#state.password)}}, {stream_to, {self(), once}}], infinity),
    % Save new request id
    {noreply, State#state{req_id = ReqId}};

%% @doc Get incoming message from flowdock chat
handle_info({ibrowse_async_response, ReqId, Data}, State) ->
    ok = ibrowse:stream_next(ReqId),
    % Parse response
    case Data of
        " " ->
            % Do nothing
            ok;
        _ ->
            % Try to decode json incoming data
            TryJsonDecode = try
                jiffy:decode(Data)
            catch _ : _ ->
                ""
            end,
            % Check data
            case TryJsonDecode of
                "" ->
                    ok;
                % this is json incoming message
                _ ->
                    % Get json
                    {Json} = TryJsonDecode,
                    case lists:member({<<"event">>, <<"message">>}, Json) of
                        true ->
                            % this is incoming message. 
                            {_, IncomingMessage} = lists:keyfind(<<"content">>, 1, Json),
                            % send it to handler
                            State#state.callback ! {incoming_message, IncomingMessage};
                        _ ->
                            % do nothing
                            pass
                    end
            end
    end,
    % return state
    {noreply, State};

handle_info({ibrowse_async_headers, ReqId, _Body}, State) ->
    ibrowse:stream_next(ReqId),
    {noreply, State};

handle_info({ibrowse_async_response_end, _ReqId}, State) ->
    {noreply, State};

%% @doc connection timeout
handle_info({error, {conn_failed, {error, _}}}, State) ->
    % try to reconnect or exit
    try_reconnect(State);

handle_info(_Info, State) ->
    {noreply, State}.
 
terminate(_Reason, _State) ->
    ok.
 
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @doc try reconnect
-spec try_reconnect(State :: #state{}) -> {normal, stop, State} | {noreply, State}.
try_reconnect(#state{reconnect_timeout = Timeout} = State) ->
    case Timeout > 0 of
        true ->
            % no need in reconnect
            {normal, stop, State};
        false ->
            % sleep
            timer:sleep(Timeout),
            % Try reconnect
            gen_server:cast(self(), stream),
            % return
            {noreply, State}
    end.