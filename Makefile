.PHONY: check test test-audio build arm64
check:
	nim check src/hwtest.nim
	nim check tests/test_hardware.nim
	nim check tests/test_gamepad.nim
	nim check tests/test_audio_stream.nim
test:
	nim r tests/test_hardware.nim
	nim r tests/test_gamepad.nim
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
