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

.PHONY: player-desktop player-rg-ds-plus player-fixtures test-player test-player-x11
player-desktop:
	mkdir -p build
	MONO_RETRO_BACKENDS=x11 nim c -o:build/mono-retro-player src/player.nim
player-rg-ds-plus:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 MONO_RETRO_BACKENDS=drm nim c -o:build/mono-retro-player-rg-ds-plus src/player.nim
player-fixtures:
	mkdir -p build
	$(CC) -std=c11 -Wall -Wextra -Werror -shared -fPIC tests/fixtures/player_core.c -o build/player-fixture.so
	$(CC) -std=c11 -Wall -Wextra -Werror -shared -fPIC -DFULLPATH tests/fixtures/player_core.c -o build/player-fullpath.so
	$(CC) -std=c11 -Wall -Wextra -Werror -shared -fPIC -DOMIT_RUN tests/fixtures/player_core.c -o build/player-missing.so
test-player: player-fixtures
	nim r -o:build/test-player tests/test_player.nim
	nim r -o:build/test-playercore tests/test_playercore.nim
	ALSOFT_DRIVERS=null nim r -o:build/test-playeraudio tests/test_playeraudio.nim
test-player-x11: player-desktop player-fixtures
	nim r -o:build/integration-player-x11 tests/integration_player_x11.nim
