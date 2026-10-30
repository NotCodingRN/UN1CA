# com/sec/android/sdhms/performance/PerformanceFeature: treat SM8250 like SM8350
SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
    "smali/c4/c.smali" "replace" \
    '<clinit>()V' \
    'SM8350' \
    'SM8250'
# Restore SM8250 TABoostController
SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
    "smali/e4/o0.smali" "replaceall" \
    "TABoostControllerSM8350_SYSFS" \
    "TABoostControllerSM8250_SYSFS"
