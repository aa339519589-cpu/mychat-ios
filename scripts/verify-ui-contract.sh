#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
root_view="$repo_root/MyChatIOS/RootView.swift"
thinking_view="$repo_root/MyChatIOS/RichMessageView.swift"
settings_view="$repo_root/MyChatIOS/SettingsViews.swift"
project_file="$repo_root/MyChatIOS.xcodeproj/project.pbxproj"
info_plist="$repo_root/MyChatIOS/Info.plist"

if command -v rg >/dev/null 2>&1; then
  fixed_search() { rg -Fq "$2" "$1"; }
  regex_search() { rg -n "$1" "$2"; }
  match_count() { rg -c "$2" "$1"; }
else
  fixed_search() { grep -Fq "$2" "$1"; }
  regex_search() { grep -R -nE "$1" "$2"; }
  match_count() { grep -c "$2" "$1"; }
fi

require_text() {
  local file="$1"
  local value="$2"
  if ! fixed_search "$file" "$value"; then
    echo "Missing UI contract: $value"
    exit 1
  fi
}

require_text "$root_view" "struct Composer: View"
require_text "$root_view" "RoundedRectangle(cornerRadius: 18, style: .continuous)"
require_text "$root_view" ".padding(.horizontal, 14)"
require_text "$root_view" ".padding(.top, 7)"
require_text "$root_view" ".padding(.bottom, 8)"
require_text "$root_view" "VoiceActivityView"
require_text "$root_view" "title: \"深度研究\""
require_text "$root_view" "Image(systemName: \"gearshape\")"
require_text "$thinking_view" "ThreeBodyLoader"
require_text "$thinking_view" "Text(\"Thinking\")"
require_text "$settings_view" "SettingsRoute.account"
require_text "$settings_view" ".memory"
require_text "$settings_view" ".models"
require_text "$settings_view" ".systemPrompt"
require_text "$settings_view" ".usage"
require_text "$project_file" "SettingsViews.swift in Sources"
require_text "$project_file" "WorkspaceViews.swift in Sources"
require_text "$info_plist" "NSCameraUsageDescription"

if regex_search "深度联网|deepWebSearch|deep_web_search" "$repo_root/MyChatIOS"; then
  echo "Removed deep-network feature is still referenced"
  exit 1
fi

if regex_search 'MyChatMark|Text\("个人空间"\)|Text\("当前对话"\)|accessibilityLabel\("收起侧边栏"\)' "$root_view"; then
  echo "Removed sidebar chrome is still referenced"
  exit 1
fi

if regex_search '\.sheet\(item: \$editor\)' "$settings_view"; then
  echo "Model editor still uses a card-like sheet"
  exit 1
fi

if regex_search 'RoundedRectangle|GroupBox|Form\s*\{|Section\s*\{' "$settings_view"; then
  echo "Settings pages regressed to card or grouped-form chrome"
  exit 1
fi

composer_count="$(match_count "$root_view" '^struct Composer: View')"
if [[ "$composer_count" != "1" ]]; then
  echo "Expected exactly one Composer implementation"
  exit 1
fi

echo "UI contract checks passed"
