.PHONY: check test test-audio build arm64
check:
	nim check src/hwtest.nim
	nim check tests/test_hardware.nim
	nim check tests/test_audio_stream.nim
test:
	nim r tests/test_hardware.nim
test-audio:
	nim r tests/test_audio_stream.nim
build:
	mkdir -p build
	nim c -o:build/hwtest src/hwtest.nim
arm64:
	mkdir -p build
	MONO_RETRO_TARGET=arm64 nim c -o:build/hwtest-arm64 src/hwtest.nim
