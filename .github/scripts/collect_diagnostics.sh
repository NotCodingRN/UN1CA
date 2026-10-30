#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

# Collects the build log, every error line, the decoded smali files the failed
# patches point at and the key firmware files into a folder for offline review.
#
# Usage: collect_diagnostics.sh <build log> <output folder>

LOG_FILE="$1"
DEST="$2"

mkdir -p "$DEST/smali" "$DEST/patched" "$DEST/fw"

[ -f "$LOG_FILE" ] || exit 0
sed 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" > "$DEST/build.log"

# LOGE prints in red, git apply prints "error:"
grep -a $'\033\[0;31m' "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g' > "$DEST/errors.txt"
grep -a -E '^(error|warning): ' "$DEST/build.log" >> "$DEST/errors.txt"
grep -a -E 'Missing SPF patches' "$DEST/build.log" >> "$DEST/errors.txt"
sort -u -o "$DEST/errors.txt" "$DEST/errors.txt"

# "/<partition>/<file>.(apk|jar)/<smali>" as printed by smali_utils.sh
while IFS= read -r REF; do
    PARTITION="$(cut -d "/" -f 2 <<< "$REF")"
    FILE="$(sed -E 's#^/[^/]+/(.+\.(apk|jar))/.*#\1#' <<< "$REF")"
    SMALI="$(sed -E 's#^/[^/]+/.+\.(apk|jar)/##' <<< "$REF")"
    DECODED="$APKTOOL_DIR/$PARTITION/${FILE//system\//}"

    if [ -f "$DECODED/$SMALI" ]; then
        mkdir -p "$DEST/smali/$PARTITION/$FILE/$(dirname "$SMALI")"
        cp -a "$DECODED/$SMALI" "$DEST/smali/$PARTITION/$FILE/$SMALI"
    elif [ -d "$DECODED" ]; then
        # The class most likely moved to another smali_classesN folder
        CLASS="${SMALI#*/}"
        while IFS= read -r MATCH; do
            REL="${MATCH#"$DECODED"/}"
            mkdir -p "$DEST/smali/$PARTITION/$FILE/$(dirname "$REL")"
            cp -a "$MATCH" "$DEST/smali/$PARTITION/$FILE/$REL"
        done < <(find "$DECODED" -path "*/$CLASS" -type f 2> /dev/null)
        echo "$REF" >> "$DEST/smali/moved_or_missing.txt"
    fi
done < <(grep -a -o -E '/(system|vendor|product|system_ext|odm)/[^" ]+\.(apk|jar)/[^" ]+\.smali' "$DEST/errors.txt" | sort -u)

# Files git apply could not patch, git prints them with the absolute --directory path
COPY_DECODED()
{
    [ -f "$1" ] || return 0
    mkdir -p "$DEST/patched/$(dirname "${1#"$APKTOOL_DIR"/}")"
    cp -a "$1" "$DEST/patched/${1#"$APKTOOL_DIR"/}"
}
while IFS= read -r REL; do
    if [[ "$REL" == /* ]]; then
        COPY_DECODED "$REL"
    else
        while IFS= read -r MATCH; do
            COPY_DECODED "$MATCH"
        done < <(find "$APKTOOL_DIR" -path "*/$REL" -type f 2> /dev/null)
    fi
done < <(grep -a -o -E '^error: (patch failed: )?[^: ]+' "$DEST/build.log" | sed -E 's/^error: (patch failed: )?//' | sort -u)

# Boot critical classes, always useful when porting a new source firmware
while IFS= read -r MATCH; do
    COPY_DECODED "$MATCH"
done < <(find "$APKTOOL_DIR/system/framework/framework.jar" "$APKTOOL_DIR/system/framework/services.jar" \
    -type f \( -name 'IVold*.smali' -o -name 'StorageManagerService.smali' -o -name 'LockSettingsService.smali' \) 2> /dev/null)

# Full decoded trees of everything UN1CA patches with smali diffs, so patches can be reworked offline.
# Note: folders split by apktool.sh because of the dex limit are already split here.
DECODED_TREES=()
for t in system/framework/framework.jar system/framework/services.jar system/framework/semwifi-service.jar \
        system/framework/telephony-common.jar system/priv-app/SecSettings/SecSettings.apk \
        system/priv-app/SettingsProvider/SettingsProvider.apk system/priv-app/MultiSoundSetting/MultiSoundSetting.apk \
        system/priv-app/SecSetupWizard_Global/SecSetupWizard_Global.apk \
        system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk \
        system/app/DAAgent/DAAgent.apk system_ext/priv-app/SystemUI/SystemUI.apk; do
    [ -d "$APKTOOL_DIR/$t" ] && DECODED_TREES+=("$t")
done
if [ "${#DECODED_TREES[@]}" -gt 0 ]; then
    tar -C "$APKTOOL_DIR" --exclude="build" --exclude="dist" --exclude="original" --exclude="res" \
        -cf - "${DECODED_TREES[@]}" | xz -T0 -6 > "$DEST/decoded.tar.xz"
fi

# Key files from each extracted firmware
for FW in "$FW_DIR"/*/; do
    [ -d "$FW" ] || continue
    NAME="$(basename "$FW")"
    mkdir -p "$DEST/fw/$NAME"
    for f in system/system/build.prop system/system/etc/floating_feature.xml \
            product/etc/build.prop vendor/build.prop vendor/etc/build.prop \
            system_ext/etc/build.prop odm/etc/build.prop; do
        [ -f "$FW/$f" ] && cp -a "$FW/$f" "$DEST/fw/$NAME/${f//\//_}"
    done
    for d in system/system/app system/system/priv-app system/system/framework \
            product/app product/priv-app system_ext/priv-app system_ext/app; do
        [ -d "$FW/$d" ] && ls -1 "$FW/$d" > "$DEST/fw/$NAME/ls_${d//\//_}.txt"
    done
done

[ -f "$OUT_DIR/config.sh" ] && cp -a "$OUT_DIR/config.sh" "$DEST/config.sh"
df -h > "$DEST/df.txt" 2>&1

echo "Collected $(wc -l < "$DEST/errors.txt") error line(s)"
exit 0
