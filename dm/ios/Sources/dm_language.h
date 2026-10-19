#pragma once
#include <stddef.h>
// Maps an iOS BCP-47 preference to a supported Horizon language code (8-byte ABI).
void dm_language_code(const char *tag, char out[8]);
