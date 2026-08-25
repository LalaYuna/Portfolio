#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

exec /usr/bin/env python3 "${SCRIPT_DIR}/verify-static-site.py"
