#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Rémi Ducceschi
#
# VS Code's claudeCode.claudeProcessWrapper calls `<wrapper> <bundled claude>
# <args...>` with cwd = workspace: argv[1] becomes CLAUDE_BIN, see README.
# No `claude update`: the extension ships and replaces its own binary.

set -eufo pipefail

CLAUDE_BIN="${1:?claude binary expected as first argument}" DISABLE_AUTOUPDATER=1 \
    exec "$(dirname "$(readlink -f "$0")")/bclaude.sh" "${@:2}"
