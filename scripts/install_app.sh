#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
source_app="$project_dir/build/AgentBar.app"
destination_app="/Applications/AgentBar.app"
running_pattern='^/Applications/AgentBar\.app/Contents/MacOS/AgentBar$'

"$script_dir/build_app.sh" release

if pgrep -f "$running_pattern" >/dev/null; then
    osascript -e 'tell application id "com.monicagraham.AgentBar" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -f "$running_pattern" >/dev/null || break
        sleep 0.1
    done
    if pgrep -f "$running_pattern" >/dev/null; then
        pkill -f "$running_pattern"
    fi
fi

ditto --norsrc "$source_app" "$destination_app"
xattr -cr "$destination_app"
codesign --force --deep --sign - "$destination_app"
open -a "$destination_app"
echo "$destination_app"
