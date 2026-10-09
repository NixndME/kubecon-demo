#!/usr/bin/env bash
# Build the AI on HKS dashboard plugin jar into dist/. Bumps the patch version every run (Morpheus treats an
# identical version as unchanged; `clean` keeps the manifest version honest).
# Needs JDK 17 and Gradle 8.5: a .toolchain folder one or two levels up, TOOLCHAIN=..., or java and gradle on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for t in "${TOOLCHAIN:-}" "$ROOT/../.toolchain" "$ROOT/../../.toolchain"; do
  [ -n "$t" ] && [ -x "$t/gradle-8.5/bin/gradle" ] && { export JAVA_HOME="$t/jdk-17.0.19+10"; GRADLE="$t/gradle-8.5/bin/gradle"; break; }
done
GRADLE="${GRADLE:-$(command -v gradle || true)}"
[ -n "$GRADLE" ] || { echo "Gradle not found. See the comment at the top of build.sh." >&2; exit 1; }
BG="$ROOT/plugin/build.gradle"
if [ "${NO_BUMP:-0}" != 1 ]; then
  cur=$(grep -oE "^version = '[0-9]+\.[0-9]+\.[0-9]+'" "$BG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  IFS=. read -r a b c <<< "$cur"; new="$a.$b.$((c+1))"
  sed -i "s/^version = '$cur'/version = '$new'/" "$BG"; echo "==> version $cur -> $new"
fi
"$GRADLE" -p "$ROOT/plugin" clean shadowJar test --console=plain
mkdir -p "$ROOT/dist"
jar=$(ls -t "$ROOT"/plugin/build/libs/*-all.jar | head -1)
cp "$jar" "$ROOT/dist/morpheus-hks-ai-dashboard-plugin.jar"; cp "$jar" "$ROOT/dist/"
echo "==> dist/morpheus-hks-ai-dashboard-plugin.jar <- $(basename "$jar")"
