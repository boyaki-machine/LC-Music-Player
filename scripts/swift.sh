#!/bin/zsh
# All dependencies are public. Do not consult the user's credential stores.
set -euo pipefail
cd "${0:A:h:h}"
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=''
exec swift "$1" --disable-keychain --disable-netrc "${@:2}"
