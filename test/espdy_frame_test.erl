-module(espdy_frame_test).
-include_lib("eunit/include/eunit.hrl").
-include("espdy_frame.hrl").

decode_name_value_header_block_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(2), 
        ?UINT16(5), "name1", ?UINT16(4), "valu",  
        ?UINT16(4), "nam2", ?UINT16(3), "val"
        >>),
    ?assertEqual(lists:sort([{<<"name1">>, [<<"valu">>]}, {<<"nam2">>, [<<"val">>]}]), lists:sort(Headers)).

decode_name_value_header_block_with_empty_value_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(1),
        ?UINT16(5), "name1", ?UINT16(0)
        >>),
    ?assertMatch({error, _Reason}, Headers).
    
decode_name_value_header_block_with_multiple_values_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(1),
        ?UINT16(5), "name1", ?UINT16(3), "h", 0, "i"
        >>),
    ?assertEqual([{<<"name1">>, [<<"h">>, <<"i">>]}], Headers).
     
decode_name_value_when_starting_with_null_value_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(1),
        ?UINT16(5), "name1", ?UINT16(2), 0, "h"
        >>),
    ?assertMatch({error, _Reason}, Headers).

decode_name_value_when_ending_with_null_value_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(1),
        ?UINT16(5), "name1", ?UINT16(2), "h", 0
        >>),
    ?assertMatch({error, _Reason}, Headers).
    
decode_name_value_when_ending_with_null_value2_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(1),
        ?UINT16(5), "name1", ?UINT16(4), "foo", 0
        >>),
    ?assertMatch({error, _Reason}, Headers).
    
decode_name_value_with_empty_value_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(1),
        ?UINT16(5), "name1", ?UINT16(4), "h", 0, 0, "i"
        >>),
    ?assertMatch({error, _Reason}, Headers).
    
decode_name_value_with_empty_header_name_test() ->
    Headers = espdy_frame:decode_name_value_header_block(<<
        ?UINT16(1),
        ?UINT16(0), ?UINT16(5), "hello"
        >>),
    ?assertMatch({error, _Reason}, Headers).
    
encode_name_value_header_block_test() ->
    Frame = espdy_frame:encode_name_value_header_block([{<<"hello">>, [<<"world">>]}, {<<"foo">>, [<<"one">>, <<"two">>]}]),
    Expected = <<?UINT16(2), ?UINT16(5), "hello", ?UINT16(5), "world", ?UINT16(3), "foo", ?UINT16(7), "one", 0, "two">>,
    ?assertEqual(Expected, Frame).
    
encode_name_value_header_block_with_empty_test() ->
    Frame = espdy_frame:encode_name_value_header_block([{<<"hello">>, []}]),
    Expected = <<?UINT16(1), ?UINT16(5), "hello", ?UINT16(0)>>,
    ?assertEqual(Expected, Frame).

encode_name_value_header_block_with_empty_value_test() ->
    ?assertException(throw, empty_header_value, espdy_frame:encode_name_value_header_block([{<<"hello">>, [<<>>]}])).


encode_then_decode_compressed_name_value_header_block_test() ->
    ZLibDeflate = espdy_frame:initialize_zlib_for_deflate(),
    Frame = list_to_binary(espdy_frame:encode_name_value_header_block(ZLibDeflate, [{<<"host">>, [<<"hostname">>]}])),
    ZLibInflate = espdy_frame:initialize_zlib_for_inflate(),
    Headers = espdy_frame:decode_name_value_header_block(ZLibInflate, Frame),
    ?assertEqual([{<<"host">>, [<<"hostname">>]}], Headers).
    
    
