#Status

This project is still very alpha. Enough of the protocol has been implemented to view pages in google chrome. Check out espdy_test_server.erl

#Running
1. /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --use-spdy=ssl
2. make compile
3. ./test_server
4. http://localhost:8443

# {active, false} socket like API
This makes the code much more complicated :( and I'm wondering if it is worth having. If you use a callback module or {active, true} style message sending
then the code becomes much simpler.

However, {active, false} gives us flow control (with spdy/3) and really simple integration with erlang web frameworks that use tcp like sockets and do recv to process POSTs.

We also support multiple concurrent send() or recv() operations on the same stream which makes the code a little bit more complicated. I'm not sure how useful this behaviour is because you have to make sure you are send()'ing and recv()'ing atomic blocks for it to be useful otherwise you might interleave messages corrupting the stream. gen_tcp supports this behaviour. i'm not sure if the ssl module supports this behaviour.

#Issues

## NPN Support in Erlang

There is no NPN support for SSL in Erlang. I'm currently working on a patch to fix this. Whether Erlang
would accept a patch for a draft extensions is another question.

## Write Queueing

We queue up writes in a write process. If the reader at the other end is not reading data fast enough then our write process will start consuming lots of memory. We need to kill off connections that are misbehaving. send() calls block until the write has returned so there is _some_ flow control on the send() side. once the os buffer has filled up send() will start blocking. however, we will send data in response to PING and protocol errors and it is possible a misbehaving client could trick us into allocating lots of memory for the write queue. 

## Read Buffering

There is no flow control in spdy draft 2. When we receive data we add it to a buffer. We keep adding data to the buffer. If we receive data faster than we are recv()'ing it then we can start chewing up memory. The plan is to add a max_recv_buffer setting and to stop reading from the socket if this limit is met.

## Goaway Implementation

We don't correctly send {error, closed_not_processed} in a lot of places. This hasn't been implemented in send/recv. Also, we kill the gen_server too early and a client may receive {error, closed} because the gen_server is not around instead of {error, closed_not_processed}.

## No settings

Have not implemented sending or receiving of the settings frame.

## Partial implementation of headers

No support for receiving header frames. I'm not sure how this would look in the api :(

## StreamId limit

No support for stopping connections when the StreamId limit has been reached 

## Not checking version

We are currently not checking the version field on control or data frames :(

## No backlimit for accepts

We continue to add connections to the accept buffer without bound.

## Communicating errors back to the client

If a client isn't send'ing or recv'ing on a stream then they won't receive error notifications about previous failed sends. I think this is how unix
tcp works so i don't think it is that terrible :). However, the spdy http protocol is the client writes to the server and then half-closes, then the 
server writes to the client and then half-closes. There is no server waiting for an ack from the client. If the servers response to the client is not
received it will not be aware of this. I'm not sure how big of a problem this is. Generally http servers don't care if they fail to deliver a response
to the client.

## No chunking of sends

If you do a large send() then it will block all the other channels using the spdy socket. We should probably chunk sends() to a reasonable value.

# Code duplication 

There is some code duplication between espdy_server and espdy_frame for control frame decoding

