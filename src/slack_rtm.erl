-module(slack_rtm).

-export([start/0]).
-export([start_link/1, start_link_bot/1]).

-behaviour(websocket_client_handler).
-export([init/2, websocket_handle/3, websocket_info/3, websocket_terminate/3]).

-export([add_conf_reaction/3, get_conf_reactions/2, load_config/1]).
-export([nickname_to_ref/2]).

start() ->
    application:ensure_all_started(?MODULE).

start_link(Token) ->
    start(),
    start_link_bot(Token).

start_link_bot(Token) ->
    StartUrl = "https://slack.com/api/rtm.start?simple_latest=true&no_unreads=true&token=" ++ Token,
    {ok, "200", _, OpenResp} = ibrowse:send_req(StartUrl, [], post, <<>>, [{response_format, binary}]),
    OpenInfo = jsx:decode(OpenResp, [return_maps]),
    #{<<"ok">> := true, <<"url">> := RTMUrl, <<"self">> := Self} = OpenInfo,

    Slack0 = #{token => Token, config => #{}, config_ch_id => undefined,
               users => #{}, nicknames => #{}, channels => #{}, my_channels => [], self => parse_self(Self)},

    #{<<"users">> := UserList, <<"channels">> := ChannelList, <<"ims">> := ImList} = OpenInfo,
    SlackWithUsers = lists:foldl(fun update_user/2, Slack0, UserList),
    SlackWithUsersChannels = lists:foldl(fun update_channel/2, SlackWithUsers, ImList ++ ChannelList),

    websocket_client:start_link(RTMUrl, ?MODULE, SlackWithUsersChannels).

