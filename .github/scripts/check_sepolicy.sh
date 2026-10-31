#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

# Compiles the split SELinux policy of the built ROM with the same files init uses
# on boot (system/core/init/selinux.cpp). A policy that does not compile makes init
# panic before the boot animation. Every failing statement is dropped from a copy and
# the compile retried, so a single run lists all of them.
#
# Usage: check_sepolicy.sh <output file>

OUT="$1"

if [[ "$TARGET_OS_BUILD_SYSTEM_EXT_PARTITION" == "true" ]]; then
    SYSTEM_EXT="$WORK_DIR/system_ext"
else
    SYSTEM_EXT="$WORK_DIR/system/system/system_ext"
fi
VERS="$(head -n 1 "$WORK_DIR/vendor/etc/selinux/plat_sepolicy_vers.txt")"
TMP="$(mktemp -d)"

# The plat_sepolicy_genfs_<version>.cil files are left out, init skips them on targets
# with an older vendor API level
FILES=(
    "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"
    "$WORK_DIR/system/system/etc/selinux/mapping/$VERS.cil"
    "$WORK_DIR/system/system/etc/selinux/mapping/$VERS.compat.cil"
    "$SYSTEM_EXT/etc/selinux/system_ext_sepolicy.cil"
    "$SYSTEM_EXT/etc/selinux/mapping/$VERS.cil"
    "$SYSTEM_EXT/etc/selinux/mapping/$VERS.compat.cil"
    "$WORK_DIR/product/etc/selinux/product_sepolicy.cil"
    "$WORK_DIR/product/etc/selinux/mapping/$VERS.cil"
    "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"
    "$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"
    "$WORK_DIR/odm/etc/selinux/odm_sepolicy.cil"
)

ARGS=()
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    REL="${f#"$WORK_DIR"/}"
    # The secilc packaged in Ubuntu predates the nlmsg extended permissions (libsepol 3.8)
    grep -v -F "(nlmsg " "$f" > "$TMP/${REL//\//_}"
    ARGS+=("$TMP/${REL//\//_}")
done

echo "Vendor SELinux version: $VERS" > "$OUT"
DROPPED=0
for i in $(seq 1 200); do
    if RESULT="$(secilc "${ARGS[0]}" -m -M true -G -N -c 30 "${ARGS[@]:1}" \
            -o "$TMP/policy" -f /dev/null 2>&1)"; then
        break
    fi

    LOC="$(grep -o -m 1 "at $TMP/[^ :]*:[0-9]*" <<< "$RESULT" | sed "s#^at $TMP/##")"
    if [ -z "$LOC" ]; then
        echo "$RESULT" >> "$OUT"
        DROPPED=-1
        break
    fi

    FILE="${LOC%:*}"
    LINE="${LOC##*:}"
    echo "$FILE: $(sed -n "${LINE}p" "$TMP/$FILE")" >> "$OUT"
    sed -i "${LINE}d" "$TMP/$FILE"
    DROPPED=$((DROPPED + 1))
done
rm -rf "$TMP"

cat "$OUT"
if [ "$DROPPED" != "0" ]; then
    echo "::error::SELinux policy does not compile, the ROM will not boot (see sepolicy.txt)"
    exit 1
fi
echo "SELinux policy compiles"
