#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
bundle_dir="$project_dir/build/AgentBar.app"
probe_dir=$(mktemp -d /tmp/agentbar-smoke.XXXXXX)
scratch_dir="$probe_dir/swift-build"
trap 'rm -rf "$probe_dir"' EXIT

cd "$project_dir"
swift build --scratch-path "$scratch_dir"
"$script_dir/build_app.sh" release >/dev/null
plutil -lint "$bundle_dir/Contents/Info.plist"

# Desktop/File Provider folders can attach FinderInfo to a bundle immediately
# after signing. Verify a no-resource-fork copy in /tmp so that metadata added
# by the workspace host is not mistaken for a packaging failure.
verification_bundle="$probe_dir/AgentBar.app"
ditto --norsrc "$bundle_dir" "$verification_bundle"
xattr -cr "$verification_bundle"
codesign --force --deep --sign - "$verification_bundle"
codesign --verify --deep --strict "$verification_bundle"

codex_binary="/Applications/ChatGPT.app/Contents/Resources/codex"
if [[ ! -x "$codex_binary" ]]; then
    echo "Codex executable missing" >&2
    exit 1
fi
"$codex_binary" login status 2>&1 | rg -q 'Logged in using ChatGPT'

claude_binary=$(find "$HOME/Library/Application Support/Claude/claude-code" \
    -path '*/claude.app/Contents/MacOS/claude' -type f -perm -111 2>/dev/null \
    | sort -V | tail -1)
if [[ -z "$claude_binary" ]]; then
    echo "Claude Desktop executable missing" >&2
    exit 1
fi
"$claude_binary" --version 2>&1 | rg -q 'Claude Code'

xcrun swiftc -parse-as-library \
    "$project_dir/scripts/ApplicationLinkProbe.swift" \
    -framework AppKit \
    -o "$probe_dir/application-link-probe"
"$probe_dir/application-link-probe"

xcrun swiftc -parse-as-library \
    "$project_dir/Sources/AgentBar/Models.swift" \
    "$project_dir/Sources/AgentBar/JSONLineProcess.swift" \
    "$project_dir/Sources/AgentBar/CodexConnector.swift" \
    "$project_dir/scripts/CodexProtocolProbe.swift" \
    -o "$probe_dir/codex-protocol-probe"
"$probe_dir/codex-protocol-probe"

xcrun swiftc -parse-as-library \
    "$project_dir/Sources/AgentBar/CodexHistoryMonitor.swift" \
    "$project_dir/scripts/CodexHistoryMonitorProbe.swift" \
    -o "$probe_dir/codex-history-monitor-probe"
"$probe_dir/codex-history-monitor-probe"

echo "AgentBar smoke test passed"
