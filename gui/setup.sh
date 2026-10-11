#!/usr/bin/env bash
# One-time setup of the results viewer (macOS or Linux).
#
# Generates the desktop platform folders (macos/, windows/, linux/) with
# `flutter create`. Existing files such as lib/ and pubspec.yaml are kept.
# It then switches off the macOS app sandbox: the viewer is a local tool that
# reads results/raw from this repository, which a sandboxed app may not do.
# Commit the generated folders afterwards and the other machines can skip this.
set -euo pipefail
cd "$(dirname "$0")"

command -v flutter >/dev/null || {
  echo "flutter not found: install Flutter first, https://docs.flutter.dev/get-started/install" >&2
  exit 1
}
flutter config --enable-macos-desktop --enable-linux-desktop --enable-windows-desktop >/dev/null || true
flutter create --platforms=macos,windows,linux --project-name pq_results --org org.pqkemstudy .

for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  [ -f "$f" ] && perl -0pi -e 's#(<key>com\.apple\.security\.app-sandbox</key>\s*)<true\s*/>#$1<false/>#' "$f"
done

# A larger first window (the default is 800x600 on macOS and 1280x720 elsewhere).
if [ -f macos/Runner/Base.lproj/MainMenu.xib ]; then
  perl -pi -e 's#<rect key="contentRect" x="(\d+)" y="(\d+)" width="800" height="600"/>#<rect key="contentRect" x="$1" y="$2" width="1360" height="860"/>#' \
    macos/Runner/Base.lproj/MainMenu.xib
fi

flutter pub get
case "$(uname -s)" in
  Darwin) dev=macos ;;
  *) dev=linux ;;
esac
echo
echo "Done. Start the viewer with:   cd gui && flutter run -d $dev"
echo "Build a standalone app with:   cd gui && flutter build $dev"
