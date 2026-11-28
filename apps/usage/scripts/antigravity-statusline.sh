#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || "$1" != /* ]]; then
    echo "Usage: antigravity-statusline.sh /absolute/path/to/account.json" >&2
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
    select(.product == "antigravity" and (.quota | type) == "object")
    | {product, quota: (.quota | with_entries(
        select(.value.disabled != true and (.value.remaining_fraction | type) == "number"
            and .value.remaining_fraction >= 0 and .value.remaining_fraction <= 1)
        | .value |= {remaining_fraction, reset_time, reset_in_seconds}
    ))}
    | select(.quota | length > 0)
' > "$temporary"; then
    mv -f "$temporary" "$destination"
fi
printf 'Usage snapshot'
