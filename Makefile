PROJECT = slack_rtm

SHELL_OPTS = +pc unicode -s tddreloader -s slack_rtm

DEPS = ibrowse websocket_client jsx
SHELL_DEPS = tddreloader

dep_ibrowse = git https://github.com/cmullaparthi/ibrowse.git v4.2
dep_websocket_client = git https://github.com/jeremyong/websocket_client.git v0.7

include erlang.mk
