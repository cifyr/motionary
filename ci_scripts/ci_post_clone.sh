#!/bin/sh
# Xcode Cloud runs this after cloning, before it builds.
#
# Motionary.xcodeproj is generated from project.yml and is not committed, so a
# fresh clone has no project at all until XcodeGen has run. This is also why the
# committed Info.plists matter: they name every lane font by hand, and those
# fonts only exist because Resources/prebuilt-* is committed for this reason.
set -e

echo "==> Installing XcodeGen"
brew install xcodegen

echo "==> Generating the project"
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

echo "==> What the build will see"
du -sh Resources
ls Resources | grep -c '^MFont' | sed 's/^/    lane fonts: /'
