// Exercise the actual packed cache, its hard capacity bound, and exact pixels
// against the habitat.79 dense-cache algorithm, adapted to the 24 px metrics.
#include "../main/ui/habitat/terminal.c"
#include "reference79/reference.h"
#include <assert.h>
#include <stdio.h>

static uint16_t dense[HT_ARC_WIDTH * HT_ARC_HEIGHT + 2];
static uint16_t packed[HT_ARC_WIDTH * HT_ARC_HEIGHT + 2];
static uint32_t seed = 0x80cace;
static unsigned next(void) { seed = seed * 1664525u + 1013904223u; return seed; }
static size_t encode(char *p, unsigned cp)
{
    if (cp < 128) { p[0]=(char)cp; return 1; }
    if (cp < 2048) { p[0]=(char)(0xc0|(cp>>6));p[1]=(char)(0x80|(cp&63));return 2; }
    p[0]=(char)(0xe0|(cp>>12));p[1]=(char)(0x80|((cp>>6)&63));p[2]=(char)(0x80|(cp&63));return 3;
}
static void compare(const char *text, int edge, bool partial)
{
    ht_scene_t scene;
    ht_scene_clear(&scene,ht_rgb(next()&0xffffff));
    ht_text(&scene,25,edge ? 345 : 20,416,&ht_mono_20,ht_rgb(0xabcdef),scene.background,
            "Underlying text stays under gaps");
    if(edge) ht_arc_status(&scene,ht_rgb(next()&0xffffff),text);
    else ht_arc_title(&scene,ht_rgb(next()&0xffffff),text);
    ht_rect_t rect={HT_ARC_X,edge ? HT_HEIGHT-HT_ARC_Y-HT_ARC_HEIGHT : HT_ARC_Y,
                    HT_ARC_WIDTH,HT_ARC_HEIGHT};
    if(partial) {
        int dx=next()%300,dy=next()%96;
        rect.x+=dx;rect.y+=dy;rect.w=1+next()%(HT_ARC_WIDTH-dx);rect.h=1+next()%(HT_ARC_HEIGHT-dy);
    }
    const size_t pixels=(size_t)rect.w*rect.h;
    dense[0]=packed[0]=0x61ac;dense[pixels+1]=packed[pixels+1]=0x8ace;
    ht79_raster(&scene,rect,dense+1);ht_raster(&scene,rect,packed+1);
    assert(dense[0]==0x61ac&&packed[0]==0x61ac);
    assert(dense[pixels+1]==0x8ace&&packed[pixels+1]==0x8ace);
    assert(!memcmp(dense+1,packed+1,pixels*sizeof *packed));
}
int main(void)
{
    assert(ht_mono_24.width==HT_ARC_CELL_WIDTH && ht_mono_24.height==HT_ARC_CELL_HEIGHT);
    unsigned peak=0;
    for(int count=1;count<=HT_ARC_COLS;count++) for(int edge=0;edge<2;edge++) {
        arc_cache_t cache={0};
        ht_run_t run={.arc=edge+1,.y=edge ? HT_HEIGHT-HT_ARC_Y-HT_ARC_HEIGHT : HT_ARC_Y};
        assert(arc_pack_geometry(&run,&cache,count));
        if(cache.mask_bytes>peak) peak=cache.mask_bytes;
        for(int y=0;y<HT_ARC_HEIGHT;y++) for(int h=0;h<2;h++) {
            arc_span_t span=cache.spans[y][h];
            assert(span.first<=ARC_HALF&&span.last<=ARC_HALF);
            if(span.first<span.last) assert(span.offset+(span.last-span.first+3)/4<=cache.mask_bytes);
        }
        char text[HT_ARC_COLS+1];memset(text,'W',count);text[count]=0;
        compare(text,edge,false);
        memset(text,' ',count);compare(text,edge,false);
    }
    assert(peak==4538);
    assert(sizeof arc_caches==12576); // was 12552: the cache entry holds a face pointer (8-byte aligned on the host) instead of a byte
    for(unsigned glyph=32;glyph<=258;glyph++) {
        unsigned cp=glyph==258 ? 0x2192 : glyph==257 ? 0xe000 : glyph==256 ? 0x2197 : glyph;
        for(int length=HT_ARC_COLS-1;length<=HT_ARC_COLS;length++) for(int edge=0;edge<2;edge++) {
            char text[HT_TEXT_BYTES];size_t n=0;
            for(int i=0;i<length;i++) n+=encode(text+n,cp);
            text[n]=0;compare(text,edge,false);
        }
    }
    for(int trial=0;trial<4000;trial++) {
        char text[HT_TEXT_BYTES];size_t n=0;unsigned length=1+next()%HT_ARC_COLS;
        for(unsigned i=0;i<length;i++) {
            unsigned cp=32+next()%228;
            n+=encode(text+n,cp==256 ? 0x2197 : cp==257 ? 0xe000 : cp==258 ? 0x2192 : cp==259 ? 0x2014 : cp);
        }
        text[n]=0;compare(text,trial&1,trial%3!=0);
    }
    printf("Packed arcs: all %u geometries <=%u/%uB; 227 glyphs at every angle, 4000 mixed/clipped labels match dense pixels; caches=%zuB PASS\n",2*HT_ARC_COLS,peak,ARC_MASK_BYTES,sizeof arc_caches);
}
