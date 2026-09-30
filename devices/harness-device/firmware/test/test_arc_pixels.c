// Golden 24 px pixels from the dense reference48 renderer. Optimizations
// must preserve every coverage/color value at all supported text lengths.
#include "../main/ui/habitat/terminal.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>

#ifndef HT_UPDATE_ARC_GOLDEN
static const uint64_t expected[] = {
#include "arc_pixels.inc"
};
#endif
static uint16_t pixels[HT_WIDTH * HT_HEIGHT];
int main(void)
{
    for (int edge=0;edge<2;edge++) for (int length=1;length<=HT_ARC_COLS;length++) {
        char text[HT_ARC_COLS+1];
        for (int i=0;i<length;i++) text[i]=32+(i*17+length*7)%95;
        text[length]=0;
        ht_scene_t scene; ht_scene_clear(&scene,ht_rgb(0x183c25));
        if(edge) ht_arc_status(&scene,ht_rgb(0xc8a9f0),text);
        else ht_arc_title(&scene,ht_rgb(0xc8a9f0),text);
        ht_raster(&scene,(ht_rect_t){0,0,HT_WIDTH,HT_HEIGHT},pixels);
        uint64_t hash=UINT64_C(14695981039346656037);
        for (unsigned i=0;i<sizeof pixels/sizeof pixels[0];i++) {
            hash^=pixels[i]; hash*=UINT64_C(1099511628211);
        }
#ifdef HT_UPDATE_ARC_GOLDEN
        printf("UINT64_C(0x%016" PRIx64 "),\n",hash);
#else
        assert(hash==expected[edge*HT_ARC_COLS+length-1]);
#endif
    }
#ifndef HT_UPDATE_ARC_GOLDEN
    printf("arc pixels: all %u upper/lower 24 px angle/color hashes preserved\n",2*HT_ARC_COLS);
#endif
}
