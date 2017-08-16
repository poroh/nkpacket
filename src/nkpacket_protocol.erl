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

%% @doc Protocol behaviour
%% This module shows the behaviour that NkPACKET protocols must follow
%% All functions are optional. The implementation in this module shows the
%% default behaviour

-module(nkpacket_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([transports/1, default_port/1, naptr/2]).
-export([conn_init/1, conn_parse/3, conn_encode/3, conn_encode/2, conn_bridge/4, 
		 conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).
-export([listen_init/1, listen_parse/5, listen_handle_call/4,
		 listen_handle_cast/3, listen_handle_info/3, listen_stop/3]).
-export([http_init/4]).
-export([behavior_info/1]).


%% ===================================================================
%% Behavior
%% ===================================================================


%% @doc No mandatory functions
behavior_info(callbacks) -> 
	[];
behavior_info(_) ->
    undefined.


%% ===================================================================
%% Types
%% ===================================================================


-type listen_state() :: term().
-type conn_state() :: term().



%% ===================================================================
%% Common callbacks
%% ===================================================================

%% @doc If you implement this function, it must return, for any supported scheme,
%% the list of supported transports. 
%% If you supply a tuple, it means that the first element, if used, must be 
%% converted to the second.
%% The first element will be used by default, and MUST NOT be a tuple
-spec transports(nklib:scheme()) ->
    [nkpacket:transport() | {nkpacket:transport(), nkpacket:transport()}].

transports(_) ->
	[tcp, tls, udp, sctp, ws, wss].


%% @doc If you implement this function, it will be used to find the default port
%% for this transport. If not implemented, port '0' will use any port for
%% listener transports, and will fail for outbound connections.
-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(_) ->
    invalid.


%% @doc Implement this function to allow NAPTR DNS queries.
%% When a request to resolve a URL maps to a non-IP host, with undefined
%% port and transport, NkPACKET will try a NAPTR DNS query.
%% For each response, this functions is called with the "service" part
%% of the NAPTR response, and you must extract the scheme and transport.
%% This would be an example for SIP:
%% naptr(sip, "sips+d2t") -> {ok, tls};
%% naptr(sip, "sip+d2u") -> {ok, udp};
%% naptr(sip, "sip+d2t") -> {ok, tcp};
%% naptr(sip, "sip+d2s") -> {ok, sctp};
%% naptr(sip, "sips+d2w") -> {ok, wss};
%% naptr(sip, "sip+d2w") -> {ok, ws};
%% naptr(sips, "sips+d2t") -> {ok, tls};
%% naptr(sips, "sips+d2w") -> {ok, wss};
%% naptr(_, _) -> invalid.
-spec naptr(nklib:scheme(), string()) ->
	{ok, nkpacket:transport()} | invalid.

naptr(_, _) ->
	invalid.



%% ===================================================================
%% Connection callbacks
%% ===================================================================

%% Connection callbacks, if implemented, are called during the life cicle of a
%% connection

%% @doc Called when the connection starts
-spec conn_init(nkpacket:nkport()) ->
	{ok, conn_state()} | {stop, term()}.

conn_init(_) ->
	{ok, none}.


%% @doc This function is called when a new message arrives to the connection
-spec conn_parse(nkpacket:incoming(), nkpacket:nkport(), conn_state()) ->
	{ok, conn_state()} | {reply, term(), conn_state()} | 
	{bridge, nkpacket:nkport(), conn_state()} |
	{stop, Reason::term(), conn_state()}.

conn_parse(_Msg, _NkPort, ConnState) ->
	{ok, ConnState}.


%% @doc This function is called when a new message must be send to the connection
-spec conn_encode(term(), nkpacket:nkport(), conn_state()) ->
	{ok, nkpacket:outcoming(), conn_state()} | {stop, Reason::term(), conn_state()} | { error, not_defined, conn_state() }.

conn_encode(_Term, _NkPort, ConnState) ->
	{error, not_defined, ConnState}.


%% @doc Implement this function to provide a 'quick' encode function, 
%% in case you don't need the connection state to perform the encode.
%% Return 'continue' to use the default version
-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(_Term, _NkPort) ->
	continue.


%% @doc This function is called on incoming data for bridged connections
-spec conn_bridge(nkpacket:incoming(), up|down, nkpacket:nkport(), conn_state()) ->
	{ok, nkpacket:incoming(), conn_state()} | {skip, conn_state()} | 
	{stop, term(), conn_state()}.

conn_bridge(Data, _Type, _NkPort, ConnState) ->
	{ok, Data, ConnState}.


%% @doc Called when the connection received a gen_server:call/2,3
-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkport(), conn_state()) ->
	{ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_call(_Msg, _From, _NkPort, ConnState) ->
	{stop, not_defined, ConnState}.


%% @doc Called when the connection received a gen_server:cast/2
-spec conn_handle_cast(term(), nkpacket:nkport(), conn_state()) ->
	{ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_cast(_Msg, _NkPort, ConnState) ->
	{stop, not_defined, ConnState}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), nkpacket:nkport(), conn_state()) ->
	{ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_info(_Msg, _NkPort, ConnState) ->
	{stop, not_defined, ConnState}.

%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), conn_state()) ->
	ok.

conn_stop(_Reason, _NkPort, _ConnState) ->
	ok.



%% ===================================================================
%% Listen callbacks
%% ===================================================================

%% Listen callbacks, if implemented, are called during the life cicle of a
%% listening transport

%% @doc Called when the listening transport starts
-spec listen_init(nkpacket:nkport()) ->
	{ok, listen_state()}.

listen_init(_) ->
	{ok, none}.


%% @doc This function is called only for UDP transports using no_connections=>true
-spec listen_parse(inet:ip_address(), inet:port_number(), binary(), nkpacket:nkport(), 
				   listen_state()) ->
    {ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_parse(_Ip, _Port, _Msg, _NkPort, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport received a gen_server:call/2,3
-spec listen_handle_call(term(), {pid(), term()}, nkpacket:nkport(), listen_state()) ->
	{ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_handle_call(_Msg, _From, _NkPort, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport received a gen_server:cast/2
-spec listen_handle_cast(term(), nkpacket:nkport(), listen_state()) ->
	{ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_handle_cast(_Msg, _NkPort, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport received an erlang message
-spec listen_handle_info(term(), nkpacket:nkport(), listen_state()) ->
	{ok, listen_state()} | {stop, Reason::term(), listen_state()}.

listen_handle_info(_Msg, _NkPort, ListenState) ->
	{stop, not_defined, ListenState}.


%% @doc Called when the listening transport stops
-spec listen_stop(Reason::term(), nkpacket:nkport(), listen_state()) ->
	ok.

listen_stop(_Reason, _NkPort, _State) ->
	ok.



%% ===================================================================
%% HTTP callbacks
%% ===================================================================

%% @doc This callback is called for the http/https "pseudo" transports.
%% It is used by the built-in http protocol, nkpacket_protocol_http.erl

-spec http_init(nkpacket:http_proto(), pid(), 
			    cowboy_req:req(), cowboy_middleware:env()) ->
    {ok, Req::cowboy_req:req(), Env::cowboy_middleware:env(), Middlewares::[module()]} |
    {stop, cowboy_req:req()}.
    
http_init(_HttpProto, _ConnPid, _Req, _Env) ->
	error(not_defined).

