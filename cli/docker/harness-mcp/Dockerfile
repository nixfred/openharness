# Harness's MCP server, `harness mcp`, in a box: for directories that list a server by building it and asking it
# what it offers (Glama starts it and sends `initialize` and `tools/list`). It is not a way to use Harness. A
# harness is an agent in tmux on the person's own computer, and this box has no daemon and no agents, so every tool
# call here answers "Harness is not running here". What it shows a directory is the real tool list.
#
# The CLI comes from the official installer, as a person gets it (cli/scripts/install.sh, which brings its own Node).
# `harness mcp` answers `initialize` and `tools/list` without a daemon or a tmux server (checked on 2026-10-11 from
# the sources, with a throwaway HOME and no tmux on PATH). The installer installs the published CLI: `harness mcp`
# is in releases after 0.3.73.
#
# From this folder (the build copies nothing in):
#   docker build -t harness-mcp .
#   printf '%s\n' \
#     '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
#     '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | docker run -i --rm harness-mcp
#
# Debian 13 (trixie) for the reason cli/docker/remote-machine gives: the managed grid the installer fetches needs
# glibc 2.38.
FROM debian:trixie-slim

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# curl and ca-certificates fetch the installer; tmux and procps (`ps`) are what it would otherwise install with
# apt-get, which a user without root cannot.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl tmux procps \
  && rm -rf /var/lib/apt/lists/*

# Not root: Harness installs into the user's home and needs no privileges.
RUN useradd --create-home --shell /bin/bash harness
USER harness
WORKDIR /home/harness

RUN curl -fsSL https://harness.autonomous.ai/cli/install.sh | bash

ENV PATH="/home/harness/.local/bin:${PATH}"

# MCP over stdio: newline-delimited JSON-RPC on stdin and stdout, nothing else on stdout.
CMD ["harness", "mcp"]
