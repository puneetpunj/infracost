#!/bin/bash
set -eou pipefail

CONTEXT="${1}"

if test -n "${BUILDKITE:-}"; then
    filename="$(mktemp)"
    trap "rm -f $filename" EXIT
    jq -r '[(.resource_changes // []) [] | select (.change.actions != ["no-op"])] as $changes | if ($changes | length) == 0 then "No changes" else ($changes[] | "\(.change.actions|join(",")) \(.address)") end' |
        sed 's/delete,create/replace/' \
            >>$filename
    if grep -e "^delete" -e "^replace" "${filename}" >/dev/null; then
        style="warning"
    elif grep -e "^create" -e "^update" "${filename}" >/dev/null; then
        style="info"
    else
        # No change, or only reads
        buildkite-agent meta-data set "${CONTEXT}_apply" "no"
        exit 0
    fi

    # in the plan, this is used in the pipeline script to run the apply if necessary"
    buildkite-agent meta-data set "${CONTEXT}_apply" "yes"

    # First sed normalises equivalent changes to the same module in different regions
    # Second sed normalises resource count/for_each indexes
    # These keep otherwise equivalent changes together
    hash=$(cat "${filename}" |
        sed -r 's/module\.([^.]+)_(au|ca|ie|sg|uk|za)/module.\1_$region/' |
        sed -r 's/\[[0-9]+\]$/[N]/;s/\["[^"]*"\]$/[K]/' |
        sort -u | sha1sum | cut -d ' ' -f 1)
    (
        echo "<details><summary>${CONTEXT}</summary><pre><code>$(cat ${filename})</code></pre></details>"
    ) | buildkite-agent annotate --context "${CONTEXT}${hash}" --style "$style" --append

    rm "$filename"
else
    cat >/dev/null
fi