parse_self(#{<<"id">> := Id, <<"name">> := Name, <<"prefs">> := Prefs} = Self) ->
    maps:without([<<"id">>, <<"name">>, <<"prefs">>], Self#{id => Id, name => Name, prefs => Prefs}).

update_user(#{<<"id">> := Id, <<"name">> := Name, <<"profile">> := Profile}, #{nicknames := NickMap, users := UserMap} = Slack) ->
    #{<<"real_name">> := _} = Profile,
    Slack#{
        nicknames := maps:put(Name, Id, NickMap),
        users := maps:put(Id, Profile#{login => Name}, UserMap)  }.

update_channel(#{<<"id">> := Id, <<"is_im">> := true, <<"user">> := User}, #{channels := Channels} = Slack) ->
    Name = <<"@", (user_login(User, Slack))/binary>>,
    Topic = <<"DM: ", (user_name(User, Slack))/binary>>,
    Slack#{
        channels := maps:put(Id, #{name => Name, type => im, topic => Topic}, Channels) };
update_channel(#{<<"id">> := Id, <<"name">> := Name} = Channel,
               #{channels := Channels, my_channels := MyChannels} = Slack) ->
    Topic = case Channel of
        #{<<"topic">> := #{<<"value">> := RealTopic}} ->
            RealTopic;
        _ ->
            undefined
    end,
    IsMember = maps:get(<<"is_member">>, Channel, false),
    Slack#{
        my_channels := [Id || IsMember] ++ MyChannels,
        channels := maps:put(Id, #{name => Name, type => channel_type(Channel), topic => Topic}, Channels) }.

channel_type(#{<<"is_group">> := true}) -> group;
channel_type(#{<<"is_im">> := true}) -> im;
channel_type(#{<<"is_mpim">> := true}) -> mpim;
channel_type(#{}) -> channel.

init(#{my_channels := MyChannels} = Slack, _ConnState) ->
    io:format("Starting with channels ~999p~n", [MyChannels]),
    {ok, set_ping_timer(Slack#{ping_timer => undefined, pending_ping => undefined})}.

set_ping_timer(#{ping_timer := PingTimer} = Slack) when is_reference(PingTimer) ->
    erlang:cancel_timer(PingTimer),
    set_ping_timer(Slack#{ping_timer := undefined});
set_ping_timer(#{ping_timer := undefined} = Slack) ->
    PingTimer = erlang:start_timer(5000, self(), ping),
    Slack#{ping_timer := PingTimer}.


websocket_handle({ping, Ping}, _ConnState, Slack) ->
    {reply, {pong, Ping}, Slack};
websocket_handle({pong, _}, _ConnState, Slack) ->
    {ok, Slack};
websocket_handle({text, Msg}, _ConnState, Slack) ->
    Event = jsx:decode(Msg, [return_maps]),
    handle_event(Event, Slack).

websocket_info({system, From, get_state}, ConnState, Slack) ->
    gen:reply(From, {ConnState, Slack}),
    {ok, Slack};
websocket_info({send, #{} = Event}, _ConnState, Slack) ->
    {reply, encode(Event), Slack};
websocket_info({timeout, PingTimer, _}, _ConnState, #{ping_timer := PingTimer} = Slack) ->
    handle_next_ping(Slack);
websocket_info(_, _ConnState, State) ->
    {ok, State}.


message(Channel, Text) ->
    encode(#{
            id => erlang:unique_integer([positive]), type => message, channel => Channel,
            text => iolist_to_binary([Text])   }).

message(Channel, User, Text) ->
    encode(#{
            id => erlang:unique_integer([positive]), type => message, channel => Channel,
            text => iolist_to_binary([slack_ref(User), ": ", Text])   }).

config_message(Channel, Id, Text) ->
    encode(#{
            id => Id, type => message, channel => Channel,
            text => iolist_to_binary([Text])    }).

encode(Event) ->
    {text, jsx:encode(Event)}.


handle_next_ping(#{pending_ping := Pending} = Slack) when is_integer(Pending) ->
    {close, <<"no ping">>, Slack};
handle_next_ping(#{} = Slack) ->
    Id = erlang:unique_integer([positive]),
    Ping = #{type => ping, id => Id},
    {reply, encode(Ping), set_ping_timer(Slack#{pending_ping := Id})}.

websocket_terminate(Reason, ConnState, _Slack) ->
    io:format("Websocket closed in state ~p, reason:~n    ~120tp~n",
              [ConnState, Reason]),
    ok.


handle_event(#{<<"type">> := <<"hello">>}, Slack) ->
    % TODO: maybe confirm something
    {ok, load_config(Slack)};

handle_event(#{<<"reply_to">> := Id}, #{pending_ping := Id} = Slack) ->
    {ok, Slack#{pending_ping := undefined}};

handle_event(#{<<"reply_to">> := Id, <<"ok">> := true, <<"ts">> := Timestamp}, #{config_ch_id := {Channel, Id}} = Slack) ->
    {ok, actualize_config(Channel, Timestamp, Slack)};

handle_event(#{<<"reply_to">> := Id} = Event, Slack) ->
    io:format("Reply to ~p: ~120tp~n", [Id, maps:without([<<"reply_to">>], Event)]),
    {ok, Slack};

handle_event(#{<<"type">> := <<"presence_change">>, <<"presence">> := Presence, <<"user">> := User}, Slack) ->
    io:format("Presence: ~ts becomes ~s~n", [user_name(User, Slack), Presence]),
    {ok, Slack};

handle_event(#{<<"type">> := <<"message">>, <<"channel">> := Channel, <<"subtype">> := Subtype} = MsgEvent, Slack) ->
    handle_msg_event(Channel, Subtype, maps:without([<<"type">>, <<"channel">>, <<"subtype">>], MsgEvent), Slack);

handle_event(#{<<"type">> := <<"message">>, <<"channel">> := Channel, <<"user">> := User, <<"text">> := Text}, Slack) ->
    io:format("Message from ~ts in ~s: ~ts~n", [user_name(User, Slack), channel_name(Channel, Slack), Text]),
    handle_message(Channel, User, Text, Slack);


handle_event(#{<<"type">> := ChannelUpdate, <<"channel">> := Channel}, Slack) when
        ChannelUpdate == <<"channel_created">>;
        ChannelUpdate == <<"channel_rename">>;
        ChannelUpdate == <<"im_created">>;
        ChannelUpdate == <<"group_joined">>;
        ChannelUpdate == <<"group_rename">>
        ->
    {ok, update_channel(Channel, Slack)};

handle_event(#{<<"type">> := <<"channel_joined">>, <<"channel">> := #{<<"id">> := Id, <<"name">> := Name}},
             #{my_channels := MyChannels} = Slack) ->
    io:format("Joined channel #~s (~s)~n", [Name, Id]),
    {ok, Slack#{my_channels := lists:usort([Id|MyChannels])}};

handle_event(#{<<"type">> := <<"channel_left">>, <<"channel">> := #{<<"id">> := Id}},
             #{my_channels := MyChannels} = Slack) ->
    io:format("Left channel ~s~n", [Id]),
    {ok, Slack#{my_channels := MyChannels -- [Id]}};

handle_event(#{<<"type">> := <<"user_typing">>}, Slack) ->
    {ok, Slack};

handle_event(#{<<"type">> := <<"reaction_", _/binary>>}, Slack) ->
    {ok, Slack};

handle_event(#{<<"type">> := Type} = Event, Slack) ->
    io:format("Dropping event of type ~s: ~120tp~n", [Type, maps:without([<<"type">>], Event)]),
    {ok, Slack}.



handle_message(Channel, User, <<"<@", _/binary>> = MaybeCommand, #{self := #{id := MyID}} = Slack) ->
    case binary:match(MaybeCommand, <<"<@", MyID/binary, ">: ">>) of
        {0, Len} ->
            <<_:Len/binary, Command/binary>> = MaybeCommand,
            handle_command(Channel, User, Command, Slack);
        _ ->
            handle_simple_message(Channel, User, MaybeCommand, Slack)
    end;
handle_message(Channel, User, Text, Slack) ->
    handle_simple_message(Channel, User, Text, Slack).

handle_simple_message(Channel, _User, Text, #{config := Config} = Slack) ->
    case Config of
        #{Channel := #{trigger := Trigger, response := Response}} ->
            handle_msg_check_trigger(Channel, Text, Trigger, Response, Slack);
        _ ->
            {ok, Slack}
    end.

handle_msg_check_trigger(Channel, Text, Trigger, ResponseTmpl, Slack) ->
    case re:run(Text, Trigger) of
        {match, _} ->
            handle_msg_triggered(Channel, Trigger, ResponseTmpl, Slack);
        _ ->
            {ok, Slack}
    end.

handle_msg_triggered(Channel, Trigger, ResponseTmpl, #{nicknames := Nicknames} = Slack) ->
    Topic = channel_topic(Channel, Slack),
    case (is_binary(Topic)) andalso check_trigger(Topic, Trigger) of
        {ok, Nickname} ->
            UserRef = nickname_to_ref(Nickname, Nicknames),
            Response = re:replace(ResponseTmpl, <<"{{user}}">>, UserRef),
            {reply, message(Channel, Response), Slack};
        _ ->
            {ok, Slack}
    end.

nickname_to_ref(Nickname, Nicknames) ->
    case Nicknames of
        #{Nickname := User} ->
            slack_ref(User);
        _ ->
            Nickname
    end.


handle_msg_event(Channel, <<"channel_topic">>, #{<<"ts">> := Timestamp, <<"topic">> := NewTopic}, #{config := Config, token := Token} = Slack) ->
    Reaction = case Config of
        #{Channel := #{trigger := Trigger}} ->
            topic_approval_reaction(NewTopic, Trigger);
        _ ->
            undefined
    end,
    _ = add_reaction(Channel, Timestamp, Reaction, Token),
    {ok, set_channel_topic(Channel, NewTopic, Slack)};

handle_msg_event(_Channel, <<"file_", _/binary>>, #{}, Slack) ->
    {ok, Slack};

handle_msg_event(Channel, Subtype, #{<<"user">> := User, <<"text">> := Text}, Slack) ->
    io:format("Dropping an event ~s from ~ts in ~s: ~ts~n", [Subtype, user_name(User, Slack), channel_name(Channel, Slack), Text]),
    {ok, Slack}.


topic_approval_reaction(Topic, Trigger) ->
    case check_trigger(Topic, Trigger) of
        {ok, _} -> <<"thumbsup">>;
        _ -> <<"thumbsdown">>
    end.

handle_command(Channel, User, <<"channels">>, #{my_channels := MyChannels} = Slack) ->
    ChList = [[slack_ref(Ch), " "] || Ch <- MyChannels],
    {reply, message(Channel, User, ChList), Slack};

handle_command(Channel, User, <<"config">>, #{config := Config} = Slack) ->
    {reply, message(Channel, User, format_config(Config)), Slack};
handle_command(Channel, User, <<"config ", ConfigKV/binary>>, #{} = Slack) ->
    case parse_config_kv(ConfigKV) of
        {ok, ConfigItem} ->
            respond_config(Channel, apply_config(ConfigItem, Slack));
        _ ->
            {reply, message(Channel, User, "sorry, I cannot understand that"), Slack}
    end;

handle_command(Channel, User, Cmd, Slack) ->
    {reply, message(Channel, User, <<"Unknown command: ", Cmd/binary>>), Slack}.

parse_apply_config(ConfText, #{} = Slack) ->
    [_Header | ConfigLines] = binary:split(ConfText, <<"\n">>, [global]),
    lists:foldl(fun parse_apply_conf_line/2, Slack, ConfigLines).

parse_apply_conf_line(ConfLine, Slack) ->
    case parse_config_kv(ConfLine) of
        {ok, ConfigItem} ->
            apply_config(ConfigItem, Slack);
        _ ->
            Slack
    end.


parse_config_kv(<<"<#", _/binary>> = ChannelConfig) ->
    case re:run(ChannelConfig, <<"^<#([^>]*)> *([^ ]*) *([^ ].*)$">>, [{capture, [1, 2, 3], binary}]) of
        {match, [Channel, <<"trigger">>, Trigger]} ->
            {ok, {Channel, trigger, Trigger}};
        {match, [Channel, <<"response">>, Response]} ->
            {ok, {Channel, response, Response}};
        _ ->
            error
    end;

parse_config_kv(<<"trigger ", Trigger/binary>>) ->
    {ok, trigger, Trigger};
parse_config_kv(_) -> error.


apply_config({Key, Value}, #{config := Config} = Slack) ->
    Slack#{config := Config#{Key => Value}};
apply_config({Channel, Key, <<"-">>}, #{config := Config} = Slack) ->
    ChannelConfig = maps:get(Channel, Config, #{}),
    NewChannelConfig = maps:without([Key], ChannelConfig),
    NewConfig = case NewChannelConfig of
        #{} -> maps:without([Channel], Config);
        _ -> Config#{Channel => NewChannelConfig}
    end,
    Slack#{config := NewConfig};
apply_config({Channel, Key, Value}, #{config := Config} = Slack) ->
    ChannelConfig = maps:get(Channel, Config, #{}),
    NewChannelConfig = ChannelConfig#{Key => Value},
    Slack#{config := Config#{Channel => NewChannelConfig}}.


respond_config(Channel, #{config := NewConfig} = Slack) ->
    Id = erlang:unique_integer([positive]),
    Text = ["%% New config %%", format_config(NewConfig)],
    {reply, config_message(Channel, Id, Text), Slack#{config_ch_id := {Channel, Id}}}.

format_config(Config) ->
    [format_config_kv("\n", Key, Value) || {Key, Value} <- maps:to_list(Config)].

format_config_kv(Prefix, Key, Value) when is_atom(Key), is_binary(Value) ->
    [Prefix, atom_to_list(Key), " ", Value];
format_config_kv(Prefix, Channel, #{} = ChannelConfig) when is_binary(Channel) ->
    ChannelPrefix = [Prefix, slack_ref(Channel), " "],
    [format_config_kv(ChannelPrefix, Key, Value) || {Key, Value} <- maps:to_list(ChannelConfig)].

user_name(User, #{users := Users}) ->
    #{User := #{<<"real_name">> := Name, login := Login}} = Users,
    case Name of
        <<>> -> <<"@", Login/binary>>;
        _ -> Name
    end.

user_login(User, #{users := Users}) ->
    #{User := #{login := Login}} = Users,
    Login.

channel_name(Channel, #{channels := Channels}) ->
    #{name := Name} = maps:get(Channel, Channels, #{name => Channel}),
    Name.

set_channel_topic(Channel, Topic, #{channels := Channels} = Slack) ->
    ChannelInfo = maps:get(Channel, Channels, #{}),
    NewChannels = Channels#{Channel => ChannelInfo#{topic => Topic}},
    Slack#{channels := NewChannels}.

channel_topic(Channel, #{channels := Channels}) ->
    #{topic := Topic} = maps:get(Channel, Channels, #{topic => undefined}),
    Topic.

slack_ref(<<"U", _/binary>> = Id) -> slack_ref(user, Id);
slack_ref(<<"C", _/binary>> = Id) -> slack_ref(channel, Id);
slack_ref(Id) -> <<"ID:", Id/binary>>.

slack_ref(user, Id) -> <<"<@", Id/binary, ">">>;
slack_ref(channel, Id) -> <<"<#", Id/binary, ">">>.


actualize_config(Channel, Timestamp, #{token := Token, self := #{id := MyID}} = Slack) ->
    ok = add_conf_reaction(Channel, Timestamp, Token),
    {ok, FullConfReactions} = get_conf_reactions(Token, MyID),
    ConfReactions = [{RChannel, RTimestamp} || {RChannel, RTimestamp, _} <- FullConfReactions],
    OldReactions = ConfReactions -- [{Channel, Timestamp}],
    case OldReactions == ConfReactions of
        true ->
            % Well, it is not good, but not fatal
            Slack;
        false ->
            [remove_conf_reaction(OldChannel, OldTimestamp, Token) || {OldChannel, OldTimestamp} <- OldReactions],
            Slack
    end.

load_config(#{token := Token, self := #{id := MyID}} = Slack) ->
    {ok, FullConfReactions} = get_conf_reactions(Token, MyID),
    case latest_config_text(FullConfReactions) of
        undefined ->
            io:format("Cannot determine config. Please configure me!~n"),
            Slack;
        ConfText when is_binary(ConfText) ->
            parse_apply_config(ConfText, Slack)
    end.



latest_config_text([]) ->
    undefined;
latest_config_text([_|_] = FullConfReactions) ->
    {_, _, Text} = hd(lists:sort(fun compare_reactions/2, FullConfReactions)),
    Text.

compare_reactions({_, TS1, _}, {_, TS2, _}) ->
    binary_to_float(TS1) >= binary_to_float(TS2).


-define(CONF_REACTION, <<"white_check_mark">>).
%-define(CONF_REACTION, <<"ok">>).
add_conf_reaction(Channel, Timestamp, Token) ->
    add_reaction(Channel, Timestamp, ?CONF_REACTION, Token).

add_reaction(_Channel, _Timestamp, undefined, _Token) ->
    ignore;
add_reaction(Channel, Timestamp, Reaction, Token) ->
    AddReactionUrl = ["https://slack.com/api/reactions.add?token=", Token, "&name=", Reaction, "&channel=", Channel, "&timestamp=", Timestamp],
    {ok, "200", _, _Resp} = ibrowse:send_req(binary_to_list(iolist_to_binary(AddReactionUrl)), [], post, <<>>, [{response_format, binary}]),
    ok.

get_conf_reactions(Token, MyID) ->
    GetReactionsUrl = "https://slack.com/api/reactions.list?token=" ++ Token ++ "&full=true",
    {ok, "200", _, Resp} = ibrowse:send_req(GetReactionsUrl, [], post, <<>>, [{response_format, binary}]),
    #{<<"ok">> := true, <<"items">> := Items} =  jsx:decode(Resp, [return_maps]),
    ConfReactions = [{Channel, Timestamp, Text} ||
            #{<<"type">> := <<"message">>, <<"channel">> := Channel, <<"message">> := Message} <- Items,
            #{<<"ts">> := Timestamp, <<"reactions">> := Reactions, <<"text">> := Text} <- [Message],
            #{<<"name">> := ?CONF_REACTION, <<"users">> := Users} <- Reactions,
            lists:member(MyID, Users)
            ],
    {ok, ConfReactions}.

remove_conf_reaction(Channel, Timestamp, Token) ->
    DelReactionUrl = io_lib:format("https://slack.com/api/reactions.remove?token=~s&channel=~s&timestamp=~s&name=~s", [Token, Channel, Timestamp, ?CONF_REACTION]),
    {ok, "200", _, _Resp} = ibrowse:send_req(lists:flatten(DelReactionUrl), [], post, <<>>, [{response_format, binary}]),
    ok.


check_trigger(Topic, Trigger) ->
    case re:run(Topic, <<"^(.* )?", Trigger/binary, "(.*)? @([^ ]*)( .*)?$">>, [unicode, {capture, [3], binary}]) of
        {match, [Nickname]} ->
            {ok, Nickname};
        nomatch ->
            {error, nomatch}
    end.
