#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
input_ipa="${1:-}"
if [[ -z "$input_ipa" ]]; then
  echo "usage: $0 /path/to/decrypted.ipa" >&2
  exit 2
fi
if [[ "$input_ipa" != /* ]]; then
  input_ipa="$PWD/$input_ipa"
fi
if [[ ! -f "$input_ipa" ]]; then
  echo "IPA not found: $input_ipa" >&2
  exit 2
fi

case "$(dd if="$input_ipa" bs=4 count=1 2>/dev/null)" in
  PK*) ;;
  *) echo "Input is not an IPA/ZIP archive" >&2; exit 2 ;;
esac

task_tmp_root="${TMPDIR:-/tmp}/youmod-ci"
mkdir -p "$task_tmp_root"
build_root="$(mktemp -d "$task_tmp_root/build.XXXXXX")"
cleanup() { rm -rf "$build_root"; }
trap cleanup EXIT

extract_root="$build_root/input"
ditto -x -k "$input_ipa" "$extract_root"
app_path="$(find "$extract_root/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$app_path" ]]; then
  echo "Payload/*.app is missing from the IPA" >&2
  exit 2
fi
app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Info.plist")"
cryptid="$(xcrun otool -l "$app_path/$app_executable" | awk '/cryptid/{print $2; exit}')"
if [[ -z "$cryptid" || "$cryptid" != "0" ]]; then
  echo "The uploaded IPA is not decrypted (cryptid=${cryptid:-unknown})" >&2
  exit 2
fi
youtube_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist")"
youmod_version="$(awk '/^Version:/{print $2; exit}' "$project_root/control")"

if command -v brew >/dev/null 2>&1; then
  homebrew_prefix="$(brew --prefix)"
  export PATH="$homebrew_prefix/bin:$PATH"
  gnu_make_prefix="$(brew --prefix make 2>/dev/null || true)"
  if [[ -n "$gnu_make_prefix" ]]; then
    export PATH="$gnu_make_prefix/libexec/gnubin:$PATH"
  fi
  if ! command -v ldid >/dev/null 2>&1; then
    brew install ldid
  fi
fi
make_bin="$(command -v make || true)"
for command_name in git make curl unzip xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Required command is missing: $command_name" >&2
    exit 1
  }
done

tools_root="$task_tmp_root/tools"
theos="$tools_root/theos"
mkdir -p "$tools_root"
xcode_tools="$tools_root/xcode-tools"
mkdir -p "$xcode_tools"
for tool_name in clang clang++ dsymutil strip lipo libtool swiftc codesign_allocate xcodebuild; do
  ln -sfn "$(xcrun -f "$tool_name")" "$xcode_tools/$tool_name"
done
if command -v brew >/dev/null 2>&1; then
  ln -sfn "$(brew --prefix xz)/bin/lzma" "$xcode_tools/lzma"
fi
export PATH="$xcode_tools:$PATH"
echo "Using lzma: $(command -v lzma)"
if [[ ! -d "$theos/.git" ]]; then
  git clone --quiet --depth=1 --recurse-submodules https://github.com/theos/theos.git "$theos"
fi
if ! find "$theos/sdks" -maxdepth 1 -type d -name 'iPhoneOS18.6.sdk' -print -quit | grep -q .; then
  sdk_checkout="$build_root/iOS-SDKs"
  git clone --quiet --depth=1 -n --filter=tree:0 https://github.com/Tonwalter888/iOS-SDKs.git "$sdk_checkout"
  git -C "$sdk_checkout" sparse-checkout set --no-cone iPhoneOS18.6.sdk
  git -C "$sdk_checkout" checkout --quiet
  mv "$sdk_checkout"/*.sdk "$theos/sdks/"
fi
git -C "$theos/vendor/logos" fetch --quiet origin a62370066a97e36d59b200a9fa10c5091f5e8972
git -C "$theos/vendor/logos" checkout --quiet a62370066a97e36d59b200a9fa10c5091f5e8972

clone_or_update_header() {
  local url="$1" destination="$2"
  if [[ ! -d "$destination/.git" ]]; then
    rm -rf "$destination"
    git clone --quiet --depth=1 "$url" "$destination"
  else
    git -C "$destination" fetch --quiet --depth=1 origin
    git -C "$destination" reset --quiet --hard FETCH_HEAD
  fi
}
clone_or_update_header https://github.com/PoomSmart/YouTubeHeader.git "$theos/include/YouTubeHeader"
clone_or_update_header https://github.com/PoomSmart/PSHeader.git "$theos/include/PSHeader"
rm -rf "$theos/include/YTHeaders"
cp -R "$theos/include/YouTubeHeader" "$theos/include/YTHeaders"
sed -i '' 's/od -c "$i" | head/od -c "$i" 2>\/dev\/null | head/g' "$theos/bin/convert_xml_plist.sh" || true

cyan_bin="$(command -v cyan || true)"
if [[ -z "$cyan_bin" && -x "$HOME/.local/bin/cyan" ]]; then
  cyan_bin="$HOME/.local/bin/cyan"
fi
if [[ -z "$cyan_bin" ]]; then
  command -v pipx >/dev/null 2>&1 || { echo "pipx is required to install cyan" >&2; exit 1; }
  pipx install https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip
  cyan_bin="$(command -v cyan || true)"
  [[ -n "$cyan_bin" ]] || cyan_bin="$HOME/.local/bin/cyan"
fi

tbd_bin="$(command -v tbd || true)"
if [[ -z "$tbd_bin" ]]; then
  tbd_bin="$tools_root/tbd"
  if [[ ! -x "$tbd_bin" ]]; then
    curl -fsSL https://github.com/inoahdev/tbd/releases/download/2.2/tbd-mac -o "$tbd_bin"
    chmod +x "$tbd_bin"
  fi
  export PATH="$tools_root:$PATH"
fi

export THEOS="$theos"
export TARGET_CC="$xcode_tools/clang"
export TARGET_CXX="$xcode_tools/clang++"
export TARGET_LD="$xcode_tools/clang++"
export ADDITIONAL_CFLAGS="-Wno-error=incompatible-pointer-types"
export ADDITIONAL_OBJCFLAGS="-Wno-error=incompatible-pointer-types"

sources="$build_root/sources"
debs="$build_root/debs"
mkdir -p "$sources" "$debs"
clone_repo() {
  local name="$1" url="$2"
  git clone --quiet --depth=1 "$url" "$sources/$name"
}

open_youtube="$build_root/OpenYouTubeSafariExtension"
git clone --quiet -n --depth=1 --filter=tree:0 https://github.com/BillyCurtis/OpenYouTubeSafariExtension.git "$open_youtube"
git -C "$open_youtube" sparse-checkout set --no-cone OpenYouTubeSafariExtension.appex
git -C "$open_youtube" checkout --quiet
appex="$(find "$open_youtube" -maxdepth 2 -type d -name '*.appex' -print -quit)"
[[ -n "$appex" ]] || { echo "OpenYouTubeSafariExtension.appex was not found" >&2; exit 1; }

clone_repo YouPiP https://github.com/PoomSmart/YouPiP.git
clone_repo YTUHD https://github.com/Tonwalter888/YTUHD.git
clone_repo Return-YouTube-Dislikes https://github.com/PoomSmart/Return-YouTube-Dislikes.git
clone_repo YouGroupSettings https://github.com/PoomSmart/YouGroupSettings.git
clone_repo YTVideoOverlay https://github.com/PoomSmart/YTVideoOverlay.git
clone_repo YTABConfig https://github.com/PoomSmart/YTABConfig.git
clone_repo YouQuality https://github.com/PoomSmart/YouQuality.git
clone_repo YouSpeed https://github.com/PoomSmart/YouSpeed.git
clone_repo DontEatMyContent https://github.com/therealFoxster/DontEatMyContent.git
clone_repo YouMute https://github.com/PoomSmart/YouMute.git
clone_repo YouLoop https://github.com/bhackel/YouLoop.git
clone_repo YouSlider https://github.com/PoomSmart/YouSlider.git
clone_repo YTHoldForSpeed https://github.com/joshuaseltzer/YTHoldForSpeed.git
git clone --quiet https://github.com/PoomSmart/YouChooseQuality.git "$sources/YouChooseQuality"
git -C "$sources/YouChooseQuality" checkout --quiet 1585a3691b2ef0b59d42c40c31639fd8b79e2cd4
clone_repo YouShare https://github.com/Tonwalter888/YouShare.git
clone_repo YTweaks https://github.com/fosterbarnes/YTweaks.git
clone_repo Gonerino https://github.com/castdrian/Gonerino.git
clone_repo YouGetCaption https://github.com/PoomSmart/YouGetCaption.git
clone_repo youtube-native-share https://github.com/jkhsjdhjs/youtube-native-share.git
clone_repo VolumeBoostYT https://github.com/VasirakCalgux/VolumeBoostYT.git
git clone --quiet --depth=1 https://github.com/protocolbuffers/protobuf.git "$sources/youtube-native-share/protobuf"
curl -fsSL https://github.com/Tonwalter888/Tonwalter888.github.io/raw/refs/heads/main/deb/alderis.deb -o "$debs/alderis.deb"

build_deb() {
  local directory="$1" output="$2"
  shift 2
  echo "==> Building $(basename "$directory")"
  (
    cd "$directory"
    "$make_bin" clean package \
      DEBUG=0 \
      FINALPACKAGE=1 \
      THEOS_PACKAGE_SCHEME=rootless \
      TARGET=iphone:clang:26.2:14.0 \
      MAKE="$make_bin" \
      TARGET_CC="$xcode_tools/clang" \
      TARGET_CXX="$xcode_tools/clang++" \
      TARGET_LD="$xcode_tools/clang++" \
      TARGET_DSYMUTIL="$xcode_tools/dsymutil" \
      TARGET_STRIP="$xcode_tools/strip" \
      TARGET_LIPO="$xcode_tools/lipo" \
      TARGET_LIBTOOL="$xcode_tools/libtool" \
      TARGET_SWIFTC="$xcode_tools/swiftc" \
      TARGET_CODESIGN_ALLOCATE="$xcode_tools/codesign_allocate" \
      TARGET_XCODEBUILD="$xcode_tools/xcodebuild" \
      TARGET_CODESIGN=/opt/homebrew/bin/ldid \
      ADDITIONAL_CFLAGS="-Wno-error=deprecated-declarations -Wno-error=incompatible-pointer-types" \
      ADDITIONAL_OBJCFLAGS="-Wno-error=deprecated-declarations -Wno-error=incompatible-pointer-types" \
      "$@"
    package="$(find packages -maxdepth 1 -type f -name '*.deb' -print | sort | tail -1)"
    [[ -n "$package" ]] || { echo "No package generated in $directory" >&2; exit 1; }
    cp "$package" "$debs/$output"
  )
}

build_deb "$project_root" youmod.deb
build_deb "$sources/YouPiP" youpip.deb
build_deb "$sources/YTUHD" ytuhd.deb
build_deb "$sources/Return-YouTube-Dislikes" ryd.deb
build_deb "$sources/YouGroupSettings" ygs.deb
build_deb "$sources/YTVideoOverlay" ytvo.deb
build_deb "$sources/YTABConfig" ytabconfig.deb
build_deb "$sources/YouQuality" youquality.deb
build_deb "$sources/YouSpeed" youspeed.deb
build_deb "$sources/DontEatMyContent" demc.deb
build_deb "$sources/YouMute" youmute.deb
build_deb "$sources/YouLoop" youloop.deb
build_deb "$sources/YouSlider" youslider.deb
build_deb "$sources/YTHoldForSpeed" ytholdspeed.deb TARGET=iphone:clang:26.2:15.0 ARCHS=arm64
build_deb "$sources/YouChooseQuality" youchoose.deb
build_deb "$sources/YouShare" youshare.deb
build_deb "$sources/YTweaks" ytweaks.deb
build_deb "$sources/Gonerino" gonerino.deb
build_deb "$sources/YouGetCaption" ygc.deb
build_deb "$sources/youtube-native-share" ytnativeshare.deb ARCHS=arm64
build_deb "$sources/VolumeBoostYT" volboostyt.deb ARCHS=arm64

output="$project_root/YouMod_${youtube_version}_v${youmod_version}_Full_AudioMix.ipa"
rm -f "$output"
inject_items=("$appex")
while IFS= read -r package; do
  inject_items+=("$package")
done < <(find "$debs" -maxdepth 1 -type f -name '*.deb' -print | sort)

"$cyan_bin" -i "$input_ipa" -o "$output" -uwef "${inject_items[@]}" -n YouTube -b com.google.ios.youtube
[[ -s "$output" ]] || { echo "IPA injection did not produce an output" >&2; exit 1; }
unzip -tq "$output" >/dev/null
echo "Built: $output"
