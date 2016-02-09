Slack RTM Bot
============

Building
---------
Install Erlang and just run `make`.

Running
-------
Put your bot's token into this command: `make shell TOKEN=xoxb-14000000000-XXXXXXXXXxxxxXXXXXxxxxXX`

Usage
-------
Use your bot's nickname to have its attention:
  - Request current config: `@duty_bot: config`
  - List available channels: `@duty_bot: channels`
  - Set channel topic/message trigger regexp: `@duty_bot: #letstalk trigger [Dd]uty`
  - Set channel triggred response: `@duty_bot: #letstalk response {{user}} is to blame for all troubles`

How does it work
---------
The bot opens a websocket connection to Slack (using its RTM API) and listens for events.

When someone sets a topic in a channel with configured trigger, the bot reats to it with :thumbsup: or :thumbsdown:
to indicate if topic was parsed successfully.

When you change bot's config, it responds with an updated config dump, then sets a :white_check_mark: reaction.
On start bots gets the latest config reaction to load config.
