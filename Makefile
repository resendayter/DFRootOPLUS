
SHELL       := bash
.SHELLFLAGS := -euo pipefail -c
MAKEFLAGS   += --no-print-directory

ARCH      := aarch64
ABI       := arm64-v8a
ENGINE    := podman

KMIS := \
    android12-5.10 \
    android13-5.10 \
    android13-5.15 \
    android14-5.15 \
    android14-6.1 \
    android15-6.6 \
    android16-6.12 \
    android17-6.18

DDK_WF      := .github/workflows/build.yml

DDK_IMAGE   ?= $(shell awk '/image: ghcr\.io\//{gsub(/.*image: /,"");gsub(/:.*$$/,"");print;exit}' $(DDK_WF))
DDK_RELEASE ?= $(shell awk '/image: ghcr\.io\/ylarod\/ddk-min:/{sub(/.*-/,"");print;exit}' $(DDK_WF))

SIGN_PASS  := df-ksu
SIGN_ALIAS := df-ksu

LKM_SRCS := lkm/dfroot.c lkm/Makefile
LKM_KOS  := $(KMIS:%=app/src/main/jni/ko/dfroot-%.ko)
LKM_STAMP := out/.lkm-build.stamp

APK_SRCS := $(wildcard app/src/main/java/df/root/*.java \
                          app/src/main/jni/*.c app/src/main/jni/*.h \
                          app/src/main/jni/*.S app/src/main/jni/*.inc \
                          app/src/main/res/layout/*.xml \
                          app/src/main/res/values/*.xml) \
            app/src/main/AndroidManifest.xml \
            app/build.gradle.kts \
            app/src/main/jni/CMakeLists.txt

APK := out/DFRootOPLUS.apk

.PHONY: all clean

all: $(APK)

keystore.jks:
	keytool -genkeypair -keystore $@ -storetype JKS \
	    -storepass $(SIGN_PASS) -keypass $(SIGN_PASS) \
	    -alias $(SIGN_ALIAS) -keyalg RSA -keysize 2048 -validity 10000 \
	    -dname "CN=DFRootOPLUS"

signing.properties: keystore.jks
	printf 'KEYSTORE_FILE=../keystore.jks\nKEYSTORE_PASSWORD=%s\nKEY_ALIAS=%s\nKEY_PASSWORD=%s\n' \
	    $(SIGN_PASS) $(SIGN_ALIAS) $(SIGN_PASS) > $@

$(LKM_KOS): $(LKM_STAMP)

$(LKM_STAMP): $(LKM_SRCS)
	@mkdir -p out
	@printf '\n\033[1;35m══  Building LKMs  ══\033[0m\n'
	@set -e; \
	for kmi in $(KMIS); do \
	    build_dir=$$(mktemp -d "/tmp/dfroot-$$-$$kmi.XXXXXX"); \
	    trap 'rm -rf "$$build_dir"' EXIT; \
	    printf '\n\033[1;33m▶  PODMAN  %s\033[0m\n' "$$kmi"; \
	    mkdir -p "$$build_dir/lkm"; \
	    cp lkm/dfroot.c lkm/Makefile "$$build_dir/lkm/"; \
	    $(ENGINE) run --rm --pid=host --network=none \
	        -v "$$build_dir":/proj \
	        -e KMI=$$kmi \
	        $(DDK_IMAGE):$$kmi-$(DDK_RELEASE) \
	        bash -c 'set -e; \
	            cd /proj/lkm; \
	            make -j$$(nproc); \
	            mkdir -p /proj/out; \
	            cp dfroot.ko /proj/out/dfroot-$$KMI.ko; \
	            make clean; \
	        '; \
	    mkdir -p app/src/main/jni/ko; \
	    cp "$$build_dir/out/dfroot-$$kmi.ko" \
	        "app/src/main/jni/ko/dfroot-$$kmi.ko"; \
	    rm -rf "$$build_dir"; \
	    trap - EXIT; \
	    printf '\033[1;32m  ✔  DF LKM   %s\033[0m\n' "$$kmi"; \
	done
	@touch $@

$(APK): signing.properties $(LKM_KOS) $(APK_SRCS)
	@printf '\n\033[1;36m══  DFRootOPLUS APK  ══\033[0m\n'
	@printf '\033[1;35m  → gradle assembleRelease\033[0m\n'
	./gradlew :app:assembleRelease
	mkdir -p $(dir $@)
	cp app/build/outputs/apk/release/DFRootOPLUS_*.apk $@
	@printf '\033[1;32m  ✔  DFRootOPLUS APK  →  $@\033[0m\n'

clean:
	rm -f app/src/main/jni/splicehelper
	rm -f lkm/*.o lkm/*.cmd lkm/.*.cmd lkm/*.mod lkm/*.mod.c lkm/*.lto.o lkm/modules.order lkm/Module.symvers lkm/dfroot.lds lkm/dfroot.ko
	rm -rf app/src/main/jni/ko
	rm -f .project app/.project app/.classpath
	rm -rf .settings app/.settings
	rm -rf build out app/.cxx app/build .gradle
