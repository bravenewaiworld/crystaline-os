################################################################################
#
# exfatprogs-upstream
#
################################################################################

EXFATPROGS_UPSTREAM_VERSION = 1.4.3
EXFATPROGS_UPSTREAM_SOURCE = exfatprogs-$(EXFATPROGS_UPSTREAM_VERSION).tar.xz
EXFATPROGS_UPSTREAM_SITE = https://github.com/exfatprogs/exfatprogs/releases/download/$(EXFATPROGS_UPSTREAM_VERSION)
EXFATPROGS_UPSTREAM_LICENSE = GPL-2.0+
EXFATPROGS_UPSTREAM_LICENSE_FILES = COPYING
EXFATPROGS_UPSTREAM_CPE_ID_VENDOR = namjaejeon
EXFATPROGS_UPSTREAM_CPE_ID_PRODUCT = exfatprogs
EXFATPROGS_UPSTREAM_DEPENDENCIES = host-pkgconf util-linux

$(eval $(autotools-package))
