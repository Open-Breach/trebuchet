#!/bin/sh
# Installed as /usr/bin/trebuchet-fixture: the binary itself stays in its
# bundle, where it finds the files beside it.
exec /usr/lib/trebuchet-fixture/trebuchet-fixture "$@"
