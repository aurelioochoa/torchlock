PROJECT       := torchlock
TAGLINE       := instant lock screen flashlight tweak for jailbroken iOS 6
HELP_VARS      = THEOS=$(THEOS)  PORT=$(PORT)
HELP_EXAMPLE   = make run PORT=2222
HELP_PAD      := 14

# ─── Preamble ────────────────────────────────────────────────────────────────
# -e stops a recipe at the first failing command; -o pipefail stops a gate that
# pipes through a filter from reporting the filter's exit code instead of the
# command's — without it, a suite that fails into `tail` "passes".
SHELL         := /usr/bin/env bash
.SHELLFLAGS   := -eo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS     += --no-print-directory

# ─── Colour ──────────────────────────────────────────────────────────────────
# MAKE_TERMOUT (GNU Make >= 4.1) is set only when stdout is a terminal, and is
# the only reliable test available here: `test -t 1` inside $(shell ...) always
# reports false, because make captures that command's stdout through a pipe.
# So `make help | less` and CI logs stay clean. NO_COLOR disables, FORCE_COLOR
# overrides both.
COLOR ?= $(if $(MAKE_TERMOUT),1,0)
ifdef NO_COLOR
  COLOR := 0
endif
ifdef FORCE_COLOR
  COLOR := 1
endif
ifeq ($(COLOR),1)
  # Real ESC bytes, so a plain `echo` renders them without needing -e.
  C_HEAD := $(shell printf '\033[1m')
  C_CMD  := $(shell printf '\033[36m')
  C_OK   := $(shell printf '\033[32m')
  C_WARN := $(shell printf '\033[33m')
  C_ERR  := $(shell printf '\033[31m')
  C_DIM  := $(shell printf '\033[2m')
  C_OFF  := $(shell printf '\033[0m')
endif

# Explains why a core verb does not apply here, then fails.
NA = @printf '  $(C_ERR)make $@$(C_OFF) does not apply to $(PROJECT).\n  $(C_DIM)%s$(C_OFF)\n\n' $(1) >&2; exit 2

# Width of the target-name column in help; widen it where names are long.
HELP_PAD ?= 18

# PROJECT, TAGLINE, HELP_VARS and HELP_EXAMPLE are interpolated into a
# single-quoted shell string below, so none of them may contain an apostrophe.
##@ General
.PHONY: help
help: ## List the available targets
	@printf '\n  $(C_HEAD)$(PROJECT)$(C_OFF) — $(TAGLINE)\n'
	@printf '  $(C_DIM)usage: make <target>$(C_OFF)\n'
	@awk 'BEGIN { FS = ":.*?## " } \
	  /^##@ / { printf "\n  $(C_HEAD)%s$(C_OFF)\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_.-]+:.*?## / { printf "    $(C_CMD)%-$(HELP_PAD)s$(C_OFF) %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@printf '\n  $(C_DIM)Variables:$(C_OFF) $(HELP_VARS)\n'
	@printf '  $(C_DIM)Example:$(C_OFF)   $(HELP_EXAMPLE)\n\n'

# ─── End of the shared block ─────────────────────────────────────────────────

# torchlock — development tasks.
#
# The tweak itself is a Theos project in tweak/; this file wraps it in the
# standard verbs. Theos lives outside the repo (default ~/theos) because it is
# shared between projects; `make setup` installs it there if it is missing.
#
# `run`, `dev`, `smoke` and `uninstall` talk to an iPhone plugged in over USB:
# iproxy forwards PORT on this machine to the phone's SSH, and ssh asks for the
# root password. Nothing is ever sent to the phone by `build` or `check`.

THEOS ?= $(HOME)/theos
export THEOS

PORT ?= 2222
TWEAK := tweak
PKG_DIR := $(TWEAK)/packages

# The 10.3 SDK is the newest that still ships armv7 stubs; the 9.3 one does not
# link with the toolchain's ld64-609. See docs/BUILDING.md.
SDK_VERSION    := 10.3
SDK_RELEASE    := master-146e41f
TOOLCHAIN_TAG  := test-210562a
TOOLCHAIN_DIR   = $(THEOS)/toolchain/linux/iphone

# iOS 6 dpkg reads gzip; keep packages in the format the phone is sure to know.
THEOS_MAKE = $(MAKE) -C $(TWEAK) THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip

# The phone runs OpenSSH from 2013: it only speaks these legacy algorithms.
# Its host key changes with every jailbreak restore, so it is not pinned.
SSH = ssh -p $(PORT) \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
	-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
	-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \
	-o Ciphers=+aes128-cbc,3des-cbc root@localhost

