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
#   ro.adb.secure=0         adbd accepts any host without the RSA prompt.
#                           userdebug already permits this; the prompt is a
#                           default, not a security boundary, on this variant.
#   persist.sys.usb.config  adb function selected from the first boot.
ifeq ($(LINEAGE_DEVELOPER_MODE),true)
PRODUCT_SOONG_NAMESPACES += vendor/extra/developer-mode
PRODUCT_PACKAGES += developer-mode
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.adb.secure=0 \
    persist.sys.usb.config=adb
endif
