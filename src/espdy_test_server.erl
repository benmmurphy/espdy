-module(espdy_test_server).
-compile([{parse_transform, lager_transform}]).

-export([start/0]).

start() ->
    lager:start(),
    lager:set_loglevel(lager_console_backend, debug),
    crypto:start(),
    ssl:start(),
    {ok, Listen} = ssl:listen(8443, [
        {keyfile, "server.key"}, 
        {certfile, "server.crt"},
        {reuseaddr, true},
        {ssl_imp, new},
        binary,
        {packet, raw},
        {active, false}
    ]),
    
    lager:info("Listening on port 80", []),
    
    loop(Listen).
    
loop(Listen) ->
    case ssl:transport_accept(Listen) of
        {ok, Socket} -> 
            case ssl:ssl_accept(Socket) of
                ok ->
                    spawn(fun() -> loop(Listen) end),
                    accept(Socket);
                {error, Reason} ->
                    lager:info("Error ssl_accept socket", [Reason]),
                    loop(Listen)
            end;
        {error, Reason} ->
            lager:info("Error accepting socket", [Reason]),
            loop(Listen)
    end.
    
accept(Socket) ->
    lager:info("Accepted Socket ~p", [Socket]),
    {ok, Pid} = espdy_server:start_link(espdy_ssl_socket:new(Socket), server),
    espdy_loop(Pid).
    
espdy_loop(Pid) ->
    {ok, Socket, Headers} = espdy_server:accept(Pid),
    spawn(fun() -> espdy_loop(Pid) end),
    espdy_accept(Socket, Headers).
 
get_header(Header, Headers) ->
    
    case lists:keyfind(Header, 1, Headers)  of
        {_, [Url]} -> {ok, Url};
        _ -> notfound
    end.
            
espdy_accept(Socket, Headers) ->
    io:format(user, "Headers ~p", [Headers]),
    ResponseHeaders = [
        {<<"status">>, [<<"200 OK">>]},
        {<<"version">>, [<<"HTTP/1.1">>]},
        {<<"Set-Cookie">>, [<<"cookie1=value1">>, <<"cookie2=value2">>]}
    ],
   
    
    case get_header(<<"url">>, Headers) of
        {ok, <<"/style.css">>} ->
            timer:sleep(1000),
            espdy_server:send_headers(Socket, ResponseHeaders),
            espdy_server:send(Socket, css_file1()),
            espdy_server:close(Socket);
        {ok, <<"/style2.css">>} ->
            espdy_server:send_headers(Socket, ResponseHeaders),
            timer:sleep(500),
            espdy_server:send(Socket, css_file2()),
            espdy_server:close(Socket);
        {ok, <<"/">>} ->
            espdy_server:send_headers(Socket, ResponseHeaders),
            {ok, Scheme} = get_header(<<"scheme">>, Headers),
            {ok, Host} = get_header(<<"host">>, Headers),
            Url = list_to_binary([Scheme, "://", Host, "/style3.css"]),
            
            PushHeaders = [{<<"status">>, <<"200 OK">>}, {<<"version">>, <<"HTTP/1.1">>}, {<<"url">>, Url}, {<<"content-type">>, <<"text/css">>}],
            {ok, PushSocket} = espdy_server:connect_for_push(Socket, false, simple_headers(PushHeaders)),
            espdy_server:send_and_close(PushSocket, css_file3()),
            espdy_server:send_and_close(Socket, html_page());
        _ ->
            espdy_server:send_headers(Socket, simple_headers([{<<"status">>, <<"404 Not Found">>}, {<<"version">>, <<"HTTP/1.1">>}])),
            espdy_server:close(Socket)
    end.

simple_header({Name, Value}) ->
    {Name, [Value]}.
    
simple_headers(Headers) ->
    lists:map(fun simple_header/1, Headers).
        
css_file1() ->
    <<".css1 {}">>.
css_file2() ->
    <<".css2 {}">>.
css_file3() ->
    <<".css3 {}">>.

    
html_page() ->
    <<"<html><head>"
    "<link rel='stylesheet' href='style.css'/>"
    " <link rel='stylesheet' href='style2.css'/>"
    "<link rel='stylesheet' href='style3.css'/>"
    "<script type='text/javascript'>"
    "function random_str(n) {"
    "  var buf = '';"
    "  for (var i = 0; i < n; ++i) {"
    "    buf += String.fromCharCode(Math.floor(Math.random() * 57) + 65);"
    "  }"
    "  return buf;"
    "}"
    "function send_large_header_request() {"
    "  var xhr = new XMLHttpRequest();"
    "  xhr.open('GET', '/foo');"
    "  for (var i = 0; i < 18; ++i) {"
    "    var ch = String.fromCharCode('a'.charCodeAt(0) + i);"
    "    xhr.setRequestHeader(ch, random_str(4094));"
    "  }"
    "  xhr.send()"
    "}"
    "</script>"
    "</head><body>hello from erlang"
    "<input type='button' onclick='send_large_header_request()' value='send large header packet'/>"
    "</body></html>">>.
    
