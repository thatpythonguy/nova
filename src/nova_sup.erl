%%% @author Niclas Axelsson <niclas@burbas.se>
%%% @doc
%%% Nova supervisor
%%% @end

-module(nova_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").
-include("../include/nova.hrl").

-define(SERVER, ?MODULE).
-define(NOVA_LISTENER, nova_listener).
-define(NOVA_STD_PORT, 8080).
-define(NOVA_STD_SSL_PORT, 8443).


%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Error :: any()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart intensity, and child
%% specifications.
%%
%% @end
%%--------------------------------------------------------------------
init([]) ->
    %% This is a bit ugly, but we need to do this anyhow(?)
    SupFlags = #{strategy => one_for_one,
                 intensity => 1,
                 period => 5},

    Environment = nova:get_environment(),

    nova_pubsub:start(),

    ?LOG_NOTICE(#{msg => <<"Starting nova">>, environment => Environment}),

    Configuration = application:get_env(nova, cowboy_configuration, #{}),

    SessionManager = application:get_env(nova, session_manager, nova_session_ets),

    Children = [
                child(nova_handlers, nova_handlers),
                child(SessionManager, SessionManager),
                child(nova_watcher, nova_watcher)
               ],

    setup_cowboy(Configuration),


    {ok, {SupFlags, Children}}.




%%%===================================================================
%%% Internal functions
%%%===================================================================
child(Id, Type, Mod, Args) ->
    #{id => Id,
      start => {Mod, start_link, Args},
      restart => permanent,
      shutdown => 5000,
      type => Type,
      modules => [Mod]}.

child(Id, Type, Mod) ->
    child(Id, Type, Mod, []).

child(Id, Mod) ->
    child(Id, worker, Mod).

setup_cowboy(Configuration) ->
    case start_cowboy(Configuration) of
        {ok, App, Host, Port} ->
            Host0 = inet:ntoa(Host),
            CowboyVersion = get_version(cowboy),
            NovaVersion = get_version(nova),
            UseStacktrace = application:get_env(nova, use_stacktrace, false),
            persistent_term:put(nova_use_stacktrace, UseStacktrace),
            ?LOG_NOTICE(#{msg => <<"Nova is running">>,
                          url => unicode:characters_to_binary(io_lib:format("http://~s:~B", [Host0, Port])),
                          cowboy_version => CowboyVersion, nova_version => NovaVersion, app => App});
        {error, Error} ->
            ?LOG_ERROR(#{msg => <<"Cowboy could not start">>, reason => Error})
    end.

-spec start_cowboy(Configuration :: map()) ->
          {ok, BootstrapApp :: atom(), Host :: string() | {integer(), integer(), integer(), integer()},
           Port :: integer()} | {error, Reason :: any()}.
start_cowboy(Configuration) ->
    Middlewares = [
                   nova_router, %% Lookup routes
                   nova_plugin_handler, %% Handle pre-request plugins
                   nova_security_handler, %% Handle security
                   nova_handler, %% Controller
                   nova_plugin_handler %% Handle post-request plugins
                  ],
    StreamH = [nova_stream_h,
               cowboy_compress_h,
               cowboy_stream_h],
    StreamHandlers = maps:get(stream_handlers, Configuration, StreamH),
    MiddlewareHandlers = maps:get(middleware_handlers, Configuration, Middlewares),
    Options = maps:get(options, Configuration, #{compress => true}),

    %% Build the options map
    CowboyOptions1 = Options#{middlewares => MiddlewareHandlers,
                              stream_handlers => StreamHandlers},

    BootstrapApp = application:get_env(nova, bootstrap_application, undefined),

    %% Compile the routes
    Dispatch =
        case BootstrapApp of
            undefined ->
                ?LOG_ERROR(#{msg => <<"You need to define bootstrap_application option in configuration">>}),
                throw({error, no_nova_app_defined});
            App ->
                ExtraApps = application:get_env(App, nova_apps, []),
                nova_router:compile([nova|[App|ExtraApps]])
        end,

    CowboyOptions2 =
        case application:get_env(nova, use_persistent_term, true) of
            true ->
                CowboyOptions1;
            _ ->
                CowboyOptions1#{env => #{dispatch => Dispatch}}
        end,

    Host = maps:get(ip, Configuration, { 0, 0, 0, 0}),

    case maps:get(use_ssl, Configuration, false) of
        false ->
            Port = maps:get(port, Configuration, ?NOVA_STD_PORT),
            case cowboy:start_clear(
                   ?NOVA_LISTENER,
                   [{port, Port},
                    {ip, Host}],
                   CowboyOptions2) of
                {ok, _Pid} ->
                    {ok, BootstrapApp, Host, Port};
                Error ->
                    Error
            end;
        _ ->
            case maps:get(ca_cert, Configuration, undefined) of
                undefined ->
                    Port = maps:get(ssl_port, Configuration, ?NOVA_STD_SSL_PORT),
                    SSLOptions = maps:get(ssl_options, Configuration, #{}),
                    TransportOpts = maps:put(port, Port, SSLOptions),
                    TransportOpts1 = maps:put(ip, Host, TransportOpts),

                    case cowboy:start_tls(
                           ?NOVA_LISTENER, maps:to_list(TransportOpts1), CowboyOptions2) of
                        {ok, _Pid} ->
                            ?LOG_NOTICE(#{msg => <<"Nova starting SSL">>, port => Port}),
                            {ok, BootstrapApp, Host, Port};
                        Error ->
                            ?LOG_ERROR(#{msg => <<"Could not start cowboy with SSL">>, reason => Error}),
                            Error
                    end;
                CACert ->
                    Cert = maps:get(cert, Configuration),
                    Port = maps:get(ssl_port, Configuration, ?NOVA_STD_SSL_PORT),
                    ?LOG_DEPRECATED(<<"0.10.3">>, <<"Use of use_ssl is deprecated, use ssl instead">>),
                    case cowboy:start_tls(
                           ?NOVA_LISTENER, [
                                            {port, Port},
                                            {ip, Host},
                                            {certfile, Cert},
                                            {cacertfile, CACert}
                                           ],
                           CowboyOptions2) of
                        {ok, _Pid} ->
                            ?LOG_NOTICE(#{msg => <<"Nova starting SSL">>, port => Port}),
                            {ok, BootstrapApp, Host, Port};
                        Error ->
                            Error
                    end
            end
    end.



get_version(Application) ->
    case lists:keyfind(Application, 1, application:loaded_applications()) of
        {_, _, Version} ->
            erlang:list_to_binary(Version);
        false ->
            not_found
    end.
