#!/bin/sh
# Prints the boards of the family FAMILY (the folders in system/board/ whose board.mk says
# "FAMILY := FAMILY"), one per line, sorted.
# Usage: family-boards.sh FAMILY
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
grep -lx "FAMILY := $1" "$ROOT"/system/board/*/board.mk | sed 's|.*/board/\([^/]*\)/board.mk|\1|' | sort
