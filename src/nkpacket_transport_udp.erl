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

%% @private UDP Transport Module.
-module(nkpacket_transport_udp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([send_stun_sync/4, send_stun_async/3]).
-export([get_listener/1, connect/1, send/4]).
-export([start_link/1, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
             handle_info/2]).

-include("nkpacket.hrl").

-define(RECV_BURST, 100).


%% ===================================================================
%% Public
%% ===================================================================


%% @private Sends a STUN binding request
%% It does not open a new NkPACKET's UDP connection
send_stun_sync(Pid, Ip, Port, Timeout) ->
    case catch gen_server:call(Pid, {nkpacket_send_stun, Ip, Port}, Timeout) of
        {ok, StunIp, StunPort} -> 
            {ok, StunIp, StunPort};
        error -> 
            error
    end.


%% @private Sends a STUN binding request, the response will be sent to the calling 
%% process as {stun, {ok, Ip, Port}|error}.
send_stun_async(Pid, Ip, Port) ->
    gen_server:cast(Pid, {nkpacket_send_stun, Ip, Port, self()}).


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkpacket:nkport()) ->
    supervisor:child_spec().

get_listener(#nkport{listen_ip=Ip, listen_port=Port, transp=udp}=NkPort) ->
    {
        {{udp, Ip, Port}, make_ref()},
        {?MODULE, start_link, [NkPort]},
        transient, 
        5000, 
        worker, 
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkpacket:nkport()) ->
    {ok, pid()} | {error, term()}.
         
connect(#nkport{transp=udp, pid=Pid}=NkPort) ->
    case catch gen_server:call(Pid, {nkpacket_connect, NkPort}, 180000) of
        {ok, ConnPid} -> 
            {ok, ConnPid};
        {error, Error} ->
            {error, Error};
        {'EXIT', Error} -> 
            {error, Error}
    end.


%% @private Function to send data if connections are not started 
-spec send(nkpacket:nkport()|pid(), inet:ip_address(), inet:port_number(), 
           binary()|iolist()) ->
    ok | {error, term()}.

send(#nkport{transp=udp, socket=Socket}, Ip, Port, Data) ->
    gen_udp:send(Socket, Ip, Port, Data);

send(Pid, Ip, Port, Data) when is_pid(Pid) ->
    case catch gen_server:call(Pid, nkpacket_get_socket, 180000) of
        {ok, Socket} -> 
            send(Socket, Ip, Port, Data);
        _ -> 
            {error, unknown_process}
    end.





%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(NkPort) -> 
    gen_server:start_link(?MODULE, [NkPort], []).


-record(stun, {
    id :: binary(),
    dest :: {inet:ip_address(), inet:port_number()},
    packet :: binary(),
    retrans_timer :: reference(),
    next_retrans :: integer(),
    from :: {call, {pid(), term()}} | {msg, pid()}
}).

-record(state, {
    nkport :: nkpacket:nkport(),
    socket :: port(),
    tcp_pid :: pid() | undefined,
    no_connections :: boolean(),
    reply_stun :: boolean(),
    stuns :: [#stun{}],
    timer_t1 :: integer(),
    protocol :: nkpacket:protocol(),
    proto_state :: term(),
    monitor_ref :: reference()
}).


%% @private 
-spec init(term()) ->
    {ok, #state{}} | {stop, term()}.

init([NkPort]) ->
    #nkport{
        class = Class,
        protocol = Protocol, 
        transp = udp,
        listen_ip = ListenIp, 
        listen_port = ListenPort,
        meta = Meta
    } = NkPort,
    process_flag(priority, high),
    process_flag(trap_exit, true),   %% Allow calls to terminate/2
    try
        % ListenOpts = [binary, {reuseaddr, true}, {ip, ListenIp}, {active, once}],
        ListenOpts = [binary, {ip, ListenIp}, {active, once}],
        Socket = case nkpacket_transport:open_port(NkPort, ListenOpts) of
            {ok, Socket0}  -> Socket0;
            {error, Error} -> throw(Error) 
        end,
        {ok, {LocalIp, LocalPort}} = inet:sockname(Socket),
        Self = self(),
        NkPort1 = NkPort#nkport{
            local_ip = LocalIp,
            local_port = LocalPort, 
            listen_port = LocalPort,
            pid = self(),
            socket = Socket
        },
        TcpPid = case Meta of
            #{udp_starts_tcp:=true} -> 
                TcpNkPort = NkPort1#nkport{transp=tcp},
                case nkpacket_transport_tcp:start_link(TcpNkPort) of
                    {ok, TcpPid0} -> 
                        TcpPid0;
                    {error, TcpError} -> 
                        lager:warning("UDP transport could not open TCP port ~p: ~p",
                                      [LocalPort, TcpError]),
                        throw(could_not_open_tcp)
                end;
            _ ->
                undefined
        end,
        Id = binary_to_atom(nklib_util:hash({udp, LocalIp, LocalPort}), latin1),
        true = register(Id, self()),
        nklib_proc:put(nkpacket_listeners, {Id, Class}),
        ConnMeta = maps:with(?CONN_LISTEN_OPTS, Meta),
        ConnPort = NkPort1#nkport{meta=ConnMeta},
        ListenType = case size(ListenIp) of
            4 -> nkpacket_listen4;
            8 -> nkpacket_listen6
        end,
        nklib_proc:put({ListenType, Class, Protocol, udp}, ConnPort),
        {ok, ProtoState} = nkpacket_util:init_protocol(Protocol, listen_init, NkPort1),
        MonRef = case Meta of
            #{monitor:=UserRef} -> erlang:monitor(process, UserRef);
            _ -> undefined
        end,        
        State = #state{
            nkport = ConnPort,
            socket = Socket,
            tcp_pid = TcpPid,
            no_connections = maps:get(udp_no_connections, Meta, false),
            reply_stun = maps:get(udp_stun_reply, Meta, false),
            stuns = [],
            timer_t1 = maps:get(udp_stun_t1, Meta, 500),
            protocol = Protocol,
            proto_state = ProtoState,
            monitor_ref = MonRef
        },
        {ok, State}
    catch
        throw:Throw ->
            lager:error("could not start UDP transport on ~p:~p (~p)", 
                        [ListenIp, ListenPort, Throw]),
            {stop, Throw}
    end.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}} | 
    {stop, term(), #state{}} | {stop, term(), term(), #state{}}.

handle_call({nkpacket_connect, ConnPort}, _From, State) ->
    #nkport{
        remote_ip = Ip,
        remote_port = Port, 
        meta = Meta
    } = ConnPort,
    {reply, do_connect(Ip, Port, Meta, State), State};

