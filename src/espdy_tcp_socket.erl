-module(espdy_tcp_socket, [Socket]).

-export([send/1, close/0, shutdown/0, setopts/1, controlling_process/1, data_tag/0, error_tag/0, close_tag/0]).

close_tag() ->
    tcp_closed.

error_tag() ->
    tcp_error.
    
data_tag() ->
    tcp.
    
send(Packet) ->
    gen_tcp:send(Socket, Packet).

close() ->
    gen_tcp:close(Socket).

setopts(Options) ->
    inet:setopts(Socket, Options).

shutdown() ->
    gen_tcp:shutdown(Socket).
 
controlling_process(Pid) ->
    gen_tcp:controlling_process(Socket, Pid).  