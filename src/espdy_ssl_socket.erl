-module(espdy_ssl_socket, [Socket]).

-export([send/1, close/0, shutdown/0, setopts/1, controlling_process/1, data_tag/0, close_tag/0, error_tag/0]).

data_tag() ->
    ssl.
    
close_tag() ->
    ssl_closed.

error_tag() ->
    ssl_error.
    
send(Packet) ->
    ssl:send(Socket, Packet).

close() ->
    ssl:close(Socket).

setopts(Options) ->
    ssl:setopts(Socket, Options).

shutdown() ->
    ssl:shutdown(Socket).
 
controlling_process(Pid) ->
    ssl:controlling_process(Socket, Pid).