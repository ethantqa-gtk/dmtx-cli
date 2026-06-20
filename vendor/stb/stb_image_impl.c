/* Single translation unit that provides the stb_image implementation.
 * Kept separate from main.zig's @cImport so stb_image's implementation
 * is compiled exactly once as a normal C object file. */
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
