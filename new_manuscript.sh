#!/bin/bash
# Set up the Figures folder for a manuscript: create <manuscript>/Figures
# (and the manuscript folder itself, if needed) and copy in the figure
# templates from this repository. Existing files are never overwritten.
#
# Usage:
#   ./new_manuscript.sh "/path/to/your/manuscript"

set -u

[ $# = 1 ] || { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

repo=$(cd "$(dirname "$0")" && pwd)
figs="$1/Figures"
mkdir -p "$figs" || exit 1

for f in "$repo"/*.ai; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    case "$name" in ~*) continue ;; esac      # skip Illustrator temp files
    if [ -e "$figs/$name" ]; then
        echo "SKIP $name (already in $figs)"
    else
        cp "$f" "$figs/" && echo "OK   $name"
    fi
done

echo
echo "Figures folder: $figs"
echo "To export, run from that folder:"
echo "  $repo/export_figures.sh --dir ."
