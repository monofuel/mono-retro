#include "../../third_party/libretro.h"
#include "../../include/mono_retro_libretro.h"
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
#ifdef RA_FIXTURE
static unsigned char memory[8192];
static unsigned char system_memory[131072];
#else
static unsigned char memory[16];
#endif
static unsigned frames;
static char mode;
static bool xbgr;

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
#ifdef RA_FIXTURE
    memset(system_memory, 0, sizeof(system_memory));
    bool achievements = true;
    environment(42u | 0x10000u, &achievements);
#endif
    xbgr = false;
    trace("init", 1);
    struct retro_variable variables[] = {
        {"fixture_option", "Example; first|second"},
        {"decompbound_dual_screen", "Companion; disabled|enabled"},
        {"melonds_render_mode", "Renderer; software|opengl"},
        {"melonds_screen_layout1", "Layout; top-bottom|bottom-top"},
        {"melonds_screen_gap", "Gap; 0|1"},
        {"melonds_number_of_screen_layouts", "Layouts; 1|2"},
        {"melonds_touch_mode", "Touch; touch|auto"},
        {"melonds_show_cursor", "Cursor; always|disabled"},
        {"melonds_mic_input", "Mic; silence|noise"},
        {NULL, NULL}
    };
    if (!environment(RETRO_ENVIRONMENT_SET_VARIABLES, variables)) return;
    struct retro_variable variable = {"fixture_option", NULL};
    if (!environment(RETRO_ENVIRONMENT_GET_VARIABLE, &variable)) abort();
    /* Re-registration must retain the requested value. */
    if (!environment(RETRO_ENVIRONMENT_SET_VARIABLES, variables)) return;
    if (!environment(RETRO_ENVIRONMENT_GET_VARIABLE, &variable)) abort();
    trace("option_second", !strcmp(variable.value, "second"));
    unsigned version = 99;
    if (!environment(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version) || version) abort();
    struct retro_log_callback logging;
    if (!environment(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &logging)) abort();
    logging.log(RETRO_LOG_INFO, "Fixture log bridge: %d %s\n", 42, "ok");
}
void retro_deinit(void) { trace("deinit", 1); }
void retro_get_system_info(struct retro_system_info *info)
{
    *info = (struct retro_system_info){
#ifdef RA_FIXTURE
        "Decompbound",
#else
        "Player fixture",
#endif
        "1", "test",
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
    if (mode == 'N') info->geometry = (struct retro_game_geometry){256, 384, 256, 384, 2.0f / 3.0f};
    if (mode == 'E' || mode == 'G') info->geometry = (struct retro_game_geometry){256, 448, 256, 448, 4.0f / 7.0f};
    /* Integer presentation must retain native pixels even with a different aspect hint. */
    if (mode == 'T') info->geometry.aspect_ratio = 2.0f;
    if (mode == 'I') info->timing.sample_rate = 0;
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
#ifdef RA_FIXTURE
    /* A deliberately hostile fixture proves hashing never borrows core input. */
    ((unsigned char *)game->data)[game->size - 1] ^= 0xff;
#endif
#endif
    if (mode == 'F') return false;
    if (mode == 'E') {
        struct retro_variable variable = {"decompbound_dual_screen", NULL};
        if (!environment(RETRO_ENVIRONMENT_GET_VARIABLE, &variable) ||
            !variable.value || strcmp(variable.value, "enabled")) abort();
    }
    if (mode == 'C' || mode == 'X' || mode == 'G') {
        uint32_t unsupported = 0;
        enum retro_pixel_format standard = 99;
        if (environment(MONO_RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, NULL) ||
            environment(MONO_RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &unsupported) ||
            environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, NULL)) abort();
        if (mode == 'C') {
            uint32_t private_format = MONO_RETRO_PIXEL_FORMAT_XBGR8888;
            if (environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &private_format)) abort();
            if (environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &standard)) abort();
            trace("format_rejected", 1);
        } else {
            uint32_t format = MONO_RETRO_PIXEL_FORMAT_XBGR8888;
            xbgr = environment(MONO_RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
            trace("xbgr_accepted", xbgr);
            /* Rejections must retain the previously accepted private format. */
            if (xbgr && (environment(MONO_RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &unsupported) ||
                environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &standard) ||
                environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format))) abort();
        }
    }
    if (!xbgr) {
        enum retro_pixel_format format = mode == 'B' ? 99 : RETRO_PIXEL_FORMAT_XRGB8888;
        if (!environment(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format)) return false;
    }
    if (mode == 'C') {
        uint32_t unsupported = 0;
        if (environment(MONO_RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &unsupported)) abort();
    }
    trace("load", 1);
    return true;
}
void retro_unload_game(void) { trace("unload", 1); }
#ifndef FULLPATH
bool retro_unserialize(const void *data, size_t size)
{
    const char expected[] = "fixture-state";
    if (!data || size != sizeof(expected) - 1 || memcmp(data, expected, size)) return false;
    frames = 0;
#ifdef RA_FIXTURE
    memset(system_memory, 0, sizeof(system_memory));
#endif
    memory[4] = 42;
    trace("state_loaded", 42);
    return true;
}
#endif
void *retro_get_memory_data(unsigned id) {
#ifdef RA_FIXTURE
    if (id == RETRO_MEMORY_SYSTEM_RAM) return system_memory;
#endif
    return id == RETRO_MEMORY_SAVE_RAM ? memory : NULL;
}
size_t retro_get_memory_size(unsigned id)
{
#ifdef RA_FIXTURE
    if (id == RETRO_MEMORY_SYSTEM_RAM) return sizeof(system_memory);
#endif
    return id == RETRO_MEMORY_SAVE_RAM ? (mode == 'S' && frames ? 8 : sizeof(memory)) : 0;
}
#ifndef OMIT_RUN
void retro_run(void)
{
    /* Deliberate row padding detects incorrect packed-row assumptions. */
    uint32_t pixels[] = {0xff0000, 0x00ff00, 0x0000ff, 0xdeadbeef,
                              0xffffff, 0x808080, 0x000000, 0xdeadbeef};
    int16_t samples[1600] = {100, -100, 200, -200};
    const size_t audio_frames = mode == 'T' || mode == 'N' || mode == 'E' || mode == 'G' ? 799 : 2;
    poll_input();
    unsigned mask = (uint16_t)input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_MASK);
    if (input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A) != !!(mask & 256)) abort();
    if (input(1, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_A)) abort();
    if (!frames) trace("loaded_byte", memory[4]);
    trace("input", mask);
    trace("pointer_pressed", input(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED));
    trace("pointer_x", (uint16_t)input(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_X));
    trace("pointer_y", (uint16_t)input(0, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_Y));
    if (input(1, RETRO_DEVICE_POINTER, 0, RETRO_DEVICE_ID_POINTER_PRESSED)) abort();
    if (input(0, RETRO_DEVICE_POINTER, 1, RETRO_DEVICE_ID_POINTER_PRESSED)) abort();
    memory[0] = mask & 255;
    memory[1] = mask >> 8;
    memory[4] = 123;
    frames++;
