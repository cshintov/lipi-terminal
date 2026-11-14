#!/bin/bash
# Build only. Never installs or launches an app, and never fetches dependencies.
set -euo pipefail
exec /usr/bin/python3 "$(cd "$(dirname "$0")" && pwd)/lipi_build.py" "$@"
