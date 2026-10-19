#include "dm_language.h"
#include <ctype.h>
#include <string.h>

void dm_language_code(const char *tag, char out[8]) {
    char s[96] = {0};
    if (tag) for (size_t i = 0; tag[i] && i + 1 < sizeof s; i++) s[i] = tag[i] == '_' ? '-' : (char)tolower((unsigned char)tag[i]);
    const char *v = "en-US";
    if (!strncmp(s,"zh",2) && (!s[2] || s[2]=='-')) v = strstr(s,"hans") ? "zh-Hans" : strstr(s,"hant") || strstr(s,"-tw") || strstr(s,"-hk") || strstr(s,"-mo") ? "zh-Hant" : "zh-Hans";
    else if (!strncmp(s,"en",2) && (!s[2] || s[2]=='-')) v = strstr(s,"-gb") ? "en-GB" : "en-US";
    else if (!strncmp(s,"fr",2) && (!s[2] || s[2]=='-')) v = strstr(s,"-ca") ? "fr-CA" : "fr";
    else if (!strncmp(s,"pt",2) && (!s[2] || s[2]=='-')) v = strstr(s,"-br") ? "pt-BR" : "pt";
    else if (!strncmp(s,"es",2) && (!s[2] || s[2]=='-')) v = strstr(s,"-419") || strstr(s,"-mx") || strstr(s,"-us") ? "es-419" : "es";
    else { const char *simple[] = {"ja","de","it","ko","nl","ru"};
        for (size_t i=0;i<sizeof simple/sizeof *simple;i++) if (!strncmp(s,simple[i],2) && (!s[2] || s[2]=='-')) { v=simple[i];break; } }
    memset(out,0,8); memcpy(out,v,strlen(v));
}
