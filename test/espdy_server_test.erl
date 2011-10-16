-module(espdy_server_test).
-compile([{parse_transform, lager_transform}]).

-include_lib("eunit/include/eunit.hrl").
-include("espdy_frame.hrl").
-include("espdy_server.hrl").
  
-define(TEST(X), {setup, local, fun setup/0, fun tear_down/1, {atom_to_list(X), fun X/0}}).
    
% there has to be an easier way of doing this... right ?

packet_sim_test_() ->
      {spawn,
          [
          ?TEST(close_after_send_tst),
          ?TEST(syn_reply_tst),
          ?TEST(send_tst),
          ?TEST(rst_while_waiting_for_read_tst),
          ?TEST(rst_read_tst),
          ?TEST(flag_fin_read_ok_tst),
          ?TEST(flag_fin_tst),
          ?TEST(flag_fin_during_tst),
          ?TEST(syn_stream_tst),
          ?TEST(syn_stream_buffer_tst),
          ?TEST(syn_stream_blocking_tst),
          ?TEST(server_ping_tst),
          ?TEST(client_ping_tst),
          ?TEST(server_receive_ping_reply_tst),
          ?TEST(client_receive_ping_reply_tst),
          ?TEST(statistics_tst),
          ?TEST(statistics_read_open_tst),
          ?TEST(handle_accept_queue_tst),
          ?TEST(handle_receive_write_after_close_from_other_side_tst),
          ?TEST(handle_non_existant_data_frame_tst),
          ?TEST(handle_write_finished_for_stream_that_no_longer_exists_tst),
          ?TEST(handle_header_finished_for_stream_that_no_longer_exists_tst),
          ?TEST(receive_closed_when_the_underlying_connection_is_closed_beneath_us_tst),
          ?TEST(send_headers_tst),
          ?TEST(handle_split_frame_tst),
          ?TEST(noop_tst),
          ?TEST(receive_protocol_error_for_invalid_syn_tst),
          ?TEST(receive_protocol_error_for_invalid_syn_when_zero_tst),
          ?TEST(receive_protocol_error_for_invalid_syn_when_going_backwards_tst),
          ?TEST(graceful_close_closes_server_when_there_are_no_connections_tst),
          ?TEST(graceful_close_closes_server_when_last_connection_is_closed_tst),
          ?TEST(graceful_close_close_twice_tst),
          ?TEST(unknown_cast_tst),
          ?TEST(unknown_call_tst),
          ?TEST(statistics_zombie_tst),
          ?TEST(zero_length_name_receives_rst_tst),
          ?TEST(zero_length_value_receives_rst_tst),
          ?TEST(zero_length_multi_value_receives_rst_tst),
          ?TEST(zero_length_name_receives_rst_when_receiving_headers_tst),
          ?TEST(receive_rst_after_sending_on_closed_channel_tst),
          ?TEST(refuse_new_connections_after_receiving_goaway_tst),
          ?TEST(refuse_new_connects_after_sending_goaway_tst),
          ?TEST(refuse_new_accepts_after_sending_goaway_tst),
          ?TEST(connect_and_recv_tst),
          ?TEST(connect_for_push_and_get_error_closed_when_recving_tst),
          ?TEST(connect_and_send_syn_fin_tst)
          
          ]
       }
      .
    
setup() ->
    application:start(lager),
    lager:set_loglevel(lager_console_backend, error).
    
tear_down(_) ->
    check_for_messages().

check_for_messages() ->
    receive
        Msg ->
            lager:info("Received message ~p", [Msg]),
            ?assert(false)
        after 100 ->
            ok
    end.
    
start_socket(Role) ->
    Socket = espdy_mock_socket:new(self()),
    {ok, Pid} = espdy_server:start_link(Socket, Role),
    Pid.
    
send_syn_stream(ZLib, Pid, StreamId, Headers) ->
    Frame = espdy_frame:encode_syn_stream(ZLib, 0, StreamId, 0, 0, Headers),
    send_frame(Pid, Frame).
    
send_syn_stream(ZLib, Pid, StreamId) ->
    send_syn_stream(ZLib, Pid, StreamId, []).
        
send_syn_stream(Pid, StreamId) ->
    Frame = espdy_frame:encode_syn_stream(0, StreamId, 0, 0, []),
    send_frame(Pid, Frame).
    
