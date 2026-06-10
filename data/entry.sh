#!/bin/bash
set -e

# DO NOT format the Caddyfile with caddy fmt --overwrite
# because it corrupts the bcrypt hash in basic_auth.
# The Caddyfile is already pre-formatted by install.sh.

echo "Start server"
/app/caddy start --config /data/Caddyfile

tail -f -n 50 /data/Caddyfile