handle_call({nkpacket_send_stun, Ip, Port}, From, State) ->
    {noreply, do_send_stun(Ip, Port, {call, From}, State)};

handle_call({nkpacket_apply_nkport, Fun}, _From, #state{nkport=NkPort}=State) ->
    {reply, Fun(NkPort), State};

handle_call(nkpacket_get_socket, _From, #state{socket=Socket}=State) ->
    {reply, {ok, Socket}, State};

handle_call(nkpacket_stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(Msg, From, #state{nkport=NkPort}=State) ->
    case call_protocol(listen_handle_call, [Msg, From, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_cast({nkpacket_send_stun, Ip, Port, Pid}, State) ->
    {noreply, do_send_stun(Ip, Port, {msg, Pid}, State)};

handle_cast(nkpacket_stop, State) ->
    {stop, normal, State};

handle_cast(Msg, #state{nkport=NkPort}=State) ->
    case call_protocol(listen_handle_cast, [Msg, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

handle_info({udp, Socket, Ip, Port, <<0:2, _Header:158, _Msg/binary>>=Packet}, State) ->
    #state{stuns=Stuns, reply_stun=StunReply, socket=Socket} = State,
    case nkpacket_stun:decode(Packet) of
        {request, binding, TransId, _} when StunReply ->
            Response = nkpacket_stun:binding_response(TransId, Ip, Port),
            gen_udp:send(Socket, Ip, Port, Response),
            lager:debug("sent STUN bind response to ~p:~p", [Ip, Port]),
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State};
        {response, binding, TransId, Attrs} when Stuns/=[] ->
            State1 = do_stun_response(TransId, Attrs, State),
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State1};
        _ ->
            case read_packets(Ip, Port, Packet, State, ?RECV_BURST) of
                {ok, State1} ->
                    ok = inet:setopts(Socket, [{active, once}]),
                    {noreply, State1};
                {stop, Reason, State1} ->
                    {stop, Reason, State1}
            end
    end;

handle_info({udp, Socket, Ip, Port, Packet}, #state{socket=Socket}=State) ->
    case read_packets(Ip, Port, Packet, State, ?RECV_BURST) of
        {ok, State1} ->
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State1};
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

handle_info({timeout, Ref, stun_retrans}, #state{stuns=Stuns}=State) ->
    {value, Stun1, Stuns1} = lists:keytake(Ref, #stun.retrans_timer, Stuns),
    {noreply, do_stun_retrans(Stun1, State#state{stuns=Stuns1})};
   
handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{monitor_ref=MRef}=State) ->
    {stop, normal, State};

handle_info({'EXIT', Pid, _Error}, #state{tcp_pid=Pid}=State) ->
    {stop, {error, tcp_error}, State};

handle_info({'EXIT', _Pid, normal}, State) ->
    %% Connection stops go here
    {noreply, State};

handle_info(killme, _State) ->
    error(killme);

handle_info(Msg, #state{nkport=NkPort}=State) ->
    case call_protocol(listen_handle_info, [Msg, NkPort], State) of
        undefined -> {noreply, State};
        {ok, State1} -> {noreply, State1};
        {stop, Reason, State1} -> {stop, Reason, State1}
    end.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(Reason, State) ->  
    #state{nkport=NkPort, tcp_pid=Pid} = State,
    case is_pid(Pid) of
        true ->
            exit(Pid, shutdown);
        false ->
            ok
    end,
    catch call_protocol(listen_stop, [Reason, NkPort], State).



%% ========= STUN processing ================================================

%% @private
do_send_stun(Ip, Port, From, State) ->
    #state{timer_t1=T1, stuns=Stuns, socket=Socket} = State,
    {Id, Packet} = nkpacket_stun:binding_request(),
    case gen_udp:send(Socket, Ip, Port, Packet) of
        ok -> 
            lager:debug("sent STUN request to ~p", [{Ip, Port}]),
            Stun = #stun{
                id = Id,
                dest = {Ip, Port},
                packet = Packet,
                retrans_timer = erlang:start_timer(T1, self(), stun_retrans),
                next_retrans = 2*T1,
                from = From
            },
            State#state{stuns=[Stun|Stuns]};
        {error, Error} ->
            lager:notice("could not send UDP STUN request to ~p:~p: ~p", 
                         [Ip, Port, Error]),
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, error);
                {msg, MsgPid} -> MsgPid ! {stun, error}
            end,
            State
    end.


%% @private
do_stun_retrans(Stun, State) ->
    #stun{dest={Ip, Port}, packet=Packet, next_retrans=Next} = Stun,
    #state{stuns=Stuns, timer_t1=T1, socket=Socket} = State,
    case Next =< (16*T1) of
        true ->
            case gen_udp:send(Socket, Ip, Port, Packet) of
                ok -> 
                    lager:warning("sent STUN refresh", []),
                    Stun1 = Stun#stun{
                        retrans_timer = erlang:start_timer(Next, self(), stun_retrans),
                        next_retrans = 2*Next
                    },
                    State#state{stuns=[Stun1|Stuns]};
                {error, Error} ->
                    lager:notice("could not send UDP STUN request to ~p:~p: ~p", 
                                 [Ip, Port, Error]),
                    do_stun_timeout(Stun, State)
            end;
        false ->
            do_stun_timeout(Stun, State)
    end.


%% @private
do_stun_timeout(Stun, State) ->
    #stun{dest={Ip, Port}, from=From} = Stun,
    lager:notice("STUN request to ~p timeout", [{Ip, Port}]),
    case From of
        {call, CallFrom} -> gen_server:reply(CallFrom, error);
        {msg, MsgPid} -> MsgPid ! {stun, error}
    end,
    State.
        

%% @private
do_stun_response(TransId, Attrs, State) ->
    #state{stuns=Stuns} = State,
    case lists:keytake(TransId, #stun.id, Stuns) of
        {value, #stun{retrans_timer=Retrans, from=From}, Stuns1} ->
            nklib_util:cancel_timer(Retrans),
            case nklib_util:get_value(xor_mapped_address, Attrs) of
                {StunIp, StunPort} -> 
                    ok;
                _ ->
                    case nklib_util:get_value(mapped_address, Attrs) of
                        {StunIp, StunPort} -> ok;
                        _ -> StunIp = StunPort = undefined
                    end
            end,
            Msg = {ok, StunIp, StunPort},
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, Msg);
                {msg, MsgPid} -> MsgPid ! {stun, Msg}
            end,
            State#state{stuns=Stuns1};
        false ->
            lager:notice("received unexpected STUN response", []),
            State
    end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private 
read_packets(Ip, Port, Packet, #state{no_connections=true, nkport=NkPort}=State, N) ->
    #state{socket=Socket} = State,
    case call_protocol(listen_parse, [Ip, Port, Packet, NkPort], State) of
        undefined -> 
            lager:warning("Received data for uknown protocol", []),
            {ok, State};
        {ok, State1} ->
            case N>0 andalso gen_udp:recv(Socket, 0, 0) of
                {ok, {Ip1, Port1, Packet1}} -> 
                    read_packets(Ip1, Port1, Packet1, State1, N-1);
                _ ->
                    {ok, State1}
            end;
        {stop, Reason, State1} ->
            {stop, Reason, State1}
    end;

read_packets(Ip, Port, Packet, #state{socket=Socket}=State, N) ->
    case do_connect(Ip, Port, State) of
        {ok, Pid} ->
            nkpacket_connection:incoming(Pid, Packet),
            case N>0 andalso gen_udp:recv(Socket, 0, 0) of
                {ok, {Ip1, Port1, Packet1}} -> 
                    read_packets(Ip1, Port1, Packet1, State, N-1);
                _ ->
                    {ok, State}
            end;
        {error, _} ->
            {ok, State}
    end.


%% @private
do_connect(Ip, Port, State) ->
    do_connect(Ip, Port, undefined, State).


%% @private
do_connect(Ip, Port, Meta, #state{nkport=NkPort}) ->
    #nkport{class=Class, protocol=Proto, meta=ListenMeta} = NkPort,
    Conn = {Proto, udp, Ip, Port},
    case nkpacket_transport:get_connected(Conn, #{class=>Class}) of
        [Pid|_] -> 
            {ok, Pid};
        [] ->
            Meta1 = case Meta of
                undefined -> ListenMeta;
                _ -> maps:merge(ListenMeta, Meta)
            end,
            NkPort1 = NkPort#nkport{
                remote_ip = Ip, 
                remote_port = Port,
                meta = Meta1
            },
            % Connection will monitor us using nkport's pid
            nkpacket_connection:start(NkPort1)
    end.


%% @private
call_protocol(Fun, Args, State) ->
    nkpacket_util:call_protocol(Fun, Args, State, #state.protocol).


