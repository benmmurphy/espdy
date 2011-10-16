-module(espdy_frame).
-include("espdy_frame.hrl").
-compile([{parse_transform, lager_transform}]).


-export([decode_name_value_header_block/1, encode_name_value_header_block/1, 
         decode_name_value_header_block/2, encode_name_value_header_block/2,
         initialize_zlib_for_deflate/0, initialize_zlib_for_inflate/0,dictionary/0,
         read_frame/2, encode_ping/1,
         encode_syn_stream/6,
         encode_syn_stream/5,
         encode_syn_stream_with_raw_uncompressed_name_value_pairs/5,
         encode_data_frame/3,
         encode_rst_stream/2,
         encode_headers/3,
         encode_headers_with_raw_uncompressed_name_value_pairs/3,
         encode_headers_with_raw_uncompressed_name_value_pairs/4,
         encode_headers/4,
         encode_syn_reply/3,
         encode_syn_reply/4,
         encode_noop/0,
         encode_goaway/1,
         decode_exactly_one_frame/1,
         decode_control_frame/1,
         decode_control_frame/2,
         encode_control_frame/3,
         decode_frame/1]).

read_frame(Buffer, <<>>) ->
    decode_frame(Buffer);
read_frame(<<>>, Data) ->
    decode_frame(Data);
read_frame(Buffer, Data) ->
    decode_frame(<<Buffer/binary, Data/binary>>).
    
decode_frame(<<?CONTROL_FRAME, Version:15, Type:16, Flags:8, Length:24, Data:Length/binary, Rest/binary>>) ->
    {#control_frame{version = Version, type = Type, flags = Flags, data = Data}, Rest};
decode_frame(<<?DATA_FRAME, StreamID:31, Flags:8, Length:24, Data:Length/binary, Rest/binary>>) ->
    {#data_frame{stream_id = StreamID, flags = Flags, data = Data}, Rest};
decode_frame(Data) ->
    Data.

decode_exactly_one_frame(Data) ->
    {Frame, <<>>} = decode_frame(Data),
    Frame.


decode_control_frame(Frame) ->
    ZLib = initialize_zlib_for_inflate(),
    ControlFrame = decode_control_frame(ZLib, Frame),
    zlib:close(ZLib),
    ControlFrame.
   

decode_control_frame(_ZLib, #control_frame{type = ?GOAWAY, data = 
        <<?RESERVED_BIT, ?STREAM_ID(LastGoodStreamId)>>}) ->
    #goaway{last_good_stream_id = LastGoodStreamId};
    
decode_control_frame(_ZLib, #control_frame{type = ?RST_STREAM, data =
        <<?RESERVED_BIT, ?STREAM_ID(StreamId), ?UINT32(StatusCode)>>}) ->
    #rst_stream{stream_id = StreamId, status = StatusCode};

    
decode_control_frame(_ZLib, #control_frame{type = ?NOOP, data = <<>>}) ->
    #noop{};
        
decode_control_frame(ZLib, #control_frame{type = ?HEADERS, data =
        <<?RESERVED_BIT, ?STREAM_ID(StreamId), 
          ?UNUSED(?UNUSED_HEADERS),
          NameValueHeaderBlock/binary>>}) ->
    Headers = decode_name_value_header_block(ZLib, NameValueHeaderBlock),
    #headers{stream_id = StreamId, headers = Headers};
          
decode_control_frame(ZLib, #control_frame{flags = Flags, type = ?SYN_REPLY, data = 
        <<?RESERVED_BIT, ?STREAM_ID(StreamId), 
          ?UNUSED(?UNUSED_SYN_REPLY), 
          NameValueHeaderBlock/binary>>}) ->
    Headers = decode_name_value_header_block(ZLib, NameValueHeaderBlock),
    #syn_reply{flags = Flags, stream_id = StreamId, headers = Headers};

decode_control_frame(ZLib, #control_frame{flags = Flags, type = ?SYN_STREAM, data = 
            <<?RESERVED_BIT, ?STREAM_ID(StreamId), 
              ?RESERVED_BIT, ?STREAM_ID(AssociatedToStreamId),
              ?PRIORITY(_Priority), ?UNUSED(?UNUSED_SYN_STREAM), 
              NameValueHeaderBlock/binary>>}) ->
    Headers = decode_name_value_header_block(ZLib, NameValueHeaderBlock),
    #syn_stream{flags = Flags, stream_id = StreamId, headers = Headers, associated_stream_id = AssociatedToStreamId}.
    
validate_valid_values(Pairs) ->
    fold_error(fun validate_value/1, Pairs).

validate_value({_Name, <<>>}) ->
    {error, empty_value};
validate_value({_Name, <<0, _Rest/binary>>}) ->
    {error, value_starts_with_null};    
validate_value({_Name, Value}) ->
    case binary:last(Value) =:= 0 of
        true -> {error, value_ends_with_null};
        _ ->
            case binary:match(Value, <<0,0>>) of
                nomatch -> ok;
                _ -> {error, empty_value}
            end
    end.

    
