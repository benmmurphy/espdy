-define(BYTE(X),     (X):8/unsigned-big-integer).
-define(UINT16(X),   (X):16/unsigned-big-integer).
-define(UINT24(X),   (X):24/unsigned-big-integer).
-define(UINT32(X),   (X):32/unsigned-big-integer).
-define(UINT64(X),   (X):64/unsigned-big-integer).

-define(NOOP, 5).
-define(PING, 6).
-define(SYN_STREAM, 1).
-define(SYN_REPLY, 2).
-define(RST_STREAM, 3).
-define(HEADERS, 8).
-define(GOAWAY, 7).

-define(SPDY_VERSION, 2).
-define(CONTROL_FRAME, 1:1/unsigned-big-integer).
-define(DATA_FRAME, 0:1/unsigned-big-integer).
-define(TYPE(X), (X):16/unsigned-big-integer).
-define(VERSION(X), (X):15/unsigned-big-integer).
-define(LENGTH(X), ?UINT24(X)).
-define(FLAGS(X), ?BYTE(X)).
-define(RESERVED_BIT, _:1).
-define(MAKE_RESERVED_BIT, 0:1).
-define(STREAM_ID(X), (X):31/unsigned-big-integer).
-define(PRIORITY(X), (X):2/unsigned-big-integer).
-define(UNUSED(X), _:(X)).
-define(MAKE_UNUSED(X), 0:(X)).

-define(UNUSED_SYN_REPLY, 16).
-define(UNUSED_SYN_STREAM, 14).
-define(UNUSED_HEADERS, 16).

-define(FLAG_FIN, 1).
-define(FLAG_UNIDIRECTIONAL, 2).

%% RST_STREAM STATUSES
-define(PROTOCOL_ERROR, 1).
-define(INVALID_STREAM, 2).
-define(REFUSED_STREAM, 3).
-define(UNSUPPORTED_VERSION, 4).
-define(CANCEL, 5).
-define(FLOW_CONTROL_ERROR, 6).
-define(STREAM_IN_USE, 7).
-define(STREAM_ALREADY_CLOSED, 8).

-record(control_frame, {version, type, flags, data}).
-record(rst_stream, {stream_id, status}).
-record(headers, {headers, stream_id}).
-record(data_frame, {stream_id, flags, data}).
-record(syn_reply, {stream_id, flags, headers}).
-record(syn_stream, {stream_id, flags, headers, associated_stream_id}).
-record(goaway, {last_good_stream_id}).
-record(noop, {}).
