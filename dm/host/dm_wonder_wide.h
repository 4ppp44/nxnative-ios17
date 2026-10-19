#pragma once
#include <stdint.h>

// Wonder 1.2.1 only. These are host policy constants, not D2R camera addresses.
#define DM_WONDER_WIDE_BUILD "ff773e90972d544eb79406eaa65396d5"
#define DM_WONDER_WIDE_WIDTH 1560u
#define DM_WONDER_WIDE_HEIGHT 720u
int dm_wonder_wide_capable(void);
int dm_wonder_wide_active(void);
void dm_wonder_wide_prepare(void);