validate_no_dups(Pairs) ->
    SortedPairs = lists:ukeysort(1, Pairs),
    case length(SortedPairs) =:= length(Pairs) of 
        true -> ok;
        false -> {error, duplicate_header_names}
    end.

expand_headers(Pairs) ->
    lists:map(fun expand_header/1, Pairs).

expand_header({Name, <<>>}) ->
    {Name, []};
expand_header({Name, Value}) ->
    Values = binary:split(Value, <<0>>),
    {Name, Values}.
 
chain_validations([], _Data) ->
    ok;
chain_validations([F|Rest], Data) ->
    case F(Data) of
        ok -> chain_validations(Rest, Data);
        Error -> Error
    end.
    
fold_error(_Fun, []) ->
    ok;
fold_error(Fun, [H|Rest]) ->
    case Fun(H) of
        ok -> fold_error(Fun, Rest);
        Error -> Error
    end.

validate_headers_names_valid(Pairs) ->
    fold_error(fun validate_headers_name_valid/1, Pairs).

validate_headers_name_valid({<<>>, _Value}) ->
    {error, empty_header_name};
validate_headers_name_valid(_) ->
    ok.
    
make_headers(Pairs) ->
    case chain_validations([fun validate_no_dups/1, fun validate_valid_values/1, fun validate_headers_names_valid/1], Pairs) of
        ok -> 
            expand_headers(Pairs);        
        Error -> Error
    end.

decode_name_value_header_block(ZLib, Binary) ->
    Iodata = 
    try
        zlib:inflate(ZLib, Binary)
    catch 
        error : {need_dictionary,3751956914} ->
            zlib:inflateSetDictionary(ZLib, dictionary()), 
            zlib:inflate(ZLib, [])
    end,
    decode_name_value_header_block(list_to_binary(Iodata)).

encode_name_value_header_block(ZLib, NameValuePairs) ->
    Binary = encode_name_value_header_block(NameValuePairs),
    zlib:deflate(ZLib, Binary, sync).
    
encode_name_value_header_block(NameValuesPairs) ->
    lists:foldl(fun (E, Acc) -> <<Acc/binary, (encode_name_values(E))/binary>> end, 
        <<?UINT16((length(NameValuesPairs)))>>,
        NameValuesPairs).

encode_name_values({Name, Values}) ->
    EncodedValues = encode_values(Values),
    <<?UINT16((byte_size(Name))), Name/binary, ?UINT16((byte_size(EncodedValues))), EncodedValues/binary>>.

encode_values(Values) ->
    lists:foldl(
        fun (<<>>, _) ->
            throw(empty_header_value);
            (E, <<>>) -> 
            <<E/binary>>;
           (E, Acc) ->
            <<Acc/binary, 0, E/binary>>
        end, 
    <<>>, Values).
         
decode_name_value_header_block(<<?UINT16(NumberOfNameValuePairs), Repeats/binary>>) ->
    make_headers(decode_name_value(Repeats, NumberOfNameValuePairs, [])).

decode_name_value(_Binary, 0, Acc) ->
    Acc;
decode_name_value(Binary0, N, Acc) ->
    {Value, Binary} = decode_name_value(Binary0),
    decode_name_value(Binary, N - 1, [Value | Acc]).

decode_name_value(<<?UINT16(NameLength), Name:NameLength/binary, ?UINT16(ValueLength), Value:ValueLength/binary, Rest/binary>>) ->
     {{Name, Value}, Rest}.

dictionary() ->
    <<"optionsgetheadpostputdeletetraceacceptaccept-charsetaccept-encodingaccept-"
    "languageauthorizationexpectfromhostif-modified-sinceif-matchif-none-matchi"
    "f-rangeif-unmodifiedsincemax-forwardsproxy-authorizationrangerefererteuser"
    "-agent10010120020120220320420520630030130230330430530630740040140240340440"
    "5406407408409410411412413414415416417500501502503504505accept-rangesageeta"
    "glocationproxy-authenticatepublicretry-afterservervarywarningwww-authentic"
    "ateallowcontent-basecontent-encodingcache-controlconnectiondatetrailertran"
    "sfer-encodingupgradeviawarningcontent-languagecontent-lengthcontent-locati"
    "oncontent-md5content-rangecontent-typeetagexpireslast-modifiedset-cookieMo"
    "ndayTuesdayWednesdayThursdayFridaySaturdaySundayJanFebMarAprMayJunJulAugSe"
    "pOctNovDecchunkedtext/htmlimage/pngimage/jpgimage/gifapplication/xmlapplic"
    "ation/xhtmltext/plainpublicmax-agecharset=iso-8859-1utf-8gzipdeflateHTTP/1"
    ".1statusversionurl", 0>>.
    
    
initialize_zlib_for_deflate() ->
    Z = zlib:open(),
    zlib:deflateInit(Z, default, deflated, 15, 8, default),
    zlib:deflateSetDictionary(Z, dictionary()),
    Z.
    
initialize_zlib_for_inflate() ->
    Z = zlib:open(),
    zlib:inflateInit(Z, 15),
    Z.

