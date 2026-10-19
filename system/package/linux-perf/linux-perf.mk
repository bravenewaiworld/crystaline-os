################################################################################
#
# linux-perf
#
################################################################################

# perf works with older kernels than its own, so it needn't match ours (4.9).
LINUX_PERF_VERSION = 6.18.0
LINUX_PERF_SOURCE = perf-$(LINUX_PERF_VERSION).tar.xz
LINUX_PERF_SITE = https://cdn.kernel.org/pub/linux/kernel/tools/perf/v$(LINUX_PERF_VERSION)
LINUX_PERF_LICENSE = GPL-2.0
LINUX_PERF_LICENSE_FILES = COPYING
LINUX_PERF_DEPENDENCIES = host-flex host-bison host-pkgconf host-python3 elfutils zlib zstd

# perf turns on each optional library it finds in the staging directory or on the PC (a JDK), so
# all of those we don't want are turned off here; otherwise what perf can do would depend on what
# else happens to be built. Kept: elfutils (symbols, and call stacks with --call-graph dwarf), zlib
# and zstd (compressed files). libtraceevent is off because it only reads kernel tracing, which
# our kernel doesn't have (CONFIG_FTRACE).
LINUX_PERF_MAKE_FLAGS = \
	ARCH=arm64 \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	HOSTCC="$(HOSTCC)" \
	JOBS=$(PARALLEL_JOBS) \
	prefix=/usr \
	WERROR=0 \
	BUILD_BPF_SKEL=0 \
	NO_LIBTRACEEVENT=1 \
	NO_LIBPYTHON=1 \
	NO_SLANG=1 \
	NO_LIBUNWIND=1 \
	NO_LIBNUMA=1 \
	NO_LZMA=1 \
	NO_LIBBABELTRACE=1 \
	NO_CAPSTONE=1 \
	NO_LIBLLVM=1 \
	NO_LIBPFM4=1 \
	NO_LIBDEBUGINFOD=1 \
	NO_SDT=1 \
	NO_JVMTI=1 \
	NO_SHELLCHECK=1

define LINUX_PERF_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE1) $(LINUX_PERF_MAKE_FLAGS) -C $(@D)/tools/perf
endef

define LINUX_PERF_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/tools/perf/perf $(TARGET_DIR)/usr/bin/perf
endef

$(eval $(generic-package))