# Newest package of each flavour, as shell snippets: make expands a whole recipe
# before running its first line, so a $(shell ...) here would still see the
# package from the previous build. Theos names debug builds *+debug_*.
RELEASE_DEB = $$(ls -t $(PKG_DIR)/*.deb 2>/dev/null | grep -v '+debug_' | head -1)
DEBUG_DEB   = $$(ls -t $(PKG_DIR)/*+debug_*.deb 2>/dev/null | head -1)

##@ Setup
.PHONY: setup
setup: ## Install Theos, the Linux iOS toolchain and the iOS 10.3 SDK into THEOS
	@command -v iproxy >/dev/null || printf '  $(C_WARN)iproxy not found$(C_OFF) — install libimobiledevice to deploy over USB.\n'
	@if [ -d '$(THEOS)/makefiles' ]; then \
	  printf '  theos already at %s\n' '$(THEOS)'; \
	else \
	  git clone --quiet --recursive --depth 1 https://github.com/theos/theos.git '$(THEOS)'; \
	fi
	@if [ -x '$(TOOLCHAIN_DIR)/bin/clang' ]; then \
	  printf '  toolchain already at %s\n' '$(TOOLCHAIN_DIR)'; \
	else \
	  mkdir -p '$(TOOLCHAIN_DIR)'; \
	  curl -fsSL https://github.com/L1ghtmann/llvm-project/releases/download/$(TOOLCHAIN_TAG)/iOSToolchain-x86_64.tar.xz \
	    | tar -xJ -C '$(TOOLCHAIN_DIR)' --strip-components=2; \
	fi
	@if [ -d '$(THEOS)/sdks/iPhoneOS$(SDK_VERSION).sdk' ]; then \
	  printf '  iPhoneOS%s.sdk already present\n' '$(SDK_VERSION)'; \
	else \
	  mkdir -p '$(THEOS)/sdks'; \
	  curl -fsSL https://github.com/theos/sdks/releases/download/$(SDK_RELEASE)/iPhoneOS$(SDK_VERSION).sdk.tar.xz \
	    | tar -xJ -C '$(THEOS)/sdks'; \
	fi
	@printf '  $(C_OK)ready$(C_OFF) — make build\n'

##@ Development
.PHONY: dev
dev: ## Debug build (adds the debug Activator listener), install it, respring
	$(THEOS_MAKE) package DEBUG=1
	@$(MAKE) deploy DEB="$(DEBUG_DEB)"

.PHONY: build
build: ## Release package into tweak/packages
	$(THEOS_MAKE) package FINALPACKAGE=1
	@printf '  $(C_OK)built$(C_OFF) %s\n' "$(RELEASE_DEB)"

.PHONY: run
run: build ## Install the release package on the iPhone and respring
	@$(MAKE) deploy DEB="$(RELEASE_DEB)"

##@ Device
# One ssh session for upload + install + respring, so the password is asked once.
# No pipes on the phone side: it has no head/tail, and a dpkg killed by SIGPIPE
# installs nothing while looking like it ran.
.PHONY: deploy
deploy: ## Install DEB=<path> on the iPhone and respring
	@test -n '$(DEB)' && test -f '$(DEB)' || { printf '  $(C_ERR)no package$(C_OFF) — pass DEB=<path> or run make build\n' >&2; exit 1; }
	@$(MAKE) forward
	@printf '  installing %s\n' '$(DEB)'
	$(SSH) 'cat > /tmp/torchlock.deb && dpkg -i /tmp/torchlock.deb; s=$$?; rm -f /tmp/torchlock.deb; [ $$s -eq 0 ] && killall -9 SpringBoard; exit $$s' < '$(DEB)'

.PHONY: smoke
smoke: forward ## On the phone: toggle the torch on, wait 3s, toggle it off
	$(SSH) 'activator send com.aurelio.torchlock.toggle && sleep 3 && activator send com.aurelio.torchlock.toggle'
	@printf '  the torch should have lit for about three seconds\n'

.PHONY: uninstall
uninstall: forward ## Remove TorchLock from the iPhone and respring
	$(SSH) 'dpkg -r com.aurelio.torchlock && killall -9 SpringBoard'

# Probe the port, not the process list: `pgrep -f 'iproxy PORT 22'` matches this
# recipe's own shell, whose command line contains the same words, so it always
# "finds" an iproxy and never starts one.
.PHONY: forward
forward:
	@command -v iproxy >/dev/null || { printf '  $(C_ERR)iproxy not found$(C_OFF) — install libimobiledevice\n' >&2; exit 1; }
	@(exec 3<>/dev/tcp/127.0.0.1/$(PORT)) 2>/dev/null || { \
	  nohup iproxy $(PORT) 22 >/dev/null 2>&1 & \
	  for i in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>/dev/tcp/127.0.0.1/$(PORT)) 2>/dev/null && exit 0; sleep 0.3; done; \
	  printf '  $(C_ERR)iproxy did not start on port %s$(C_OFF)\n' '$(PORT)' >&2; exit 1; }

##@ Gates
.PHONY: test
test: ## Run the test suite once
	$(call NA,'There are no unit tests: the tweak only runs inside SpringBoard on a device. make smoke exercises it on the connected iPhone.')

.PHONY: check
# Cleans first so the gate always compiles: up-to-date objects would pass it
# without -Werror ever seeing the source.
check: ## Fast gate: compile the tweak with warnings as errors
	$(THEOS_MAKE) clean
	$(THEOS_MAKE) FINALPACKAGE=1 ADDITIONAL_CFLAGS=-Werror

.PHONY: verify
verify: check build ## Full gate: check, then a production build

.PHONY: fmt
fmt: ## Format the tree in place
	$(call NA,'No formatter is configured; Tweak.x follows the Theos tab style by hand.')

##@ Cleaning
.PHONY: clean
clean: ## Remove build output and packages, never the phone or THEOS
	$(THEOS_MAKE) clean
	rm -rf $(TWEAK)/.theos $(PKG_DIR)

.PHONY: distclean
distclean: clean ## clean; Theos itself is shared and left in place
	@printf '  THEOS at %s is shared with other projects and was left alone\n' '$(THEOS)'
