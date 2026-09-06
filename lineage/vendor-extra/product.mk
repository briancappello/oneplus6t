# Local additions to the LineageOS product, installed by build-lineage.sh at
# vendor/extra/product.mk in the source tree.
#
# LineageOS inherits this file if it exists (vendor/lineage/config/common.mk:
# `inherit-product-if-exists, vendor/extra/product.mk`). That is the sanctioned
# hook for exactly this, and it means nothing upstream is modified: the device
# tree stays clean, repo sync never sees a dirty checkout, and a pin bump never
# has to carry a patch.

# Google apps from MindTheGapps (vendor/gapps, pinned in local_manifest.xml).
# Brings GmsCore, Phonesky (Play Store), Google's SetupWizard, Velvet and the
# supporting permissions/sysconfig. Required: carrier phone-number activation
# on this device needs a Play-installed app and cannot proceed without it.
$(call inherit-product, vendor/gapps/arm64/arm64-vendor.mk)

# Developer mode. Gated on LINEAGE_DEVELOPER_MODE, which build-lineage.sh
# exports only for --developer-mode; a plain build never sees it and ships
# stock. Everything below is all-or-nothing on purpose: a half-developer
# image is the confusing kind.
#
#   developer-mode          init oneshot that seeds Developer options, USB
#                           debugging and Rooted debugging into /data on the
#                           first boot of that /data (see
#                           vendor/extra/developer-mode/). These are Settings
#                           rows and a file, not properties, so a format of
#                           userdata wiped them on every reflash before this.
#   persist.sys.usb.config  adb function selected from the first boot.
#
# Promptless adb (ro.adb.secure=0) is NOT set here. LineageOS's own
# vendor/lineage/config/common.mk emits ro.adb.secure=0 when
# WITH_ADB_INSECURE is defined and =1 otherwise; setting it here as well
# produced "found duplicate sysprop assignments" and the build refuses
# conflicting values rather than taking the last one. build-lineage.sh sets
# WITH_ADB_INSECURE=true alongside LINEAGE_DEVELOPER_MODE so the upstream
# knob does it.
ifeq ($(LINEAGE_DEVELOPER_MODE),true)
PRODUCT_SOONG_NAMESPACES += vendor/extra/developer-mode
PRODUCT_PACKAGES += developer-mode
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.usb.config=adb
endif
