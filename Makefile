rebar ?= ./rebar3
rebar_cmd = $(rebar) $(profile:%=as %)

compile:
	@$(rebar_cmd) compile

clean:
	@$(rebar_cmd) clean
	-@rm -rf *.dump 2>/dev/null
	-@rm -rf src/*.dump 2>/dev/null
	-@rm -rf src/*.beam 2>/dev/null

start: compile
	erl -name mole0@127.0.0.1 -setcookie moles -pa _build/default/lib/*/ebin -s moles_app

service: compile
	erl -name mole0@127.0.0.1 -setcookie moles -pa _build/default/lib/*/ebin -noshell -detached -s moles_app &
