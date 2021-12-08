-module(nova_error_controller).
-export([
         not_found/1,
         server_error/1
        ]).

not_found(_Req) ->
    Variables = #{status => "Could not find the page you were looking for",
                  title => "404 Not found",
                  message => "We could not find the page you were looking for"},
    {ok, Body} = nova_error:render(Variables),
    {status, 404, #{}, Body}.

server_error(#{crash_info := #{stacktrace := Stacktrace, class := Class, reason := Reason}}) ->
    Variables = #{status => "Internal Server Error",
                  title => "500 Internal Server Error",
                  message => "Something internal crashed. Please take a look!",
                  extra_msg => io_lib:format("~p, ~p", [Class, Reason]),
                  stacktrace => Stacktrace}, #{view => nova_error},
    {ok, Body} = nova_error:render(Variables),
    {status, 500, #{}, Body}.
