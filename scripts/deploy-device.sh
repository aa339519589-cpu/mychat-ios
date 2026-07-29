#!/bin/zsh
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
project_path="$repo_root/MyChatIOS.xcodeproj"
build_path="$repo_root/.device-build-native"
device_id="${MYCHAT_DEVICE_ID:-DEE9D44F-8BF7-5740-BC78-3CA4437F3FE8}"
fresh_install="${MYCHAT_FRESH_INSTALL:-0}"
app_path="$build_path/Build/Products/Debug-iphoneos/MyChatIOS.app"
binary_path="$app_path/MyChatIOS"

branch="$(git -C "$repo_root" branch --show-current)"
if [[ "$branch" != "main" ]]; then
  print -u2 "Refusing device deployment from branch: $branch"
  exit 2
fi

if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  print -u2 "Refusing deployment with uncommitted files. Commit or discard them first."
  exit 3
fi

git -C "$repo_root" fetch --prune origin main
git -C "$repo_root" merge --ff-only origin/main

head_sha="$(git -C "$repo_root" rev-parse HEAD)"
origin_sha="$(git -C "$repo_root" rev-parse origin/main)"
if [[ "$head_sha" != "$origin_sha" ]]; then
  print -u2 "Deployment source mismatch: HEAD=$head_sha origin/main=$origin_sha"
  exit 4
fi

"$repo_root/scripts/verify-ui-contract.sh"
rm -rf "$build_path"
build_number="$(git -C "$repo_root" rev-list --count "$head_sha")"

xcodebuild \
  -project "$project_path" \
  -scheme MyChatIOS \
  -configuration Debug \
  -destination "id=$device_id" \
  -derivedDataPath "$build_path" \
  CURRENT_PROJECT_VERSION="$build_number" \
  clean build

if [[ ! -d "$app_path" || ! -f "$binary_path" ]]; then
  print -u2 "Built app not found: $app_path"
  exit 5
fi

if strings "$binary_path" | grep -Eq '个人空间|当前对话'; then
  print -u2 "Retired sidebar content detected in the compiled app; installation blocked."
  exit 6
fi

built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")"
print "Installing MyChat commit ${head_sha[1,12]}, build $built_version"

if [[ "$fresh_install" == "1" ]]; then
  xcrun devicectl device uninstall app --device "$device_id" com.mychat.ios >/dev/null 2>&1 || true
fi

xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --terminate-existing --device "$device_id" com.mychat.ios
xcrun devicectl device info apps --device "$device_id" --bundle-id com.mychat.ios
