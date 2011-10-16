-module(espdy_mock_socket, [PacketReceiver]).

-export([send/1, close/0, shutdown/0, setopts/1, controlling_process/1, data_tag/0, error_tag/0, close_tag/0]).

close_tag() ->
    tcp_closed.

error_tag() ->
    tcp_error.
    
data_tag() ->
    tcp.
    
send(Packet) ->
    PacketReceiver ! {packet, self(), Packet},
    receive
        {mock_packet_result, Result} -> Result
    end.

close() ->
    ok.

setopts(Options) ->
    ok.
    
shutdown() ->
    ok.
    
controlling_process(Pid) ->
    ok.