#ifdef RA_FIXTURE
    system_memory[0] = frames;
#endif
    if (mode == 'R' && frames == 2) {
        struct retro_system_av_info info;
        retro_get_system_av_info(&info);
        info.timing.sample_rate = 44100;
        if (!environment(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &info)) abort();
    }
    if (mode == 'N' || mode == 'E' || mode == 'G') {
        static uint32_t ds_pixels[448][257];
        const unsigned panel_height = mode == 'N' ? 192 : 224;
        for (unsigned y = 0; y < panel_height * 2; y++)
            for (unsigned x = 0; x < 256; x++)
                ds_pixels[y][x] = y < panel_height ?
                    (x < 128 ? (xbgr ? 0xff0000ff : 0xff0000) : (xbgr ? 0xff00ff00 : 0x00ff00)) :
                    (x < 128 ? (xbgr ? 0xffff0000 : 0x0000ff) : (xbgr ? 0xffffffff : 0xffffff));
        video(ds_pixels, 256, panel_height * 2, sizeof(ds_pixels[0]));
    } else if (mode == 'V') {
        /* A new colour, a duplicate with an older recycled buffer, then new pixels. */
        pixels[0] = frames == 1 ? 0xff0000 : (frames == 2 ? 0x00ff00 : 0x0000ff);
        video(frames == 3 ? NULL : pixels, 3, 2, sizeof(uint32_t) * 4);
    } else {
        if (xbgr) {
            pixels[0] = 0xff0000ff;
            pixels[1] = 0xff00ff00;
            pixels[2] = 0xffff0000;
            pixels[4] = 0xffffffff;
            pixels[5] = 0xff808080;
            pixels[6] = 0xff000000;
        }
        video(mode == 'H' ? RETRO_HW_FRAME_BUFFER_VALID : ((mode == 'D' || mode == 'X') && frames > 1 ? NULL : pixels), 3, 2, sizeof(uint32_t) * 4);
    }
    trace("video_returned", frames);
    audio(10, -10);
    if (batch(mode == 'U' ? NULL : samples, audio_frames) != audio_frames) abort();
    memset(samples, 0, sizeof(samples));
    trace("audio_returned", 1);
    if (mode == 'Q') environment(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
}
#endif
