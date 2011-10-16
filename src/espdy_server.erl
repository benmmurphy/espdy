-module(espdy_server).
-compile([{parse_transform, lager_transform}]).
-behaviour(gen_server).

-include("espdy_frame.hrl").
-include("espdy_server.hrl").

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3, socket_writer/1, graceful_close/1]).


-export([accept/1, 
         connect/1,
         connect/3,
         connect_for_push/3,
         send_headers/2, 
         send/2, 
         close/1, 
         send_and_close/2, 
         recv/3, recv/2, 
         statistics/1, 
         stream_id/1]).

% TESTING API ONLY. NOT SAFE TO USE
-export([async_accept/1, async_send_headers/2, async_send/2, async_close/1, async_send_and_close/2, 
        async_recv/3, async_recv/2]).

make_socket(Pid, StreamId) ->
    #espdy_socket{pid = Pid, stream_id = StreamId}.
    
accept(Pid) ->
    case send_call(Pid, accept) of
        {ok, StreamId, Headers} -> {ok, make_socket(Pid, StreamId), Headers};
        Error -> Error
    end.

connect(Pid) ->
    connect(Pid, false, []).
    
connect_for_push(#espdy_socket{pid = Pid, stream_id = StreamId}, SendFin, Headers) ->
    connect(Pid, SendFin, Headers, StreamId).
    
connect(Pid, SendFin, Headers) ->
    connect(Pid, SendFin, Headers, 0).
    
connect(Pid, SendFin, Headers, AssociatedStreamId) ->
    case send_call(Pid, {connect, Headers, SendFin, AssociatedStreamId}) of
        {ok, StreamId} -> {ok, make_socket(Pid, StreamId)};
        Error -> Error
    end.
    
graceful_close(Pid) ->
    gen_server:cast(Pid, graceful_close).
    
send_headers(#espdy_socket{pid = Pid, stream_id = StreamId}, Headers) ->
    send_call(Pid, {send_headers, StreamId, Headers}).
    
send(#espdy_socket{pid = Pid, stream_id = StreamId}, Data) ->
    send_call(Pid, {send, StreamId, Data}).
    
send_and_close(#espdy_socket{pid = Pid, stream_id = StreamId}, Data) ->
    send_call(Pid, {send_and_close, StreamId, Data}).
    
close(#espdy_socket{pid = Pid, stream_id = StreamId}) ->
    send_call(Pid, {close, StreamId}).

recv(#espdy_socket{pid = Pid, stream_id = StreamId}, Length, Timeout) ->
    send_call(Pid, {recv, StreamId, Length, Timeout}).


    
recv(Socket, Length) ->
    recv(Socket, Length, infinity).
    
statistics(Pid) ->
    send_call(Pid, statistics).
    
stream_id(#espdy_socket{stream_id = StreamId}) ->
    StreamId.
    
async_accept(Pid) ->
    send_async(Pid, accept).
    
async_send(#espdy_socket{pid = Pid, stream_id = StreamId}, Data) ->
    send_async(Pid, {send, StreamId, Data}).

async_recv(#espdy_socket{pid = Pid, stream_id = StreamId}, Length, Timeout) ->
    send_async(Pid, {recv, StreamId, Length, Timeout}).

async_recv(Socket, Length) ->
    async_recv(Socket, Length, infinity).
        
async_send_headers(#espdy_socket{pid = Pid, stream_id = StreamId}, Headers) ->
    send_async(Pid, {send_headers, StreamId, Headers}).

async_close(#espdy_socket{pid = Pid, stream_id = StreamId}) ->
    send_async(Pid, {close, StreamId}).
    
async_send_and_close(#espdy_socket{pid = Pid, stream_id = StreamId}, Data) ->
    send_async(Pid, {send_and_close, StreamId, Data}).
    
send_async(Pid, Msg) ->
    Ref = make_ref(),
    Pid ! {'$gen_call', {self(), Ref}, Msg},
    Ref.

send_call(Pid, Request) ->
    try
        gen_server:call(Pid, Request, infinity)
    catch
    % not sure if this is too broad...
    exit:_ ->
        {error, closed}
    end.
    
-record(state, {
    last_stream_accepted = 0,
    next_syn_stream_id,
    closing = false,
    other_side_closing = false,
    data_tag,
    close_tag,
    role, 
    socket, 
    socket_writer = undefined,
    zlib_read_nv_context = undefined,
    zlib_write_nv_context = undefined, 
    read_buffer = <<>>, 
    streams = dict:new(),
    accept_buffer = [],
    waiting_acceptors = []}).
    
-record(stream, {

    read_open = true,
    write_closing = false, 
    write_open = true,
    read_buffer = <<>>, 
    recv_waiters = [], 
    send_waiters = [],
    send_header_waiters = [],
    syn_reply_sent = false}).

stream_to_proplist(#stream{} = Rec) ->
  lists:zip(record_info(fields, stream), tl(tuple_to_list(Rec))).

debug_streams(#state{streams = Streams}) ->
    lists:map(fun({N, S}) -> {N, stream_to_proplist(S) } end, dict:to_list(Streams)).
    
start_link(Socket, Role) ->
    case gen_server:start_link(espdy_server, [Socket, Role], []) of
        {ok, Pid} = Result -> 
            ok = Socket:controlling_process(Pid),
            ok = gen_server:call(Pid, start),
            Result;
        Error -> Error
    end.
   
initial_stream_id(server) ->
    2;
initial_stream_id(client) ->
    1.
     
init([Socket, Role]) ->
    {ok, #state{
        next_syn_stream_id = initial_stream_id(Role),
        data_tag = Socket:data_tag(),
        close_tag = Socket:close_tag(),
        socket = Socket, 
        socket_writer = spawn_link(?MODULE, socket_writer, [Socket]), 
        role = Role,
        zlib_read_nv_context = espdy_frame:initialize_zlib_for_inflate(),
        zlib_write_nv_context = espdy_frame:initialize_zlib_for_deflate()
    }}.

socket_writer(Socket) ->
    receive
        {send, Data, Callback} ->
            lager:debug("Sending Data ~p", [Data]),
            Callback(Socket:send(Data)),
            socket_writer(Socket);
        _ ->
            socket_writer(Socket)
    end.

socket_write(State, Data) ->
    socket_write(State, Data, fun(_) -> ok end).
                    
socket_write(State, Data, CallbackFun) ->
    (State#state.socket_writer) ! {send, Data, CallbackFun}.
    
split_at_or_at_end(N, Binary) when byte_size(Binary) > N ->
    split_at(N, Binary);
split_at_or_at_end(_N, Binary) ->
    {Binary, <<>>}.
    
split_at(N, Binary) ->
    case Binary of
        <<Bytes:N/binary, Rest/binary>> -> {Bytes, Rest}
    end.

handle_receive_need_more_data(_StreamId, #stream{read_open = false}, _Length, _From, State) ->
    {reply, {error, closed}, State};
handle_receive_need_more_data(StreamId, StreamRecord, Length, From, State) ->
    RecvWaiters = StreamRecord#stream.recv_waiters,
    NewStreams = dict:store(StreamId, StreamRecord#stream{recv_waiters = [{From, Length} | RecvWaiters]}, State#state.streams),
    {noreply, State#state{streams = NewStreams}}.    
    
handle_receive(StreamId, StreamRecord, Length, From, State) ->
    ReadBuffer = StreamRecord#stream.read_buffer,
    case byte_size(ReadBuffer) >= Length of
        true ->
            {First, Rest} = split_at(Length, ReadBuffer),
            NewStreams = dict:store(StreamId, StreamRecord#stream{read_buffer = Rest}, State#state.streams),
            {reply, First, State#state{streams = NewStreams}};
        _ ->
            handle_receive_need_more_data(StreamId, StreamRecord, Length, From, State)
    end.
 
write_headers(State, StreamId, Stream, Data, From) ->
    Self = self(),
    
    WriteFun = fun(Result) ->
        case Result of
            ok -> 
                Self ! {header_finished, {ok, StreamId}};
            Reason ->
                Self ! {write_error, Reason}
        end
    end,
    
    socket_write(State, Data, WriteFun),
    Stream#stream{syn_reply_sent = true, send_header_waiters = Stream#stream.send_header_waiters ++ [From]}.
    

    
           
handle_send_headers(State, StreamId, #stream{syn_reply_sent = true} = StreamRecord, Headers, From) ->
    Packet = espdy_frame:encode_headers(State#state.zlib_write_nv_context, StreamId, 0, Headers),
    write_headers(State, StreamId, StreamRecord, Packet, From);
    
handle_send_headers(State, StreamId, #stream{syn_reply_sent = false} = StreamRecord, Headers, From) ->
    SynReply = espdy_frame:encode_syn_reply(State#state.zlib_write_nv_context, StreamId, 0, Headers),
    write_headers(State, StreamId, StreamRecord, SynReply, From).

ensure_syn_reply_sent(_State, _StreamId, #stream{syn_reply_sent = true} = Stream) ->
    Stream;
ensure_syn_reply_sent(State, StreamId, Stream) ->
    Data = espdy_frame:encode_syn_reply(State#state.zlib_write_nv_context, StreamId, 0, []),
    WriteFun = fun(_Result) ->
        ok % TODO: handle write error
    end,
    
    socket_write(State, Data, WriteFun),
    Stream#stream{syn_reply_sent = true}.

write_flags(true) ->
    ?FLAG_FIN;
write_flags(_) ->
    0.
    
update_write_closing_flag(_Stream, true) ->
    true;
update_write_closing_flag(#stream{write_closing = Closing}, _Fin) ->
    Closing.
    
perform_write(State, StreamId, Stream0, Buffer, Fin, From) ->
    Stream = ensure_syn_reply_sent(State, StreamId, Stream0),
    perform_write_prime(State, StreamId, Stream, Buffer, Fin, From).
    
perform_write_prime(State, StreamId, Stream, BufferToSend, Fin, From) ->
    Self = self(),    
    Data = espdy_frame:encode_data_frame(StreamId, write_flags(Fin), BufferToSend),
    
    WriteFun = fun(Result) ->
        
        case Result of
            ok ->
                Self ! {write_finished, {ok, StreamId, Fin, true}};
            Reason ->
                Self ! {write_error, Reason}
        end
    end,
    
    socket_write(State, Data, WriteFun),
    Stream#stream{write_closing = update_write_closing_flag(Stream, Fin), send_waiters = Stream#stream.send_waiters ++ [From]}.

     
handle_send(StreamId, StreamRecord, Packet, Fin, From, State) ->
    StreamRecord1 = perform_write(State, StreamId, StreamRecord, Packet, Fin, From),
    update_stream(StreamId, StreamRecord1, State).

update_stream(StreamId, StreamRecord, State) ->
    NewStreams = dict:store(StreamId, StreamRecord, State#state.streams),
    State#state{streams = NewStreams}.

handle_accept(_From, #state{closing = true} = State) ->
    {reply, {error, closed}, State};
handle_accept(_From, #state{accept_buffer = [{StreamId, Headers} | Rest]} = State) ->
    {reply, {ok, StreamId, Headers}, State#state{accept_buffer = Rest}};
handle_accept(From, State) ->
    {noreply, State#state{waiting_acceptors = State#state.waiting_acceptors ++ [From]}}.

send_fin(StreamId, Stream, State) ->
    Data = espdy_frame:encode_data_frame(StreamId, ?FLAG_FIN, <<>>),
    Self = self(),
    WriteFun = fun(Result) ->
        
        case Result of
            ok ->
                Self ! {write_finished, {ok, StreamId, true, false}};
            Reason ->
                Self ! {write_error, Reason}
        end
    end,
    
    socket_write(State, Data, WriteFun),
    
    Stream#stream{write_closing = true}.
    
handle_close(StreamId, Stream, State) ->
    send_fin(StreamId, Stream, State).
    
syn_flags(WithFin, StreamId) ->
    syn_flags_fin(WithFin) bor syn_flags_uni(StreamId).
    
syn_flags_fin(true) ->
    ?FLAG_FIN;
syn_flags_fin(_WithFin) ->
    0.

syn_flags_uni(0) ->
    0;
syn_flags_uni(_) ->
    ?FLAG_UNIDIRECTIONAL.
    
handle_connect(Headers, WithFin, AssociatedStreamId, _From, State) ->
    StreamId = State#state.next_syn_stream_id,
    
    Frame = espdy_frame:encode_syn_stream(State#state.zlib_write_nv_context, syn_flags(WithFin, AssociatedStreamId), StreamId, AssociatedStreamId, 0, Headers),
    lager:debug("Sending connect frame StreamId: ~p AssociatedStreamId: ~p SynFlags: ~p Headers: ~p", [StreamId, AssociatedStreamId, syn_flags(WithFin, AssociatedStreamId), Headers]),
    
    socket_write(State, Frame),
    % TODO: FIX fully closed streams here
    State1 = update_stream(StreamId, #stream{syn_reply_sent = true, write_open = (not WithFin), read_open = (AssociatedStreamId =:= 0)}, State),
    {reply, {ok, StreamId}, State1#state{next_syn_stream_id = StreamId + 2}}.
    
    
run_with_stream(StreamId, State, Function) ->
    case dict:find(StreamId, State#state.streams) of
        error ->
            lager:debug("Stream not found ~p ~p", [StreamId, debug_streams(State)]),
            {reply, {error, closed}, State};
        {ok, StreamRecord} ->
            Function(StreamRecord)
    end.
    
is_write_open(#stream{write_closing = false, write_open = true}) ->
    true;
is_write_open(_) ->
    false.
    
run_with_stream_write_open(StreamId, State, Function) ->
    run_with_stream(StreamId, State, 
        fun(Stream) ->
            case is_write_open(Stream) of
                true -> Function(Stream);
                _ -> {reply, {error, closed}, State}
            end
        end).
        


is_closing(#state{closing = true}) ->
    true;
is_closing(#state{other_side_closing = true}) ->
    true;
is_closing(_) ->
    false.
    
handle_call({connect, Headers, WithFin, AssociatedStreamId}, From, State) ->
    case is_closing(State) of
        true ->
            {reply, {error, closed_not_processed}, State};
        _ ->
            handle_connect(Headers, WithFin, AssociatedStreamId, From, State)
    end;
handle_call({close, StreamId}, _From, State) ->
    run_with_stream(StreamId, State, fun(StreamRecord) ->
            NewStream = handle_close(StreamId, StreamRecord, State),
            {reply, ok, update_stream(StreamId, NewStream, State)}
    end);
    
handle_call(statistics, _From, State) ->
    lager:debug("Stream status for statistics ~p", [debug_streams(State)]),
    {reply, get_statistics(State), State};
    
handle_call(accept, From, State) ->
    handle_accept(From, State);
    
handle_call({send_headers, StreamId, Headers}, From, State) ->
    run_with_stream_write_open(StreamId, State, fun(StreamRecord) ->
            NewStream = handle_send_headers(State, StreamId, StreamRecord, Headers, From),
            {noreply, update_stream(StreamId, NewStream, State)}
    end);
    
handle_call({send_and_close, StreamId, Binary}, From, State) ->
    run_with_stream_write_open(StreamId, State, fun(StreamRecord) ->
            {noreply, handle_send(StreamId, StreamRecord, Binary, true, From, State)}
    end);
handle_call({send, StreamId, Binary}, From, State) ->
    run_with_stream_write_open(StreamId, State, fun(StreamRecord) ->
            {noreply, handle_send(StreamId, StreamRecord, Binary, false, From, State)}
    end);
    
handle_call({recv, StreamId, Length, _Timeout}, From, State) ->
    run_with_stream(StreamId, State, 
        fun(StreamRecord) ->
            handle_receive(StreamId, StreamRecord, Length, From, State)
        end);
    
handle_call(start, _From, State) ->
    (State#state.socket):setopts([{active, once}, {packet, raw}, {mode, binary}]),
    {reply, ok, State};
    
handle_call(Call, _From, State) ->
    lager:debug("Received invalid call ~p", [Call]),
    {reply, {error, unknown_call}, State}.

handle_cast(graceful_close, #state{closing = true} = State) ->
    {noreply, State};
handle_cast(graceful_close, #state{closing = false} = State) ->
    socket_write(State, espdy_frame:encode_goaway(State#state.last_stream_accepted)),
    case dict:size(State#state.streams) of 
        0 ->
            {stop, normal, State};
        _ ->
            {noreply, State#state{closing = true}}
    end;
   
            
handle_cast(_Call, State) ->
    {noreply, State}.

is_ping_reply(ID, Role) ->
    (ID rem 2 =:= 0) =:= (Role =:= server).

handle_ping_reply(ID, State) ->
    lager:debug("Received PING reply ~p", [ID]),
    State.
    
handle_ping(ID, State) ->
    lager:debug("Received PING ~p", [ID]),
    socket_write(State, espdy_frame:encode_ping(ID)),
    State.


stream_error_for_open_stream(StreamId, Stream, Status, State) ->
    socket_write(State, espdy_frame:encode_rst_stream(StreamId, Status)),
    stream_abnormally_closed(StreamId, Stream, State).
    
stream_error(StreamId, Status, State) ->
    socket_write(State, espdy_frame:encode_rst_stream(StreamId, Status)),
    State.
    
is_flag_fin(Flags) ->
    (Flags band ?FLAG_FIN) =:= ?FLAG_FIN.
    
send_closed(From) ->
    lager:debug("Sending {error, closed} to ~p ", [From]),
    gen_server:reply(From, {error, closed}).
  
stream_abnormally_closed(StreamId, Stream, State) ->
    stream_read_closed(Stream),
    stream_write_abnormally_closed(Stream),
    NewStreams = dict:erase(StreamId, State#state.streams),
    State#state{streams = NewStreams}.
 
stream_write_abnormally_closed(Stream) ->
    lists:foreach(fun send_closed/1, Stream#stream.send_waiters).
        
stream_read_closed(Stream) ->
    [send_closed(From) || {From, _Length} <- Stream#stream.recv_waiters].
    


add_stream_data(Stream, Data) ->
    ReadBuffer = Stream#stream.read_buffer,
    lager:debug("Reply To Receivers ~p ~p ~n", [Data, Stream#stream.recv_waiters]),
    {NewBuffer, NewReceivers} = reply_to_receivers(<<ReadBuffer/binary, Data/binary>>, lists:reverse(Stream#stream.recv_waiters)),
    Stream#stream{read_buffer = NewBuffer, recv_waiters = NewReceivers}.
    
reply_to_receivers(Buffer, []) ->
    {Buffer, []};
reply_to_receivers(Binary, [{From, Length} | Rest] = Receivers) ->
    case Binary of 
        <<Packet:Length/binary, RestOfBuffer/binary>> -> 
            lager:debug("Reply To Receiver ~p ~p ~n", [From, Packet]),
            gen_server:reply(From, Packet),
            reply_to_receivers(RestOfBuffer, Rest);
        _ ->
            {Binary, Receivers}
    end.

update_open_stream(Stream, Flags) ->
    case is_flag_fin(Flags) of
        true ->
            lager:debug("Closing Stream", []),
            stream_read_closed(Stream),
            Stream#stream{read_open = false, recv_waiters = []};
        _ ->
            Stream
    end.
    
            
handle_valid_data_frame(StreamId, #stream{read_open = false} = Stream, _Flags, _Data, State) ->
    stream_error_for_open_stream(StreamId, Stream, ?INVALID_STREAM, State);
        
handle_valid_data_frame(StreamId, Stream, Flags, Data, State) ->
    Stream1 = add_stream_data(Stream, Data),
    Stream2 = update_open_stream(Stream1, Flags),
    check_if_stream_is_fully_closed_and_update_stream(StreamId, Stream2, State).

new_stream(StreamId, Headers, #state{waiting_acceptors = [H|Rest]} = State) ->
    gen_server:reply(H, {ok, StreamId, Headers}),
    State#state{waiting_acceptors = Rest};
new_stream(StreamId, Headers, State) ->
    State#state{accept_buffer = State#state.accept_buffer ++ [{StreamId, Headers}]}.
    
expected_stream_modulus(#state{role = server}) ->
    1;
expected_stream_modulus(#state{role = client}) ->
    0.
    
can_accept_stream(State) ->
    State#state.closing =:= false.
    
is_valid_stream_id(State, StreamId) ->
    (StreamId =/= 0) and (expected_stream_modulus(State) =:= (StreamId rem 2)) and (State#state.last_stream_accepted < StreamId).

check_headers(StreamId, {error, Reason}, _Flags, State) ->
    lager:debug("Receive invalid header ~p", [Reason]),
    stream_error(StreamId, ?PROTOCOL_ERROR, State);

check_headers(StreamId, Headers, Flags, State) -> 
    NewStreams = dict:store(StreamId, #stream{read_open = not is_flag_fin(Flags)}, State#state.streams),
    new_stream(StreamId, Headers, State#state{streams = NewStreams, last_stream_accepted = StreamId}).
           
accept_stream(State, StreamId, Flags, Headers) ->
    
    case is_valid_stream_id(State, StreamId) of
        true ->
            check_headers(StreamId, Headers, Flags, State);
        false ->
            stream_error(StreamId, ?PROTOCOL_ERROR, State),
            State
    end.
    
refuse_stream(State, StreamId) ->
    stream_error(StreamId, ?REFUSED_STREAM, State),
    State.
    
with_stream(StreamId, State, Fun) ->
    case dict:find(StreamId, State#state.streams) of
        error ->
            lager:debug("Stream Error: INVALID STREAM", []), 
            stream_error(StreamId, ?INVALID_STREAM, State);
        {ok, Stream} ->
            Fun(Stream)
    end.
    
validate_header_frame(Stream, Headers) ->
    case {Headers, Stream#stream.read_open} of 
        {{error, _Reason}, _} ->
            {error, ?PROTOCOL_ERROR};
        {_, false } ->
            {error, ?INVALID_STREAM};
        _ ->
            ok
    end.
    
handle_frame(#control_frame{type = ?GOAWAY, data = <<?RESERVED_BIT, ?STREAM_ID(_LastAcceptedStreamId)>>}, State) ->
  State#state{other_side_closing = true};
handle_frame(#control_frame{type = ?HEADERS, data = 
    <<?RESERVED_BIT, ?STREAM_ID(StreamId),
      ?UNUSED(?UNUSED_HEADERS), NameValueHeaderBlock/binary>>}, State) ->
    %% must always decode headers
    Headers = espdy_frame:decode_name_value_header_block(State#state.zlib_read_nv_context, NameValueHeaderBlock),
    lager:debug("Receive headers ~p", [Headers]),
    
    with_stream(StreamId, State, fun(Stream) ->
        case validate_header_frame(Stream, Headers) of 
            {error, Status} ->
                stream_error(StreamId, Status, State);
            _ ->
                lager:debug("Received valid headers but we ignore headers..."),
                State
        end
    end);
    
handle_frame(#control_frame{type = ?NOOP}, State) ->
    State;
    
handle_frame(#control_frame{type = ?PING, data = <<?UINT32(ID)>>}, State) ->
    case is_ping_reply(ID, State#state.role) of 
        true -> handle_ping_reply(ID, State);
        _ -> handle_ping(ID, State)
    end;
 
handle_frame(#control_frame{flags = Flags, type = ?SYN_STREAM, data = 
    <<?RESERVED_BIT, ?STREAM_ID(StreamId), 
      ?RESERVED_BIT, ?STREAM_ID(_AssociatedToStreamId),
      ?PRIORITY(_Priority), ?UNUSED(?UNUSED_SYN_STREAM), 
      NameValueHeaderBlock/binary>>}, State) ->
    
    lager:debug("Received SYN STREAM for ~p with NameValueHeaderBlock size ~p", [StreamId, byte_size(NameValueHeaderBlock)]),
    % always need to decode headers to stop streams getting of sync
    
    Headers = espdy_frame:decode_name_value_header_block(State#state.zlib_read_nv_context, NameValueHeaderBlock),
    
    case can_accept_stream(State) of
        true ->
            accept_stream(State, StreamId, Flags, Headers);
        false ->
            refuse_stream(State, StreamId)
    end;

handle_frame(#control_frame{type = ?RST_STREAM, data = 
    <<?RESERVED_BIT, ?STREAM_ID(StreamId), ?UINT32(StatusCode)>>}, State) ->
        case dict:find(StreamId, State#state.streams) of
            error ->
                lager:debug("Received RST_STREAM for unknown stream: ~p (~p)", [StreamId, StatusCode]),
                State;
            {ok, Stream} ->
                lager:debug("Received RST_STREAM for stream: ~p (~p)", [StreamId, StatusCode]),
                stream_abnormally_closed(StreamId, Stream, State)
        end;
                 
handle_frame(#data_frame{stream_id = StreamId, flags = Flags, data = Data}, State) ->
    with_stream(StreamId, State, fun(Stream) ->
        handle_valid_data_frame(StreamId, Stream, Flags, Data, State)
    end);

handle_frame(Frame, State) ->
    lager:debug("Received Unknown Frame: ~p", [Frame]),
    State.
    
handle_data(Data, State0) ->
    case espdy_frame:read_frame(State0#state.read_buffer, Data) of
        {Frame, NewBuffer} ->
            lager:debug("Received frame ~p", [Frame]),
            State = handle_frame(Frame, State0),
            handle_data(<<>>, State#state{read_buffer = NewBuffer});
        NewBuffer ->
            lager:debug("Buffering... ~p", [NewBuffer]),
            (State0#state.socket):setopts([{active, once}]),
            State0#state{read_buffer = NewBuffer}
    end.

notify_write_finished(Stream, true) ->
    case Stream#stream.send_waiters of
        [Top | Rest] ->
            gen_server:reply(Top, ok),
            Stream#stream{send_waiters = Rest};
        _ ->
            %WTF
            Stream
    end;
    
notify_write_finished(Stream, false) ->
    Stream.

stream_finished(StreamId, _Stream, State) ->
    lager:debug("Stream fully closed ~p", [StreamId]),
    State#state{streams = dict:erase(StreamId, State#state.streams)}.

check_if_stream_is_fully_closed_and_update_stream(StreamId, #stream{read_open = false, write_open = false} = Stream, State) ->
    stream_finished(StreamId, Stream, State);
check_if_stream_is_fully_closed_and_update_stream(StreamId, Stream, State) ->
    update_stream(StreamId, Stream, State).
    
check_for_graceful_shutdown(State) ->
    case (State#state.closing =:= true) and (dict:size(State#state.streams) =:= 0) of
        true ->
            lager:debug("scheduled shutdown", []),
            {stop, normal, State};
        _ ->
            {noreply, State}
    end.
    
handle_write_finished(StreamId, Stream0, Fin, Notify, State) ->
    Stream1 = notify_write_finished(Stream0, Notify),
    Stream2 = case Fin of
        true ->
            Stream1#stream{write_open = false};
        _ ->
            Stream1
    end,
    
    check_if_stream_is_fully_closed_and_update_stream(StreamId, Stream2, State).

handle_header_finished(StreamId, Stream, State) ->
    NewStream = case Stream#stream.send_header_waiters of 
        [Top | Rest] ->
            gen_server:reply(Top, ok),
            Stream#stream{send_header_waiters = Rest};
        _ ->
            %WTF
            Stream
    end,
    
    update_stream(StreamId, NewStream, State).


handle_info({header_finished, {ok, StreamId}}, State) ->
    lager:debug("header_finished ~p", [StreamId]),
    case dict:find(StreamId, State#state.streams) of 
        {ok, Stream} ->
            {noreply, handle_header_finished(StreamId, Stream, State)};
        _ ->
            lager:debug("Received header_finished notification for stream that no longer exists ~p", [StreamId]),
            {noreply, State}
    end;                
handle_info({write_error, Reason}, State) ->
    lager:debug("Received write_error notification ~p", [Reason]),
    {stop, normal, State};
    
handle_info({write_finished, {ok, StreamId, Fin, Notify}}, State) ->
    lager:debug("write_finished ~p", [StreamId]),
    case dict:find(StreamId, State#state.streams) of 
        {ok, Stream} ->
            State1 = handle_write_finished(StreamId, Stream, Fin, Notify, State),
            lager:debug("Stream status ~p", [debug_streams(State1)]),
            check_for_graceful_shutdown(State1);
        _ ->
            lager:debug("Received write_finished notification for stream that no longer exists ~p", [StreamId]),
            {noreply, State}
    end;

handle_info({CloseTag, _Socket}, #state{close_tag = CloseTag} = State0) ->
    lager:debug("Received closed ~p", [self()]),
    %% mmmm... i think this is wrong. need to add tests for half closed tcp
    
    {stop, normal, State0};
    
handle_info({DataTag, _Socket, Data}, #state{data_tag = DataTag} = State0) ->
    lager:debug("Received data ~p Buffer ~p ~n", [Data, State0#state.read_buffer]),
    State = handle_data(Data, State0),
    lager:debug("Stream status ~p", [debug_streams(State)]),
    check_for_graceful_shutdown(State);
    

handle_info(Msg, State) ->
    lager:debug("Received unknown message ~p", [Msg]),
    {noreply, State}.

clean_up_listeners(Stream) ->
    stream_read_closed(Stream),
    stream_write_abnormally_closed(Stream).
    
dict_for_each_value(Fun, Dict) ->
    dict:fold(
        fun(_K, V, Acc) -> 
            Fun(V),
            Acc
        end, 0, Dict).
        
clean_up_all_listeners(State) ->
    dict_for_each_value(fun clean_up_listeners/1, State#state.streams).


get_statistics(State) ->
    [RO, WO, BO, Z] = dict:fold(
        fun (_K, #stream{read_open = true} = Stream, [ReadOpen, WriteOpen, BothOpen, Zombies]) -> 
            case is_write_open(Stream) of
                true ->
                    [ReadOpen, WriteOpen, BothOpen + 1, Zombies];
                _ ->
                    [ReadOpen + 1, WriteOpen, BothOpen, Zombies]
            end;
            (_K, #stream{read_open = false} = Stream , [ReadOpen, WriteOpen, BothOpen, Zombies]) ->
            case is_write_open(Stream) of
                true ->
                    [ReadOpen, WriteOpen + 1, BothOpen, Zombies];
                _ ->
                    [ReadOpen, WriteOpen, BothOpen, Zombies + 1]
            end
        end, [0, 0, 0, 0], State#state.streams),
    [{read_open, RO}, {write_open, WO}, {both_open, BO}, {zombies, Z}].
            
            
terminate(_Reason, State) ->
    zlib:close(State#state.zlib_read_nv_context),
    zlib:close(State#state.zlib_write_nv_context),
    clean_up_all_listeners(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.