#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Rémi Ducceschi
#
# Everything the CI lint job runs, so a failure there reproduces with one command.
# Usage: tests/lint.sh

# No -f: the file lists below are globs.
set -euo pipefail

cd "$(dirname "$(dirname "$(readlink -f "$0")")")"

bash -n bclaude.sh bclaude-vscode.sh tests/*.sh tests/helpers.bash
shellcheck bclaude.sh bclaude-vscode.sh tests/*.sh tests/helpers.bash tests/*.bats
jq empty managed-settings.json examples/settings.json
echo "lint ok"
