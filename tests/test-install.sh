#!/usr/bin/env bash
# install.sh end to end: the site is laid out the way it is served at
# get.openbreach.dev (signed repositories, the public key, install.sh
# itself), served over HTTP on this machine, and the documented one-liner
# is run in a clean container of every target. The key is a throwaway
# generated here.
#
# The containers install curl and resolve dependencies from their distro's
# own repositories, so this test needs the network.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
require_docker

work="$(mktemp -d)"
server=""
cleanup() {
  [ -z "$server" ] || kill "$server" 2> /dev/null || true
  stop_gpg_agent "$work/gnupg"
  rm -rf "$work"
}
trap cleanup EXIT

make_test_key "$work/gnupg" ed25519
make_site "$work/site" "$work/gnupg" 1.0.0 1.1.0

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/site" > "$work/server.log" 2>&1 &
server="$!"
url="http://127.0.0.1:$port"
for _ in $(seq 1 50); do
  if curl -fsS -o /dev/null "$url/install.sh" 2> /dev/null; then break; fi
  sleep 0.1
done
curl -fsS -o /dev/null "$url/install.sh" || fail "the test server did not start: $(cat "$work/server.log")"

for target in $(jq -r '.targets[].id' "$targets"); do
  image="$(image_of "$target")"
  echo "-- $target: the one-liner in $image"
  # The host's network, so that the container reaches the server above.
  docker_run --network host -v "$repo_root/tests/client:/client:ro" "$image" \
    sh /client/install.sh "$url" trebuchet-fixture 1.1.0 > "$work/client.log" 2>&1 \
    || { cat "$work/client.log"; fail "$target: install.sh"; }
  tail -n 1 "$work/client.log"
done

# The script asked for exactly the files a user's machine needs.
for path in /install.sh /keys/openbreach.gpg /keys/openbreach.asc; do
  grep -q "GET $path " "$work/server.log" || fail "nothing fetched $path"
done

echo "install.sh: ok"
