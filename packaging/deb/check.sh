#!/bin/sh
#
# Install-test a built .deb on the host (Debian/Ubuntu, needs sudo):
#
#   packaging/deb/check.sh dist/zish_<ver>-1_<arch>.deb
#
# lintian (fail on errors) → apt install → /etc/shells registered → the
# installed binary runs a feat and passes the bash-differential regression
# suite → remove → /etc/shells unregistered. The suite runs against
# /usr/bin/zish, i.e. the exact static binary the package ships, not whatever
# happens to be in zig-out.
#
# It REMOVES zish at the end: a CI script, not for a box where zish is the
# login shell.

set -eu

deb=${1:?usage: check.sh <zish_*.deb>}
case $deb in /*) ;; *) deb=$PWD/$deb ;; esac
cd "$(dirname "$0")/../.."

if command -v lintian >/dev/null 2>&1; then
    lintian --fail-on error "$deb"
fi

sudo apt-get install -y "$deb"
grep -qx /usr/bin/zish /etc/shells || { echo "check: /usr/bin/zish not in /etc/shells" >&2; exit 1; }
[ "$(/usr/bin/zish -c 'echo $((6*7))')" = 42 ] || { echo "check: smoke failed" >&2; exit 1; }
[ "$(/usr/bin/zish -c 'calc 2+3')" = 5 ] || { echo "check: shipped feat not found" >&2; exit 1; }

ZISH=/usr/bin/zish ./tests/regress.sh

# Upgrade/reinstall must not duplicate the /etc/shells entry.
sudo apt-get install -y --reinstall "$deb"
[ "$(grep -cx /usr/bin/zish /etc/shells)" = 1 ] || { echo "check: /etc/shells entry duplicated" >&2; exit 1; }

sudo apt-get remove -y zish
if grep -qx /usr/bin/zish /etc/shells; then
    echo "check: /usr/bin/zish left in /etc/shells after remove" >&2; exit 1
fi
[ ! -e /usr/bin/zish ] || { echo "check: /usr/bin/zish left after remove" >&2; exit 1; }
echo "check: ok ($deb)"
