compile:
	./rebar compile

eunit:
	./rebar skip_deps=true eunit

run:
	erl -pa ebin -pa deps/lager/ebin -s espdy_test_server

.PHONY: eunit compile
