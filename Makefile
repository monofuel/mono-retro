.PHONY: check test test-audio build arm64
check:
	nim check src/hwtest.nim
	nim check src/launcher.nim
	nim check src/player.nim
	nim check tests/test_hardware.nim
	nim check tests/test_gamepad.nim
	nim check tests/test_audio_stream.nim
	nim check tests/test_launcher.nim
	nim check tests/test_player.nim
	nim check tests/test_playercore.nim
	nim check tests/test_playeraudio.nim
	nim check tests/test_playerds.nim
	nim check tests/test_playerstate.nim
	nim check tools/prepare_lost_in_blue.nim
test:
	mkdir -p build
	nim r tests/test_hardware.nim
	nim r tests/test_gamepad.nim
	nim r tests/test_launcher.nim
	nim r -o:build/test-player tests/test_player.nim
test-audio:
	nim r tests/test_audio_stream.nim
build:
	mkdir -p build
	nim c -o:build/hwtest src/hwtest.nim
arm64:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=fbdev,drm nim c -o:build/hwtest-arm64 src/hwtest.nim

.PHONY: desktop rg-sp rg-ds-plus handhelds combined combined-arm64
desktop:
	mkdir -p build
	MONO_RETRO_BACKENDS=x11 nim c -o:build/hwtest-desktop src/hwtest.nim
rg-sp:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=fbdev nim c -o:build/hwtest-rg-sp src/hwtest.nim
rg-ds-plus:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=drm nim c -o:build/hwtest-rg-ds-plus src/hwtest.nim
handhelds:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=fbdev,drm nim c -o:build/hwtest-handhelds src/hwtest.nim
combined:
	mkdir -p build
	MONO_RETRO_BACKENDS=x11,fbdev,drm nim c -o:build/hwtest-combined src/hwtest.nim
combined-arm64:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=x11,fbdev,drm nim c -o:build/hwtest-combined-arm64 src/hwtest.nim

.PHONY: launcher-desktop launcher-handhelds
launcher-desktop: desktop
	MONO_RETRO_BACKENDS=x11 nim c -o:build/mono-retro src/launcher.nim
	cp build/hwtest-desktop build/mono-retro-hwtest
launcher-handhelds: handhelds
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=fbdev,drm nim c -o:build/mono-retro-arm64 src/launcher.nim
	cp build/hwtest-handhelds build/mono-retro-hwtest-arm64

.PHONY: test-launcher-x11
test-launcher-x11: launcher-desktop
	nim r tests/integration_launcher_x11.nim

.PHONY: player-desktop player-rg-sp player-rg-ds-plus player-fixtures test-player test-player-x11
player-desktop:
	mkdir -p build
	MONO_RETRO_BACKENDS=x11 nim c -o:build/mono-retro-player src/player.nim
player-rg-sp:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=fbdev nim c -o:build/mono-retro-player-rg-sp src/player.nim
player-rg-ds-plus:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=drm nim c -o:build/mono-retro-player-rg-ds-plus src/player.nim
player-fixtures:
	mkdir -p build
	$(CC) -std=c11 -Wall -Wextra -Werror -shared -fPIC tests/fixtures/player_core.c -o build/player-fixture.so
	$(CC) -std=c11 -Wall -Wextra -Werror -shared -fPIC -DFULLPATH tests/fixtures/player_core.c -o build/player-fullpath.so
	$(CC) -std=c11 -Wall -Wextra -Werror -shared -fPIC -DOMIT_RUN tests/fixtures/player_core.c -o build/player-missing.so
test-player: player-fixtures prepare-lost-in-blue-tool
	nim r -o:build/test-player tests/test_player.nim
	nim r -o:build/test-playercore tests/test_playercore.nim
	ALSOFT_DRIVERS=null nim r -o:build/test-playeraudio tests/test_playeraudio.nim
	nim r -o:build/test-playerds tests/test_playerds.nim
	nim r -o:build/test-playerstate tests/test_playerstate.nim
	nim r -o:build/test-prepare-lost-in-blue tests/test_prepare_lost_in_blue.nim
test-player-x11: player-desktop player-fixtures
	nim r -o:build/integration-player-x11 tests/integration_player_x11.nim

DS_LAYOUT ?= combined
LOST_IN_BLUE_SOURCE ?= $(HOME)/Documents/Arcade/cartridge-dumps/DS/Lost in Blue
LOST_IN_BLUE_WORK = build/player-test/melonds-lost-in-blue
MELONDS_CORE = build/cores/melondsds-package/lib/retroarch/cores/melondsds_libretro.so
MELONDSDS_REV = 33c48260402865ef77667487528efd5ca7ce1233
MELONDSDS_SOURCE = build/sources/melondsds-1.2.0
MELONDSDS_ARM64 = build/cores/melondsds-arm64
CORE_JOBS ?= 8

.PHONY: core-melondsds-rg-ds-plus
core-melondsds-rg-ds-plus:
	mkdir -p build/sources
	test -d $(MELONDSDS_SOURCE)/.git || git clone --no-checkout https://github.com/JesseTG/melonds-ds.git $(MELONDSDS_SOURCE)
	git -C $(MELONDSDS_SOURCE) checkout --detach $(MELONDSDS_REV)
	git -C $(MELONDSDS_SOURCE) diff --exit-code HEAD --
	NIX_DONT_SET_RPATH=1 NIX_DONT_SET_RPATH_aarch64_unknown_linux_gnu=1 cmake \
	  -C $(CURDIR)/tools/melondsds-revisions.cmake \
	  -S $(MELONDSDS_SOURCE) -B $(MELONDSDS_ARM64) \
	  -DCMAKE_TOOLCHAIN_FILE=$(CURDIR)/tools/melondsds-arm64.cmake \
	  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	  -DFETCHCONTENT_UPDATES_DISCONNECTED=ON \
	  -DENABLE_OPENGL=OFF -DENABLE_JIT=ON -DENABLE_THREADED_RENDERER=ON \
	  -DENABLE_LTO_RELEASE=OFF -DBUILD_TESTING=OFF
	NIX_DONT_SET_RPATH=1 NIX_DONT_SET_RPATH_aarch64_unknown_linux_gnu=1 cmake \
	  --build $(MELONDSDS_ARM64) --target melondsds_libretro --parallel $(CORE_JOBS)
	@set -e; for source in $(MELONDSDS_SOURCE) $(MELONDSDS_ARM64)/_deps/*-src; do \
	  printf '%s ' "$$(basename "$$source")"; git -C "$$source" rev-parse HEAD; \
	done > $(MELONDSDS_ARM64)/SOURCES.txt

.PHONY: core-melondsds prepare-lost-in-blue-tool setup-lost-in-blue play-lost-in-blue
core-melondsds:
	mkdir -p build/cores
	nix-build '<nixpkgs>' -A libretro.melondsds --out-link build/cores/melondsds-package
prepare-lost-in-blue-tool:
	mkdir -p build
	nim c -o:build/prepare-lost-in-blue tools/prepare_lost_in_blue.nim
setup-lost-in-blue: core-melondsds prepare-lost-in-blue-tool
	build/prepare-lost-in-blue "$(LOST_IN_BLUE_SOURCE)" $(LOST_IN_BLUE_WORK)
play-lost-in-blue: player-desktop setup-lost-in-blue
	build/mono-retro-player --core:$(MELONDS_CORE) \
	  --rom:$(LOST_IN_BLUE_WORK)/LOST_IN_BLUE_ASKEA4_00.nds \
	  --save-dir:$(LOST_IN_BLUE_WORK)/saves --ds-layout:$(DS_LAYOUT)
