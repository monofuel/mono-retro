#include "../../third_party/libretro.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* An independent C core exercises the actual public ABI used by Nim. */
static retro_environment_t environment;
static retro_video_refresh_t video;
static retro_audio_sample_t audio;
static retro_audio_sample_batch_t batch;
static retro_input_poll_t poll_input;
static retro_input_state_t input;
static unsigned char memory[16];
static unsigned frames;
static char mode;

static void trace(const char *event, unsigned value)
{
    const char *path = getenv("MONO_RETRO_FIXTURE_TRACE");
    if (!path) return;
    FILE *file = fopen(path, "a");
    if (!file) abort();
    fprintf(file, "%s=%u\n", event, value);
    if (fclose(file)) abort();
}

unsigned retro_api_version(void) { return RETRO_API_VERSION; }
void retro_set_environment(retro_environment_t callback) { environment = callback; }
void retro_set_video_refresh(retro_video_refresh_t callback) { video = callback; }
void retro_set_audio_sample(retro_audio_sample_t callback) { audio = callback; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t callback) { batch = callback; }
void retro_set_input_poll(retro_input_poll_t callback) { poll_input = callback; }
void retro_set_input_state(retro_input_state_t callback) { input = callback; }
void retro_set_controller_port_device(unsigned port, unsigned device)
{
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) abort();
}
void retro_init(void)
{
    memset(memory, 0xff, sizeof(memory));
    frames = 0;
    trace("init", 1);
    struct retro_variable variables[] = {{"fixture_option", "Example; first|second"}, {NULL, NULL}};
    if (!environment(RETRO_ENVIRONMENT_SET_VARIABLES, variables)) abort();
    struct retro_variable variable = {"fixture_option", NULL};
    if (!environment(RETRO_ENVIRONMENT_GET_VARIABLE, &variable) || strcmp(variable.value, "first")) abort();
    unsigned version = 99;
    if (!environment(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version) || version) abort();
    struct retro_log_callback logging;
    if (!environment(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &logging)) abort();
    logging.log(RETRO_LOG_INFO, "Fixture log bridge: %d %s\n", 42, "ok");
}
void retro_deinit(void) { trace("deinit", 1); }
void retro_get_system_info(struct retro_system_info *info)
{
    *info = (struct retro_system_info){"Player fixture", "1", "test",
#ifdef FULLPATH
        true,
#else
        false,
#endif
        false};
}
void retro_get_system_av_info(struct retro_system_av_info *info)
{
    *info = (struct retro_system_av_info){{3, 2, 3, 2, 1.5f}, {60, 48000}};
}
bool retro_load_game(const struct retro_game_info *game)
{
#ifdef FULLPATH
    if (game->data || game->size || !game->path) abort();
    FILE *file = fopen(game->path, "rb");
    if (!file) abort();
    mode = (char)fgetc(file);
    fclose(file);
#else
    if (!game->data || !game->size || !game->path) abort();
    mode = *(const char *)game->data;
#endif
    if (mode == 'F') return false;
    enum retro_pixel_format format = mode == 'B' ? 99 : RETRO_PIXEL_FORMAT_XRGB8888;
    environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
    trace("load", 1);
    return true;
}
void retro_unload_game(void) { trace("unload", 1); }
void *retro_get_memory_data(unsigned id) { return id == RETRO_MEMORY_SAVE_RAM ? memory : NULL; }
size_t retro_get_memory_size(unsigned id)
{
    return id == RETRO_MEMORY_SAVE_RAM ? (mode == 'S' && frames ? 8 : sizeof(memory)) : 0;
}
#ifndef OMIT_RUN
void retro_run(void)
{
    /* Deliberate row padding detects incorrect packed-row assumptions. */
    const uint32_t pixels[] = {0xff0000, 0x00ff00, 0x0000ff, 0xdeadbeef,
                              0xffffff, 0x808080, 0x000000, 0xdeadbeef};
    const int16_t samples[] = {100, -100, 200, -200};
    poll_input();
    unsigned mask = (uint16_t)input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_MASK);
    if (input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A) != !!(mask & 256)) abort();
    if (input(1, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A)) abort();
    if (!frames) trace("loaded_byte", memory[4]);
    trace("input", mask);
    memory[0] = mask & 255;
    memory[1] = mask >> 8;
    memory[4] = 123;
    frames++;
    video(mode == 'H' ? RETRO_HW_FRAME_BUFFER_VALID : (mode == 'D' && frames > 1 ? NULL : pixels), 3, 2, sizeof(uint32_t) * 4);
    trace("video_returned", frames);
    audio(10, -10);
    if (batch(samples, 2) != 2) abort();
    if (mode == 'Q') environment(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
}
#endif
