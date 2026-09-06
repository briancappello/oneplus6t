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