start_channel(ZLib, Pid, N) ->
    send_syn_stream(ZLib, Pid, N),
    {ok, Socket, _Headers} = espdy_server:accept(Pid),
    Socket.
        
start_channel(Pid, N) ->
    send_syn_stream(Pid, N),
    {ok, Socket, _Headers} = espdy_server:accept(Pid),
    Socket.    
    
start_channel_one(Pid) ->
    start_channel(Pid, 1).
    
start_channel_one() ->
    start_channel_one(start_socket(server)).


receive_packet() ->
    receive
        {packet, PacketPid, Packet} -> 
            PacketPid ! {mock_packet_result, ok},
            timer:sleep(50) % DODGY HACK
    end,
    Packet.
    
receive_data_frame() ->
    receive
        {packet, PacketPid, Packet} -> PacketPid ! {mock_packet_result, ok}
    end,
    Frame = espdy_frame:decode_exactly_one_frame(Packet),
    ?assertMatch(#data_frame{}, Frame),
    Frame.

receive_control_frame() ->
    receive
        {packet, PacketPid, Packet} -> PacketPid ! {mock_packet_result, ok}
    end,
    Frame = espdy_frame:decode_exactly_one_frame(Packet),
    ?assertMatch(#control_frame{}, Frame),
    Frame.


    
send_frame(#espdy_socket{pid = Pid}, Packet) ->
    Pid ! {tcp, undefined, Packet};

send_frame(Pid, Packet) ->
    Pid ! {tcp, undefined, Packet}.
        
assert_dont_receive_packet() ->
    receive 
        {packet, _, _} -> ?assert(false)
    after 10 ->
        ok
    end.
           
receive_response(Ref) ->
    receive 
        {Ref, Resp} -> ok
    end,
    Resp.



statistics_zombie_tst() ->
    Pid = start_socket(server),
    Socket = start_channel_one(Pid),
    
    send_frame(Socket, espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<>>)),
    
    Ref1 = espdy_server:async_send_and_close(Socket, <<"hello">>),
    ?assertMatch(#control_frame{type = ?SYN_REPLY}, receive_control_frame()),
    
    % ZOOOMBIIIESSS. this probably shouldn't be a zombie. but the idea is we need to keep 
    % streams around until they have written all their crap out. 
    ?assertEqual([{read_open, 0}, {write_open, 0}, {both_open, 0}, {zombies, 1}], espdy_server:statistics(Pid)),
    ?assertMatch(#data_frame{flags = ?FLAG_FIN}, receive_data_frame()),
    ok = receive_response(Ref1).
    
    
statistics_read_open_tst() ->
    Pid = start_socket(server),
    Socket = start_channel_one(Pid),
    
    ?assertEqual([{read_open, 0}, {write_open, 0}, {both_open, 1}, {zombies, 0}], espdy_server:statistics(Pid)),
    
    Ref1 = espdy_server:async_send_and_close(Socket, <<"hello">>),
    ?assertMatch(#control_frame{type = ?SYN_REPLY}, receive_control_frame()),
    ?assertMatch(#data_frame{flags = ?FLAG_FIN}, receive_data_frame()),
    ok = receive_response(Ref1),
    
    ?assertEqual([{read_open, 1}, {write_open, 0}, {both_open, 0}, {zombies, 0}], espdy_server:statistics(Pid)).
    
    
statistics_tst() ->
    Pid = start_socket(server),
    Socket = start_channel_one(Pid),
    
    ?assertEqual([{read_open, 0}, {write_open, 0}, {both_open, 1}, {zombies, 0}], espdy_server:statistics(Pid)),
    
    send_frame(Socket, espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<>>)),
    
    ?assertEqual([{read_open, 0}, {write_open, 1}, {both_open, 0}, {zombies, 0}], espdy_server:statistics(Pid)),

    Ref1 = espdy_server:async_send_and_close(Socket, <<"hello">>),
    
    ?assertMatch(#control_frame{type = ?SYN_REPLY}, receive_control_frame()),
    ?assertMatch(#data_frame{flags = ?FLAG_FIN}, receive_data_frame()),
    
    ok = receive_response(Ref1),
    
    ?assertEqual([{read_open, 0}, {write_open, 0}, {both_open, 0}, {zombies, 0}], espdy_server:statistics(Pid))
    
    .
     
close_after_send_tst() ->

    Socket = start_channel_one(),
    Ref1 = espdy_server:async_send(Socket, <<"hello">>),
    
    %SYN_REPLY
    receive_control_frame(),
    
    receive_data_frame(),
    ok = receive_response(Ref1),
    
    Ref2 = espdy_server:async_close(Socket),
    
    DataFrame = receive_data_frame(),
    ?assertEqual(?FLAG_FIN, DataFrame#data_frame.flags),
    
    ok = receive_response(Ref2).
    
    
syn_reply_tst() ->
    Headers = [{<<"foo">>, [<<"bar">>]}],

    Socket = start_channel_one(),
    Ref1 = espdy_server:async_send_headers(Socket, Headers),
    ControlFrame = receive_control_frame(),
    SynReply = espdy_frame:decode_control_frame(ControlFrame),
    ?assertEqual(1, SynReply#syn_reply.stream_id),
    ?assertEqual(Headers, SynReply#syn_reply.headers),
    ?assertEqual(0, SynReply#syn_reply.flags),
    
    ok = receive_response(Ref1).
    
send_tst() ->

    Socket = start_channel_one(),
    Ref1 = espdy_server:async_send(Socket, <<"helloworld">>),
    Ref2 = espdy_server:async_send(Socket, <<"lollercopter">>),

    ControlFrame = receive_control_frame(),
    SynReply = espdy_frame:decode_control_frame(ControlFrame),
    ?assertEqual(#syn_reply{stream_id = 1, headers = [], flags = 0}, SynReply),
    
    DataFrame = receive_data_frame(),
    ?assertEqual(1, DataFrame#data_frame.stream_id),
    ?assertEqual(<<"helloworld">>, DataFrame#data_frame.data),
    
    ?assertEqual(#data_frame{stream_id = 1, data = <<"lollercopter">>, flags = 0}, receive_data_frame()),
    
    ok = receive_response(Ref1),
    ok = receive_response(Ref2).
    
rst_while_waiting_for_read_tst() ->

    Socket = start_channel_one(),
    DataFrame = espdy_frame:encode_data_frame(1, 0, <<"1234">>),
    RstFrame = espdy_frame:encode_rst_stream(1, ?PROTOCOL_ERROR),
    
    send_frame(Socket, DataFrame),
    
    Ref1 = espdy_server:async_recv(Socket, 6),
    
    send_frame(Socket, RstFrame),

    {error, closed} = receive_response(Ref1).
    
rst_read_tst() ->

    Socket = start_channel_one(),
    
    DataFrame = espdy_frame:encode_data_frame(1, 0, <<"12345">>),
    
    send_frame(Socket, DataFrame),
    RstFrame = espdy_frame:encode_rst_stream(1, ?PROTOCOL_ERROR),
    
    send_frame(Socket, RstFrame),
    
    ?assertEqual({error, closed}, espdy_server:recv(Socket, 4)).
    
    
flag_fin_read_ok_tst() ->

    Socket = start_channel_one(),
    DataFrame = espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<"1234">>),
    send_frame(Socket, DataFrame),
    
    ?assertEqual(<<"1234">>, espdy_server:recv(Socket, 4)).
    
flag_fin_tst() ->

    Socket = start_channel_one(),
    DataFrame = espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<"1234">>),
    send_frame(Socket, DataFrame),
    
    ?assertEqual({error, closed}, espdy_server:recv(Socket, 6)).

flag_fin_during_tst() ->

    Socket = start_channel_one(),
    DataFrame = espdy_frame:encode_data_frame(1, 0, <<"1234">>),
    send_frame(Socket, DataFrame),
    Ref1 = espdy_server:async_recv(Socket, 6),
    
    DataFrame2 = espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<"5">>),
    send_frame(Socket, DataFrame2),
    ?assertEqual({error, closed}, receive_response(Ref1)).

syn_stream_tst() ->

    Socket = start_channel_one(),
    DataFrame = espdy_frame:encode_data_frame(1, 0, <<"helloxworld">>),
    send_frame(Socket, DataFrame),
    
    Binary = espdy_server:recv(Socket, 6), 
    ?assertEqual(<<"hellox">>, Binary),
    Binary2 = espdy_server:recv(Socket, 5),
    ?assertEqual(<<"world">>, Binary2).

syn_stream_buffer_tst() ->

    Socket = start_channel_one(),
  
    DataFrame = espdy_frame:encode_data_frame(1, 0, <<"1234">>),
    DataFrame2 = espdy_frame:encode_data_frame(1, 0, <<"5678">>),
    send_frame(Socket, DataFrame),
    send_frame(Socket, DataFrame2),
    
    Binary = espdy_server:recv(Socket, 6),
    ?assertEqual(<<"123456">>, Binary),
    Binary2 = espdy_server:recv(Socket, 2),
    ?assertEqual(<<"78">>, Binary2).
    
syn_stream_blocking_tst() ->

    Socket = start_channel_one(),

    Ref1 = espdy_server:async_recv(Socket, 6),
    Ref2 = espdy_server:async_recv(Socket, 5),
    
    DataFrame = espdy_frame:encode_data_frame(1, 0, <<"helloxworld">>),
    
    send_frame(Socket, DataFrame),

    ?assertEqual(<<"hellox">>, receive_response(Ref1)),
    ?assertEqual(<<"world">>, receive_response(Ref2)).


receive_accept(Pid, Ref) ->
    {ok, StreamId, Headers} = receive_response(Ref),
    {ok, #espdy_socket{pid = Pid, stream_id = StreamId}, Headers}.
    
handle_accept_queue_tst() ->
    Socket = start_socket(server),
    
    Ref1 = espdy_server:async_accept(Socket),
    Ref2 = espdy_server:async_accept(Socket),
    
    ZLib = espdy_frame:initialize_zlib_for_deflate(),
    send_syn_stream(ZLib, Socket, 1),
    send_syn_stream(ZLib, Socket, 3),
    zlib:close(ZLib),
    
    {ok, Socket1, []} = receive_accept(Socket, Ref1),
    ?assertEqual(1, espdy_server:stream_id(Socket1)),
    {ok, Socket2, []} = receive_accept(Socket, Ref2),
    ?assertEqual(3, espdy_server:stream_id(Socket2)).
    
receive_rst_stream(StreamId, Status) ->
    ControlFrame = receive_control_frame(),
    ?assertMatch(#control_frame{type = ?RST_STREAM}, ControlFrame),
    ?assertMatch(#rst_stream{stream_id = StreamId, status = Status}, espdy_frame:decode_control_frame(ControlFrame)).
    
handle_receive_write_after_close_from_other_side_tst() ->
    Socket = start_channel_one(),
    send_frame(Socket, espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<>>)),
    send_frame(Socket, espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<>>)),
    
    receive_rst_stream(1, ?INVALID_STREAM),
    
    {error, closed} = espdy_server:send(Socket, <<"hello">>).
    
handle_non_existant_data_frame_tst() ->
    Socket = start_channel_one(),
    send_frame(Socket, espdy_frame:encode_data_frame(2, ?FLAG_FIN, <<>>)),
    receive_rst_stream(2, ?INVALID_STREAM).
    
    
handle_write_finished_for_stream_that_no_longer_exists_tst() ->
    % not sure if this is actually possible.. but we have tests for it...
    Socket = start_socket(server),
    
    Socket ! {write_finished, {ok, 1, false, true}}.
    
handle_header_finished_for_stream_that_no_longer_exists_tst() ->
    % not sure if this is actually possible.. but we have tests for it...
    Socket = start_socket(server),

    Socket ! {header_finished, {ok, 1}}.
        
tcp_close(#espdy_socket{pid = Pid}) ->
    Pid ! {tcp_closed, undefined}.
    
receive_closed_when_the_underlying_connection_is_closed_beneath_us_tst() ->
    Socket = start_channel_one(),
    Ref1 = espdy_server:async_recv(Socket, 5),
    tcp_close(Socket),
    {error, closed} = receive_response(Ref1).
    
receive_syn_reply(ZLib) ->
    ControlFrame = receive_control_frame(),
    SynReply = espdy_frame:decode_control_frame(ZLib, ControlFrame),
    ?assertMatch(#syn_reply{}, SynReply),
    SynReply.

receive_headers(ZLib) ->
    ControlFrame = receive_control_frame(),
    Headers = espdy_frame:decode_control_frame(ZLib, ControlFrame),
    ?assertMatch(#headers{}, Headers),
    Headers.
    
send_headers_tst() ->
    Socket = start_channel_one(),
    FirstHeaders = [{<<"foo">>, [<<"bar">>]}],
    Ref1 = espdy_server:async_send_headers(Socket, FirstHeaders),
    ZLib = espdy_frame:initialize_zlib_for_inflate(),
    ?assertMatch(#syn_reply{headers = FirstHeaders}, receive_syn_reply(ZLib)),
    
    SecondHeaders = [{<<"bar">>, [<<"foo">>]}],
    Ref2 = espdy_server:async_send_headers(Socket, SecondHeaders),
    ?assertMatch(#headers{headers = SecondHeaders}, receive_headers(ZLib)),
    
    zlib:close(ZLib),
    
    ok = receive_response(Ref1),
    ok = receive_response(Ref2).
    
handle_split_frame_tst() ->
    Socket = start_socket(server),
    Frame = espdy_frame:encode_syn_stream(0, 1, 0, 0, []),
    <<Part1:2/binary, Part2/binary>> = Frame,
    send_frame(Socket, Part1),
    send_frame(Socket, Part2),
    {ok, _StreamSock, []} = espdy_server:accept(Socket).
  
noop_tst() ->
    Socket = start_socket(server),
    Noop = espdy_frame:encode_noop(),
    send_frame(Socket, Noop).
    
receive_protocol_error_for_invalid_syn_tst() ->
    Socket = start_socket(server),
    ZLib = espdy_frame:initialize_zlib_for_deflate(),
    Headers = [{<<"hello">>, [<<"world">>]}],
    
    send_syn_stream(ZLib, Socket, 2, Headers),

    
    
    ControlFrame = receive_control_frame(),
    RstStream = espdy_frame:decode_control_frame(ControlFrame),
    ?assertMatch(#rst_stream{stream_id = 2, status = ?PROTOCOL_ERROR}, RstStream),
    
    send_syn_stream(ZLib, Socket, 3, Headers),
    
    {ok, Socket1, Headers} = espdy_server:accept(Socket).
    
receive_protocol_error_for_invalid_syn_when_zero_tst() ->
    Socket = start_socket(client),
    Frame = espdy_frame:encode_syn_stream(0, 0, 0, 0, []),
    send_frame(Socket, Frame),

    ControlFrame = receive_control_frame(),
    RstStream = espdy_frame:decode_control_frame(ControlFrame),
    ?assertMatch(#rst_stream{stream_id = 0, status = ?PROTOCOL_ERROR}, RstStream).
    

receive_protocol_error_for_invalid_syn_when_going_backwards_tst() ->
    Socket = start_socket(server),
    ZLib = espdy_frame:initialize_zlib_for_deflate(),
    Socket3 = start_channel(ZLib, Socket, 3),
    send_syn_stream(ZLib, Socket, 1, []),

    ControlFrame = receive_control_frame(),
    RstStream = espdy_frame:decode_control_frame(ControlFrame),
    ?assertMatch(#rst_stream{stream_id = 1, status = ?PROTOCOL_ERROR}, RstStream).

zero_length_name_receives_rst_tst() ->
    Socket = start_socket(server),
    Frame = espdy_frame:encode_syn_stream_with_raw_uncompressed_name_value_pairs(0, 1, 0, 0, <<?UINT16(1), ?UINT16(0), "", ?UINT16(3), "foo" >>),
    send_frame(Socket, Frame),
    RstStream = espdy_frame:decode_control_frame(receive_control_frame()),
    ?assertMatch(#rst_stream{stream_id = 1, status = ?PROTOCOL_ERROR}, RstStream).

zero_length_value_receives_rst_tst() ->
    Socket = start_socket(server),
    Frame = espdy_frame:encode_syn_stream_with_raw_uncompressed_name_value_pairs(0, 1, 0, 0, <<?UINT16(1), ?UINT16(3), "foo", ?UINT16(0), "" >>),
    send_frame(Socket, Frame),
    RstStream = espdy_frame:decode_control_frame(receive_control_frame()),
    ?assertMatch(#rst_stream{stream_id = 1, status = ?PROTOCOL_ERROR}, RstStream).
    
zero_length_multi_value_receives_rst_tst() ->
    Socket = start_socket(server),
    Frame = espdy_frame:encode_syn_stream_with_raw_uncompressed_name_value_pairs(0, 1, 0, 0, <<?UINT16(1), ?UINT16(3), "foo", ?UINT16(4), "foo", 0>>),
    send_frame(Socket, Frame),
    RstStream = espdy_frame:decode_control_frame(receive_control_frame()),
    ?assertMatch(#rst_stream{stream_id = 1, status = ?PROTOCOL_ERROR}, RstStream).
        
    
zero_length_name_receives_rst_when_receiving_headers_tst() ->
    ZLib = espdy_frame:initialize_zlib_for_deflate(),
    Socket = start_socket(server),
    send_syn_stream(ZLib, Socket, 1),
    
    Frame = espdy_frame:encode_headers_with_raw_uncompressed_name_value_pairs(ZLib, 1, 0, <<?UINT16(1), ?UINT16(0), "", ?UINT16(3), "foo">>),
    send_frame(Socket, Frame),
    RstStream = espdy_frame:decode_control_frame(receive_control_frame()),
    ?assertMatch(#rst_stream{stream_id = 1, status = ?PROTOCOL_ERROR}, RstStream).
    
% receive_headers_tst() ->
%     ZLib = espdy_frame:initialize_zlib_for_deflate(),
%     Socket = start_socket(server),
%     Headers = [{<<"name">>, [<<"value">>]}],
%     send_syn_stream(ZLib, Socket, 1),
%     {ok, Socket1, _} = espdy_server:accept(Socket),
%     send_frame(Socket, espdy_frame:encode_headers(ZLib, 1, 0, Headers)),
%     
%     ?assertMatch({header, Headers}, espdy_server:recv_header_or_data(Socket1)).
    
graceful_close_closes_server_when_there_are_no_connections_tst() ->
    Socket = start_socket(server),
    espdy_server:graceful_close(Socket),
    ControlFrame = receive_control_frame(),
    GoAway = espdy_frame:decode_control_frame(ControlFrame),
    ?assertMatch(#goaway{last_good_stream_id = 0}, GoAway),
    ?assertEqual({error, closed}, espdy_server:statistics(Socket)).
    
assert_cant_start_channel_with_refused(ZLib, Socket, N) ->
    send_syn_stream(ZLib, Socket, 3),
    ControlFrame = receive_control_frame(),
    RstStream = espdy_frame:decode_control_frame(ControlFrame),
    ?assertMatch(#rst_stream{stream_id = N, status = ?REFUSED_STREAM}, RstStream).
    
graceful_close_close_twice_tst() ->
    Socket = start_socket(server),
    Socket1 = start_channel(Socket, 1),
    espdy_server:graceful_close(Socket),
    espdy_server:graceful_close(Socket),
    ControlFrame = receive_control_frame(),
    GoAway = espdy_frame:decode_control_frame(ControlFrame),
    ?assertMatch(#goaway{last_good_stream_id = 1}, GoAway).
    
graceful_close_closes_server_when_last_connection_is_closed_tst() ->
    ZLib = espdy_frame:initialize_zlib_for_deflate(),
    Msg1 = <<"omgdoesitwork?">>,
    Socket = start_socket(server),
    Socket1 = start_channel(ZLib, Socket, 1),
    espdy_server:graceful_close(Socket),
    ControlFrame = receive_control_frame(),
    GoAway = espdy_frame:decode_control_frame(ControlFrame),
    ?assertMatch(#goaway{last_good_stream_id = 1}, GoAway),
    
    assert_cant_start_channel_with_refused(ZLib, Socket, 3),
    
    send_frame(Socket1, espdy_frame:encode_data_frame(1, ?FLAG_FIN, Msg1)),
    ?assertEqual(Msg1, espdy_server:recv(Socket1, byte_size(Msg1))),
    
    Ref1 = espdy_server:async_close(Socket1),
    receive_packet(),
    ok = receive_response(Ref1),
        
    ?assertEqual({error, closed}, espdy_server:statistics(Socket)).
        
receive_rst_after_sending_on_closed_channel_tst() ->
    ZLib = espdy_frame:initialize_zlib_for_deflate(),
    Socket = start_socket(server),
    Headers = [{<<"name">>, [<<"value">>]}],
    send_syn_stream(ZLib, Socket, 1),
    
    {ok, Socket1, _} = espdy_server:accept(Socket),
    
    send_frame(Socket, espdy_frame:encode_data_frame(1, ?FLAG_FIN, <<>>)),
    send_frame(Socket, espdy_frame:encode_headers(ZLib, 1, 0, Headers)),

    ?assertMatch(#rst_stream{stream_id = 1, status = ?INVALID_STREAM}, espdy_frame:decode_control_frame(receive_control_frame())),
    
    send_syn_stream(ZLib, Socket, 3, Headers),
    
    {ok, Socket2, Headers} = espdy_server:accept(Socket)
    
    
    % this can happen naturally not just from broken clients because there is a race
    % between cancelling/refusing a stream and the other party being aware of this
    % 
    % ie: refuse a stream and then a headers frame pops down.
    % we always need to make sure we decode headers with zlib no matter what or the zlib
    % dictionaries will get out of sync which will break ALL subsequent SYN or HEADER
    % frames.

    .
        

refuse_new_connects_after_sending_goaway_tst() ->
    Socket = start_socket(server),
    Channel = start_channel_one(Socket),
    espdy_server:graceful_close(Socket),
    
    GoAway = receive_control_frame(),
    
    
    ?assertMatch({error, closed_not_processed}, espdy_server:connect(Socket)).
    

refuse_new_accepts_after_sending_goaway_tst() ->
    Socket = start_socket(server),
    Channel = start_channel_one(Socket),
    espdy_server:graceful_close(Socket),
    
    GoAway = receive_control_frame(),
    
    ?assertMatch({error, closed}, espdy_server:accept(Socket)).
    
refuse_new_connections_after_receiving_goaway_tst() ->
    Socket = start_socket(server),
    Channel = start_channel_one(Socket),
    send_frame(Socket, espdy_frame:encode_goaway(1)),


    ?assertMatch({error, closed_not_processed}, espdy_server:connect(Socket)).
    
connect_and_recv_tst() ->
    Socket = start_socket(server),
    {ok, Channel} = espdy_server:connect(Socket),
    SynStream = espdy_frame:decode_control_frame(receive_control_frame()),
    ?assertMatch(#syn_stream{associated_stream_id = 0, stream_id = 2, flags = 0, headers = []}, SynStream),    
    send_frame(Socket, espdy_frame:encode_data_frame(Channel#espdy_socket.stream_id, 0, <<"hello">>)),
    ?assertEqual(<<"hello">>, espdy_server:recv(Channel, 5)).

connect_and_send_syn_fin_tst() ->
    Socket = start_socket(server),
    Headers = [{<<"hello">>, [<<"world">>]}],
    {ok, Channel} = espdy_server:connect(Socket, true, Headers),
    SynStream = espdy_frame:decode_control_frame(receive_control_frame()),
    ?assertMatch(#syn_stream{associated_stream_id = 0, stream_id = 2, flags = ?FLAG_FIN, headers = Headers}, SynStream),
    ?assertEqual({error, closed}, espdy_server:send(Channel, <<"more_data">>)).
    
connect_for_push_and_get_error_closed_when_recving_tst() ->
    Socket = start_socket(server),
    ChannelOne = start_channel_one(Socket),
    Headers = [{<<"hello">>, [<<"world">>]}],
    
    {ok, Channel} = espdy_server:connect_for_push(ChannelOne, false, Headers),
    SynStream = espdy_frame:decode_control_frame(receive_control_frame()),
    ?assertMatch(#syn_stream{associated_stream_id = 1, stream_id = 2, flags = ?FLAG_UNIDIRECTIONAL, headers = Headers}, SynStream),
    ?assertEqual({error, closed}, espdy_server:recv(Channel, <<"more_data">>)).
        
run_ping(Role, ID) ->
    Socket = start_socket(Role),
    Frame = espdy_frame:encode_ping(ID),
    send_frame(Socket, Frame),

    ?assertEqual(Frame, receive_packet()).

run_receive_ping(Role, ID) ->
    Socket = start_socket(Role),
    Frame = espdy_frame:encode_ping(ID),
    send_frame(Socket, Frame),
    
    assert_dont_receive_packet().

    
server_ping_tst() ->

    run_ping(server, 1).
    
client_ping_tst() ->

    run_ping(client, 2).

server_receive_ping_reply_tst() ->

    run_receive_ping(server, 2).
    
client_receive_ping_reply_tst() ->

    run_receive_ping(client, 1).

unknown_cast_tst() ->
    gen_server:cast(start_socket(server), lols).
    
unknown_call_tst() ->
    ?assertEqual({error, unknown_call}, gen_server:call(start_socket(server), lols, infinity)).
    
code_change_test() ->
    ?assertEqual({ok, state}, espdy_server:code_change(old_vsn, state, extra)).
    