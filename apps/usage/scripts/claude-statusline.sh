#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: claude-statusline.sh /absolute/path/to/account.json" >&2
    exit 2
fi

if ! command -v jq >/dev/null && [[ -x /opt/homebrew/bin/jq ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

destination=$1
umask 077
mkdir -p "$(dirname "$destination")"
temporary=$(mktemp "${destination}.XXXXXX")
trap 'rm -f "$temporary"' EXIT

if jq -ec '
    def reading:
        if (.used_percentage | type) == "number"
        then {used_percentage, resets_at}
        else null end;
    {rate_limits: {
        five_hour: (.rate_limits.five_hour | reading),
        seven_day: (.rate_limits.seven_day | reading)
    }}
    | select(.rate_limits.five_hour != null or .rate_limits.seven_day != null)
' > "$temporary"; then
    mv -f "$temporary" "$destination"
fi
printf 'Usage snapshot'
