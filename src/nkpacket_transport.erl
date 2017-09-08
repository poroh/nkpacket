%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkPACKET Transport control module
-module(nkpacket_transport).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([connect/2, send/3, get_connected/1, get_connected/2]).
-export([get_listener/1, open_port/2, get_defport/2]).
-export_type([socket/0]).

-compile({no_auto_import,[get/1]}).

-include_lib("nklib/include/nklib.hrl").
-include("nkpacket.hrl").


-type socket() :: 
    port() | ssl:sslsocket() | {port(), integer()} | pid().

-define(CONN_TRIES, 100).
-define(OPEN_ITERS, 5).


%% ===================================================================
%% Public
%% ===================================================================


%% @private Finds a connected transport
-spec get_connected(nkpacket:raw_connection()) ->
    [pid()].

get_connected(Conn) ->
    get_connected(Conn, #{}).


%% @private Finds a connected transport
-spec get_connected(nkpacket:raw_connection(), map()) ->
    [pid()].

get_connected({_Proto, Transp, _Ip, _Port}, _Opts) when Transp==http; Transp==https ->
    [];

get_connected({_Proto, Transp, _Ip, _Port}=Conn, Opts) when Transp==ws; Transp==wss ->
    Host = maps:get(host, Opts, any),
    Path = maps:get(path, Opts, any),
    WsProto = maps:get(ws_proto, Opts, any),
    Class = maps:get(class, Opts, none),
    nklib_util:filtermap(
        fun({Meta, Pid}) ->
            HostOK = Host==any orelse 
                case maps:get(host, Meta, any) of
                    any -> true;
                    Host -> true;
                    _ -> false
                end,
            PathOK = Path==any orelse
                case maps:get(path, Meta, any) of
                    any -> true;
                    Path -> true;
                    _ -> false
                end,
            ProtoOK = WsProto==any orelse 
                case maps:get(ws_proto, Meta, any) of
                    any -> true;
                    WsProto -> true;
                    _ -> false
                end,
            case HostOK andalso PathOK andalso ProtoOK of
                true -> {true, Pid};
                false -> false
            end
        end,
        nklib_proc:values({nkpacket_connection, Class, Conn}));

get_connected({_, _, _, _}=Conn, Opts) ->
    Class = maps:get(class, Opts, none),
    [
        Pid || 
        {_Meta, Pid} <- nklib_proc:values({nkpacket_connection, Class, Conn})
    ].


%% @private
-spec send([nkpacket:send_spec()], term(), nkpacket:send_opts()) ->
    {ok, {pid(), term()}} | {error, term()}.

send([Uri|Rest], Msg, Opts) when is_binary(Uri); is_list(Uri) ->
    case nklib_parse:uris(Uri) of
        PUris when is_list(PUris) ->
            send([PUri || PUri <- PUris]++Rest, Msg, Opts);
        error ->
            send(Rest, Msg, Opts#{last_error=>{invalid_uri, Uri}})
    end;
     
send([#uri{}=Uri|Rest], Msg, Opts) ->
    case nkpacket:resolve(Uri, Opts) of
        {ok, RawConns, Opts1} ->
            %% lager:debug("transport send to ~p (~p)", [RawConns, Rest]),
            send(RawConns++Rest, Msg, Opts1);
        {error, Error} ->
            lager:notice("Error sending to ~p: ~p", [Uri, Error]),
            send(Rest, Msg, Opts#{last_error=>Error})
    end;

% Used when we don't want to reuse the same exact connection (stateless proxies)
send([#nkport{socket=undefined}=NkPort|Rest], Msg, Opts) ->
    {ok, Conn} = nkpacket:get_remote(NkPort),
    send([{current, Conn}|Rest], Msg, Opts);

send([Port|Rest], Msg, Opts) when is_pid(Port); is_record(Port, nkport) ->
    %% lager:debug("transport send to nkport ~p", [Port]),
    case do_send(Msg, [Port], Opts#{udp_to_tcp=>false}) of
        {ok, Res} -> {ok, Res};
        {error, Opts1} -> send(Rest, Msg, Opts1)
    end;

send([{current, {Protocol, udp, Ip, Port}}|Rest], Msg, Opts) ->
    send([{Protocol, udp, Ip, Port}|Rest], Msg, Opts);

send([{current, Conn}|Rest], Msg, Opts) ->
    Pids = get_connected(Conn, Opts),
    send(Pids++Rest, Msg, Opts);

send([{Protocol, Transp, Ip, 0}|Rest], Msg, Opts) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} ->
            send([{Protocol, Transp, Ip, Port}|Rest], Msg, Opts);
        error ->
            send(Rest, Msg, Opts#{last_error=>invalid_default_port})
    end;

send([{connect, Conn}|Rest], Msg, Opts) ->
    RemoveOpts = [udp_to_tcp, last_error],
    ConnOpts = maps:without(RemoveOpts, Opts),
    %% lager:debug("transport connecting to ~p (~p)", [Conn, ConnOpts]),
    case connect([Conn], ConnOpts) of
        {ok, Pid} ->
            case do_send(Msg, [Pid], Opts) of
                {ok, Res} ->
                    {ok, Res};
                retry_tcp ->
                    Conn1 = setelement(2, Conn, tcp), 
                    send([Conn1|Rest], Msg, Opts);
                {error, Opts1} ->
                    send(Rest, Msg, Opts1)
            end;
        {error, Error} ->
            lager:info("Error connecting to ~p: ~p", [Conn, Error]),
            send(Rest, Msg, Opts#{last_error=>Error})
    end;

send([{_, _, _, _}=Conn|Rest], Msg, #{class:=_}=Opts) ->
    Pids = case Opts of
        #{force_new:=true} -> [];
        _ -> get_connected(Conn, Opts)
    end,
    case do_send(Msg, Pids, Opts) of
        {ok, Res} -> 
            %% lager:debug("transport used previous connection to ~p (~p)", [Conn, Opts]),
            {ok, Res};
        retry_tcp ->
            Conn1 = setelement(2, Conn, tcp), 
            lager:debug("transport retrying with tcp", []),
            send([Conn1|Rest], Msg, Opts);
        {error, Opts1} -> 
            send([{connect, Conn}|Rest], Msg, Opts1)
    end;

% If we dont specify a class, do not reuse connections
send([{_, _, _, _}=Conn|Rest], Msg, Opts) ->
    send([{connect, Conn}|Rest], Msg, Opts);

send([Term|Rest], Msg, Opts) ->
    lager:warning("Invalid send specification: ~p", [Term]),
    send(Rest, Msg, Opts#{last_error=>{invalid_send_specification, Term}});

send([], _Msg, #{last_error:=Error}) -> 
    {error, Error};

send([], _, _) ->
    {error, no_transports}.


% get_allc() ->
%     [element(2, nkpacket:get_nkport(Pid)) ||
%         Pid <- nkpacket_connection:get_all()].



%% @private
-spec do_send(term(), [#nkport{}|pid()], nkpacket:send_opts()) ->
    {ok, {pid(), term()}} | retry_tcp | {error, nkpacket:send_opts()}.

do_send(_Msg, [], Opts) ->
    {error, Opts};

do_send(Msg, [Port|Rest], #{pre_send_fun:=Fun}=Opts) ->
    Msg1 = get_msg_fun(Fun, Msg, Port),
    case do_send(Msg1, [Port|Rest], maps:remove(pre_send_fun, Opts)) of
        { ok, _ } = Result ->
            Result;
        { error, Opts1 } ->
            { error, Opts1#{ pre_send_fun => Fun } }
    end;
do_send(Msg, [Port|Rest], Opts) ->
    SendOpts = case maps:find(udp_max_size, Opts) of
        {ok, MaxSize} -> #{udp_max_size=>MaxSize};
        error -> #{}
    end,
    case nkpacket_connection:send(Port, Msg, SendOpts) of
        ok when is_pid(Port) ->
            {ok, {Port, Msg}};
        ok ->
            {ok, {Port#nkport.pid, Msg}};
        {error, udp_too_large} ->
            case Opts of
                #{udp_to_tcp:=true} ->
                    retry_tcp;
                _ ->
                    lager:notice("Error sending msg: udp_too_large", []),
                    do_send(Msg, Rest, Opts#{last_error=>udp_too_large})
            end;
        {error, Error} ->
            lager:notice("Error sending msg to ~p: ~p", [Port, Error]),
            do_send(Msg, Rest, Opts#{last_error=>Error})
    end.

        
%% @private
-spec get_msg_fun(fun((#nkport{}) -> binary()), term(), #nkport{}|pid()) ->
    {ok, binary()} | {error, invalid_nkport}.

get_msg_fun(Fun, Msg, #nkport{}=NkPort) ->
    Fun(Msg, NkPort);

get_msg_fun(Fun, Msg, Pid) when is_pid(Pid) ->
    case nkpacket:get_nkport(Pid) of
        {ok, NkPort} -> get_msg_fun(Fun, Msg, NkPort);
        _ -> {error, invalid_nkport}
    end.


%% @private Starts a new outbound connection.
-spec connect([nkpacket:raw_connection()], nkpacket:connect_opts()) ->
    {ok, pid()} | {error, term()}.

connect([], _Opts) ->
    {error, no_transports};

connect([{Protocol, Transp, Ip, 0}|Rest], Opts) ->
    case get_defport(Protocol, Transp) of
        {ok, Port} -> 
            connect([{Protocol, Transp, Ip, Port}|Rest], Opts);
        error ->
            {error, invalid_default_port}
    end;

connect([Conn|Rest], Opts) ->
    Fun = fun() -> do_connect(Conn, Opts) end,
    try nklib_proc:try_call(Fun, Conn, 100, ?CONN_TRIES) of
        {ok, NkPort} ->
            {ok, NkPort};
        {error, Error} when Rest==[] ->
            {error, Error};
        {error, _} ->
            connect(Rest, Opts)
    catch
        error:max_tries ->
            connect(Rest, Opts)
    end.


%% @private Starts a new connection to a remote server
%% Tries to find an associated listening transport, 
%% to use the listening address, port and meta from it
-spec do_connect(nkpacket:raw_connection(), nkpacket:connect_opts()) ->
    {ok, pid()} | {error, term()}.
         
do_connect({Protocol, Transp, Ip, Port}, Opts) ->
    ListenOpt = maps:get(base_nkport, Opts, undefined),
    BasePort = case ListenOpt of
        false ->
            #nkport{};
        #nkport{}=ListenPort ->
            ListenPort;
        _ ->    % undefined or true
            case nkpacket:get_listening(Protocol, Transp, Opts#{ip=>Ip}) of
                [NkPort|_] -> NkPort;
                [] -> #nkport{}
            end
    end,
    #nkport{listen_ip=ListenIp, meta=Meta1} = BasePort,
    case ListenIp of
        undefined when ListenOpt ->
            {error, no_listening_transport};
        _ ->
            %% lager:debug("transport base port: ~p", [BasePort]),
            % Our listening host and meta must not be used for the new connection
            Meta2 = maps:remove(host, Meta1),
            Meta3 = maps:remove(path, Meta2),
            ConnPort = BasePort#nkport{
                class = maps:get(class, Opts, none),
                transp = Transp, 
                protocol = Protocol,
                remote_ip = Ip, 
                remote_port = Port,
                meta = maps:remove(class, maps:merge(Meta3, Opts))
            },
            % If we found a listening transport, connection will monitor it
            nkpacket_connection:connect(ConnPort)
    end.


-spec get_listener(nkpacket:nkport()) ->
    {ok, supervisor:child_spec()} | {error, term()}.

get_listener(#nkport{transp=udp}=NkPort) ->
    {ok, nkpacket_transport_udp:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==tcp; Transp==tls ->
    {ok, nkpacket_transport_tcp:get_listener(NkPort)};

get_listener(#nkport{transp=sctp}=NkPort) ->
    {ok, nkpacket_transport_sctp:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==ws; Transp==wss ->
    {ok, nkpacket_transport_ws:get_listener(NkPort)};

get_listener(#nkport{transp=Transp}=NkPort) when Transp==http; Transp==https ->
    {ok, nkpacket_transport_http:get_listener(NkPort)};

get_listener(_) ->
    {error, invalid_transport}.


%% @doc Gets the default port for a protocol
-spec get_defport(nkpacket:protocol(), nkpacket:transport()) ->
    {ok, inet:port_number()} | error.

get_defport(Protocol, Transp) ->
    case erlang:function_exported(Protocol, default_port, 1) of
        true ->
            case Protocol:default_port(Transp) of
                Port when is_integer(Port), Port > 0 -> 
                    {ok, Port};
                Other -> 
                    lager:warning("Error calling ~p:default_port(~p): ~p",
                                  [Protocol, Transp, Other]),
                    error
            end;
        false ->
            error
    end.


%% @private Tries to open a network port
%% If Port==0, it first tries the "default" port for this transport, if defined.
%% If port is in use if tries again after a while.
-spec open_port(nkpacket:nkport(), list()) ->
    {ok, port()} | {error, term()}.

open_port(NkPort, Opts) ->
    #nkport{
        transp = Transp,
        listen_ip = Ip, 
        listen_port = Port, 
        protocol = Protocol
    } = NkPort,
    {Module, Fun} = case Transp of
        udp -> {gen_udp, open};
        tcp -> {gen_tcp, listen};
        tls -> {ssl, listen};
        sctp -> {gen_sctp, open};
        ws -> {gen_tcp, listen};
        wss -> {ssl, listen};
        http -> {gen_tcp, listen};
        https -> {ssl, listen}
    end,
    DefPort = case get_defport(Protocol, Transp) of
        {ok, DefPort0} -> DefPort0;
        error -> undefined
    end,
    case Port of
        0 when is_integer(DefPort) ->
            lager:info("Opening ~p:~p (default, ~p)", [Module, DefPort, Opts]),
            case Module:Fun(DefPort, Opts) of
                {ok, Socket} ->
                    {ok, Socket};
                {error, _} ->
                    open_port(Ip, 0, Module, Fun, Opts, ?OPEN_ITERS)
            end;
        _ ->
            open_port(Ip, Port, Module, Fun, Opts, ?OPEN_ITERS)
    end.


%% @private Checks if a port is available for UDP and TCP
-spec open_port(inet:ip_address(), inet:port_number(),
                module(), atom(), list(), pos_integer()) ->
    {ok, port()} | {error, term()}.

open_port(Ip, Port, Module, Fun, Opts, Iter) ->
    lager:info("Opening ~p:~p (~p)", [Module, Port, Opts]),
    case Module:Fun(Port, Opts) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} when Iter > 0 ->
            lager:info("~p port ~p is in use, waiting (~p)", 
                         [Module, Port, Iter]),
            timer:sleep(1000),
            open_port(Ip, Port, Module, Fun, Opts, Iter-1);
        {error, Error} ->
            {error, Error}
    end.






