#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/python3 -I -S "$here/check-build.py" --launch "$@"
