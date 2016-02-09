-module(slack_rtm_sup).

-export([start/2, stop/1]).

-export([init/1]).

-export([add_bot/1]).

start(_, _) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, root).

stop(_) ->
    ok.


init(root) ->
    Bots = case application:get_env(slack_rtm, token) of
        {ok, Token} -> [bot_spec(Token)];
        undefined -> []
    end,
    {ok, {{one_for_one, 10, 1}, Bots}}.


add_bot(Token) ->
    NormToken = binary_to_list(iolist_to_binary([Token])),
    supervisor:start_child(?MODULE, bot_spec(NormToken)).

bot_spec(Token) ->
    #{id => Token, start => {slack_rtm, start_link_bot, [Token]}}.