encode_data_frame(StreamId, Flags, Data) ->
    <<?DATA_FRAME, ?STREAM_ID(StreamId), ?FLAGS(Flags), ?LENGTH(byte_size(Data)), Data/binary>>.
    
encode_control_frame(Type, Flags, Data) ->
    <<?CONTROL_FRAME, ?VERSION(?SPDY_VERSION), ?TYPE(Type), ?FLAGS(Flags), ?LENGTH(byte_size(Data)), Data/binary>>.

encode_noop() ->
    encode_control_frame(?NOOP, 0, <<>>).
    
encode_goaway(LastStreamId) ->
    encode_control_frame(?GOAWAY, 0, <<?MAKE_RESERVED_BIT, ?STREAM_ID(LastStreamId)>>).
    
encode_ping(ID) ->
    encode_control_frame(?PING, 0, <<?UINT32(ID)>>).

encode_rst_stream(StreamId, StatusCode) ->
    encode_control_frame(?RST_STREAM, 0,
        <<0:1, ?STREAM_ID(StreamId),
          ?UINT32(StatusCode)>>).

encode_syn_stream_with_raw_uncompressed_name_value_pairs(Flags, StreamId, AssociatedToStreamId, Priority, RawBlock) ->
    ZLib = initialize_zlib_for_deflate(),
    NameValueHeaderBlock = list_to_binary(zlib:deflate(ZLib, RawBlock, sync)),
    encode_syn_stream_with_raw_name_value_pairs(Flags, StreamId, AssociatedToStreamId, Priority, NameValueHeaderBlock).
    
encode_syn_stream_with_raw_name_value_pairs(Flags, StreamId, AssociatedToStreamId, Priority, NameValueHeaderBlock) ->
    encode_control_frame(?SYN_STREAM, Flags,
        <<?MAKE_RESERVED_BIT, ?STREAM_ID(StreamId), 
          ?MAKE_RESERVED_BIT, ?STREAM_ID(AssociatedToStreamId),
          ?PRIORITY(Priority),
          ?MAKE_UNUSED(?UNUSED_SYN_STREAM),
          NameValueHeaderBlock/binary>>).
          
encode_syn_stream(Flags, StreamId, AssociatedToStreamId, Priority, NameValuePairs) ->
    ZLib = initialize_zlib_for_deflate(),
    Frame = encode_syn_stream(ZLib, Flags, StreamId, AssociatedToStreamId, Priority, NameValuePairs),
    zlib:close(ZLib),
    Frame.
    
encode_syn_stream(ZLib, Flags, StreamId, AssociatedToStreamId, Priority, NameValuePairs) ->
    NameValueHeaderBlock = list_to_binary(encode_name_value_header_block(ZLib, NameValuePairs)),
    encode_syn_stream_with_raw_name_value_pairs(Flags, StreamId, AssociatedToStreamId, Priority, NameValueHeaderBlock).

encode_syn_reply(StreamId, Flags, Headers) ->
    ZLib = initialize_zlib_for_deflate(),
    encode_syn_reply(StreamId, Flags, Headers),
    zlib:close(ZLib).
    
encode_syn_reply(ZLib, StreamId, Flags, Headers) ->
    NameValueHeaderBlock = list_to_binary(encode_name_value_header_block(ZLib, Headers)),
    Frame = <<
      ?MAKE_RESERVED_BIT, ?STREAM_ID(StreamId),
      ?MAKE_UNUSED(?UNUSED_SYN_REPLY),
      NameValueHeaderBlock/binary>>,
    encode_control_frame(?SYN_REPLY, Flags, Frame).

encode_headers(StreamId, Flags, Headers) ->
    ZLib = initialize_zlib_for_deflate(),
    Frame = encode_headers(ZLib, StreamId, Flags, Headers),
    zlib:close(ZLib), 
    Frame.
    
encode_headers_with_raw_uncompressed_name_value_pairs(ZLib, StreamId, Flags, Headers) ->
    encode_headers_with_compressed_name_value_header_block(StreamId, Flags, list_to_binary(zlib:deflate(ZLib, Headers, sync))).
       
encode_headers_with_raw_uncompressed_name_value_pairs(StreamId, Flags, Headers) ->
    ZLib = initialize_zlib_for_deflate(),
    Frame = encode_headers_with_raw_uncompressed_name_value_pairs(StreamId, Flags, Headers),
    zlib:close(ZLib), 
    Frame.

encode_headers(ZLib, StreamId, Flags, Headers) ->
    NameValueHeaderBlock = list_to_binary(encode_name_value_header_block(ZLib, Headers)),
    encode_headers_with_compressed_name_value_header_block(StreamId, Flags, NameValueHeaderBlock).
    
encode_headers_with_compressed_name_value_header_block(StreamId, Flags, NameValueHeaderBlock) ->
    Frame = <<
        ?MAKE_RESERVED_BIT, ?STREAM_ID(StreamId),
        ?MAKE_UNUSED(?UNUSED_HEADERS),
        NameValueHeaderBlock/binary>>,
    encode_control_frame(?HEADERS, Flags, Frame).