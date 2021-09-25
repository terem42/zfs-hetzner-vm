#!/bin/bash

set -o pipefail
set -o errexit
set -o nounset
set -o errtrace
shopt -s inherit_errexit

# Always download the latest version:
#
# - it's fast and stable enough not to worry about it;
# - the workflow is basically single-person, so there's no risk of a new dev encountering an error found
#   by a new shellcheck version.

mkdir -p /opt/shellcheck

wget -qO- https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz \
  | tar xJv -O shellcheck-stable/shellcheck \
  > /opt/shellcheck/shellcheck

chmod +x /opt/shellcheck/shellcheck

/opt/shellcheck/shellcheck --version

grep -lZP '^#!/bin/\w+sh' -R | xargs -0 /opt/shellcheck/shellcheck