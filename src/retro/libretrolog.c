#include <stdarg.h>
#include <stdio.h>
#include "../../third_party/libretro.h"

/* Keep the C variadic calling convention out of Nim callbacks. */
void mono_retro_log(enum retro_log_level level, const char *format, ...)
{
    if (level < RETRO_LOG_INFO)
        return;
    va_list arguments;
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
}
