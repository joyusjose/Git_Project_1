#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/bump-version.sh [patch|minor|major|x.y.z]
# Defaults to patch if not provided.

PART="${1:-patch}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if [[ ! -f package.json ]]; then
  echo "package.json not found at $REPO_ROOT; run from repo root" >&2
  exit 1
fi

BUILD_NUMBER="${BUILD_BUILDID:-}"
if [[ -z "${BUILD_NUMBER}" ]]; then
  # Fallback if not running in Azure Pipelines
  BUILD_NUMBER=1
fi

# sed in-place flag compatibility (macOS vs GNU)
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(-i)
else
  SED_INPLACE=(-i '')
fi

# Bump package.json version without creating git tag/commit
if [[ "$PART" =~ ^(patch|minor|major)$ ]]; then
  npm version "$PART" --no-git-tag-version >/dev/null
elif [[ "$PART" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  npm version "$PART" --no-git-tag-version >/dev/null
else
  echo "Invalid version part: $PART (use patch|minor|major|x.y.z)" >&2
  exit 1
fi

VERSION=$(node -p "require('./package.json').version")
echo "New version: $VERSION (build $BUILD_NUMBER)"

# --- Android ---
ANDROID_FILE=""
if [[ -f android/app/build.gradle ]]; then
  ANDROID_FILE="android/app/build.gradle"
elif [[ -f android/app/build.gradle.kts ]]; then
  ANDROID_FILE="android/app/build.gradle.kts"
else
  # Try to locate a plausible file
  ANDROID_FILE=$(grep -RIl "defaultConfig" android 2>/dev/null | head -n1 || true)
fi

if [[ -n "$ANDROID_FILE" && -f "$ANDROID_FILE" ]]; then
  echo "Updating Android file: $ANDROID_FILE"
  if [[ "$ANDROID_FILE" == *.kts ]]; then
    # Kotlin DSL
    sed "${SED_INPLACE[@]}" -E "s/versionName\s*=\s*\"[^\"]*\"/versionName = \"$VERSION\"/" "$ANDROID_FILE"
    sed "${SED_INPLACE[@]}" -E "s/versionCode\s*=\s*[0-9]+/versionCode = $BUILD_NUMBER/" "$ANDROID_FILE"
  else
    # Groovy DSL
    sed "${SED_INPLACE[@]}" -E "s/versionName\s*\"[^\"]*\"/versionName \"$VERSION\"/" "$ANDROID_FILE"
    sed "${SED_INPLACE[@]}" -E "s/versionCode\s*[0-9]+/versionCode $BUILD_NUMBER/" "$ANDROID_FILE"
  fi
else
  echo "Warning: Could not locate Android build.gradle/build.gradle.kts under ./android" >&2
fi

# --- iOS ---
PLISTBUDDY="/usr/libexec/PlistBuddy"

# Update Info.plist files (CFBundleShortVersionString and CFBundleVersion)
FOUND_PLIST=0
if [[ -d ios ]]; then
  while IFS= read -r -d '' plist; do
    FOUND_PLIST=1
    echo "Updating iOS plist: $plist"
    if [[ -x "$PLISTBUDDY" ]]; then
      # CFBundleShortVersionString
      if "$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$plist" >/dev/null 2>&1; then
        "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$plist"
      else
        "$PLISTBUDDY" -c "Add :CFBundleShortVersionString string $VERSION" "$plist"
      fi
      # CFBundleVersion (build number)
      if "$PLISTBUDDY" -c "Print :CFBundleVersion" "$plist" >/dev/null 2>&1; then
        "$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist"
      else
        "$PLISTBUDDY" -c "Add :CFBundleVersion string $BUILD_NUMBER" "$plist"
      fi
    else
      echo "Warning: PlistBuddy not found; skipping plist updates" >&2
    fi
  done < <(find ios -type f -name "Info.plist" -print0)
fi

# Also try to update MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.pbxproj if present
PBXPROJ_FILE="$(find ios -type f -name project.pbxproj 2>/dev/null | head -n1 || true)"
if [[ -n "$PBXPROJ_FILE" ]]; then
  echo "Updating iOS project settings: $PBXPROJ_FILE"
  sed "${SED_INPLACE[@]}" -E "s/(MARKETING_VERSION = )[^;]+;/\1$VERSION;/g" "$PBXPROJ_FILE" || true
  sed "${SED_INPLACE[@]}" -E "s/(CURRENT_PROJECT_VERSION = )[^;]+;/\1$BUILD_NUMBER;/g" "$PBXPROJ_FILE" || true
fi

# --- Commit and push changes ---
# Update pipeline build number (visible in Azure UI)
echo "##vso[build.updatebuildnumber]$VERSION+$BUILD_NUMBER"

# Stage changes
git add -A

# Create commit if there are changes
if ! git diff --cached --quiet; then
  git -c user.email="azure-pipelines@local" -c user.name="Azure Pipelines" \
    commit -m "chore(version): bump to $VERSION ($BUILD_NUMBER) [skip ci]"
  # Push back to the same branch Azure checked out
  BRANCH_REF="${BUILD_SOURCEBRANCH:-}"
  BRANCH_NAME="${BUILD_SOURCEBRANCHNAME:-}"
  if [[ -n "$BRANCH_REF" && "$BRANCH_REF" == refs/heads/* ]]; then
    TARGET_REF="$BRANCH_REF"
  elif [[ -n "$BRANCH_NAME" ]]; then
    TARGET_REF="refs/heads/$BRANCH_NAME"
  else
    TARGET_REF="HEAD"
  fi
  echo "Pushing changes to $TARGET_REF"
  git push origin "HEAD:$TARGET_REF"
else
  echo "No version changes to commit"
fi

echo "Version bump complete: $VERSION ($BUILD_NUMBER)"