decode_ping_frame_test() ->
    Frame = espdy_frame:encode_ping(1),
    {DecodedFrame, Data} = espdy_frame:read_frame(<<>>, Frame),
    ?assertEqual(<<>>, Data),
    ?assertEqual(#control_frame{version = ?SPDY_VERSION, type = ?PING, flags = 0, data = <<0,0,0,1>>}, DecodedFrame).
    
decode_split_ping_frame_test() ->
    Frame = espdy_frame:encode_ping(1),
    <<Part1:2/binary, Part2/binary>> = Frame,
    {DecodedFrame, Data} = espdy_frame:read_frame(Part1, Part2),
    ?assertEqual(<<>>, Data),
    ?assertEqual(#control_frame{version = ?SPDY_VERSION, type = ?PING, flags = 0, data = <<0,0,0,1>>}, DecodedFrame).
       
chrome_frame_test() ->
    Buffer = <<128,2,0,1,1,0,1,31,0,0,0,1,0,0,0,0,0,0,56,234,223,162,81,178,98,224,102,96,131,164,23,6,123,184,11,117,48,44,214,174,64,23,205,205,177,46,180,53,208,179,212,209,210,215,2,179,44,24,248,80,115,44,131,156,103,176,63,212,61,58,96,7,129,213,153,235,64,212,27,51,240,163,229,105,6,65,144,139,117,160,78,214,41,78,73,206,128,171,129,37,3,6,190,212,60,221,208,96,157,212,60,168,165,188,40,137,141,129,19,26,36,182,6,12,44,160,220,207,192,9,74,34,57,96,38,91,46,176,192,201,79,97,96,118,119,13,97,96,43,6,106,203,77,5,170,42,41,41,96,96,6,133,5,163,62,3,23,34,3,51,148,250,230,87,101,230,228,36,234,155,234,25,40,104,0,228,155,152,156,153,87,146,95,156,97,173,224,9,76,83,57,10,64,1,5,255,96,133,8,5,67,131,120,243,120,3,77,5,71,96,240,164,134,167,38,121,103,150,232,155,26,155,234,25,42,104,120,123,132,248,250,232,40,228,100,102,167,42,184,167,38,103,231,107,42,56,103,0,203,165,84,125,67,19,61,160,235,129,170,128,101,131,66,112,98,90,98,81,38,68,19,3,59,52,118,24,56,96,145,6,0,0,0,255,255>> ,
    {Frame, <<>>} = espdy_frame:decode_frame(Buffer),
    DecodedFrame = espdy_frame:decode_control_frame(Frame).
    
encode_two_syn_replies_test() ->
    Headers = [
        {<<"status">>, [<<"200 OK">>]},
        {<<"version">>, [<<"HTTP/1.1">>]}
    ],
    
    ZLib = espdy_frame:initialize_zlib_for_deflate(),
    Syn1 = espdy_frame:encode_syn_reply(ZLib, 1, 0, Headers),
    
    Syn2 = espdy_frame:encode_syn_reply(ZLib, 3, 0, Headers),
    
    Inflate = espdy_frame:initialize_zlib_for_inflate(),
    
    DecodeFrame1 = espdy_frame:decode_exactly_one_frame(Syn1),
    Syn1Decoded = espdy_frame:decode_control_frame(Inflate, DecodeFrame1),
    
    DecodeFrame2 = espdy_frame:decode_exactly_one_frame(Syn2),
    Syn2Decoded = espdy_frame:decode_control_frame(Inflate, DecodeFrame2).
    
decode_our_headers_test() ->
    ZLib = espdy_frame:initialize_zlib_for_inflate(),
    Buffer = <<128,2,0,2,0,0,0,39,0,0,0,1,0,0,120,187,223,162,81,178,98,96,98,96,131,8,50,176,1,19,171,130,191,55,3,59,84,154,129,3,166,11,0,0,0,255,255>>,
    Frame = espdy_frame:decode_exactly_one_frame(Buffer),
    DecodedFrame = espdy_frame:decode_control_frame(ZLib, Frame),
    
    Buffer2 = <<128,2,0,2,0,0,0,14,0,0,0,3,0,0,34,74,17,0,0,0,255,255>>,
    Frame2= espdy_frame:decode_exactly_one_frame(Buffer2),
    DecodedFrame2 = espdy_frame:decode_control_frame(ZLib, Frame2).
        

