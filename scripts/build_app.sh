#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
bundle_dir="$project_dir/build/AgentBar.app"
staging_dir=$(mktemp -d /tmp/agentbar-build.XXXXXX)
staged_bundle="$staging_dir/AgentBar.app"
scratch_dir="$staging_dir/swift-build"
trap 'rm -rf "$staging_dir"' EXIT

cd "$project_dir"
swift build -c "$configuration" --scratch-path "$scratch_dir"

binary_path=$(swift build -c "$configuration" --scratch-path "$scratch_dir" --show-bin-path)/AgentBar
mkdir -p "$staged_bundle/Contents/MacOS"
mkdir -p "$staged_bundle/Contents/Resources"
cp "$binary_path" "$staged_bundle/Contents/MacOS/AgentBar"
sed "s|__AGENTBAR_DEFAULT_WORKSPACE__|$project_dir|g" \
    "$project_dir/Resources/Info.plist" \
    > "$staged_bundle/Contents/Info.plist"
xattr -cr "$staged_bundle"
codesign --force --deep --sign - "$staged_bundle"
codesign --verify --deep --strict "$staged_bundle"

# Build outside Desktop/File Provider so workspace metadata cannot invalidate
# the signature. The build directory is generated output and is replaced whole.
if [[ "$bundle_dir" != "$project_dir/build/AgentBar.app" ]]; then
    echo "Unexpected bundle path: $bundle_dir" >&2
    exit 1
fi
rm -rf "$bundle_dir"
mkdir -p "${bundle_dir:h}"
ditto --norsrc "$staged_bundle" "$bundle_dir"

echo "$bundle_dir"
