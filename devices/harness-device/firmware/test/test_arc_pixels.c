// Golden 24 px pixels from the dense reference48 renderer. Optimizations
// must preserve every coverage/color value at all supported text lengths.
#include "../main/ui/habitat/terminal.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#ifndef HT_UPDATE_ARC_GOLDEN
static const uint64_t expected[] = {
#include "arc_pixels.inc"
};
#endif
static uint16_t pixels[HT_WIDTH * HT_HEIGHT];
#ifndef HT_UPDATE_ARC_GOLDEN
// One upper-arc label in a given face: its pixel hash and inked pixel count, ink kept inside r 230.
static uint64_t face_hash(const char *text, const ht_arc_face_t *face, unsigned *ink)
{
    ht_scene_t scene; ht_scene_clear(&scene,ht_rgb(0x183c25));
    ht_arc_title_face(&scene,ht_rgb(0xc8a9f0),text,face);
    assert(scene.count==1 && !strcmp(scene.runs[0].text,text)); // no '?' substitution
    assert(scene.runs[0].font==face->mono);
    ht_raster(&scene,(ht_rect_t){0,0,HT_WIDTH,HT_HEIGHT},pixels);
    // The panel's own corners are not the background colour; ink is whatever a blank scene lacks.
    static uint16_t blank[HT_WIDTH * HT_HEIGHT];
    ht_scene_clear(&scene,ht_rgb(0x183c25));
    ht_raster(&scene,(ht_rect_t){0,0,HT_WIDTH,HT_HEIGHT},blank);
    uint64_t hash=UINT64_C(14695981039346656037);
    *ink=0;
    for (int y=0;y<HT_HEIGHT;y++) for (int x=0;x<HT_WIDTH;x++) {
        uint16_t v=pixels[y*HT_WIDTH+x];
        hash^=v; hash*=UINT64_C(1099511628211);
        if (v!=blank[y*HT_WIDTH+x]) {
            (*ink)++;
            assert((x-233)*(x-233)+(y-233)*(y-233)<230*230);
        }
    }
    return hash;
}
static void roboto_face(void)
{
    unsigned a,b;
    assert(ht_arc_roboto.mono==&ht_rmono_24 && ht_arc_geist.mono==&ht_mono_24);
    // ht_arc_title is exactly the GeistMono face.
    ht_scene_t x,y; ht_scene_clear(&x,ht_rgb(0x183c25)); ht_scene_clear(&y,ht_rgb(0x183c25));
    ht_arc_title(&x,ht_rgb(0xc8a9f0),"harness-pro");
    ht_arc_title_face(&y,ht_rgb(0xc8a9f0),"harness-pro",&ht_arc_geist);
    assert(!memcmp(&x.runs[0],&y.runs[0],sizeof x.runs[0]));
    // Same text, different face: different pixels, and the mask cache must not hand one face the
    // other's mask (alternating would expose a cache keyed on the text alone).
    const char *names[] = {"harness-pro","Claude Code ~/go/src","Quick fox 0123456789 -> ^"};
    for (unsigned i=0;i<sizeof names/sizeof names[0];i++) {
        uint64_t g=face_hash(names[i],&ht_arc_geist,&a), r=face_hash(names[i],&ht_arc_roboto,&b);
        assert(a && b && g!=r);
        assert(face_hash(names[i],&ht_arc_geist,&a)==g && face_hash(names[i],&ht_arc_roboto,&b)==r);
    }
    // Vietnamese: all 98 letters are drawn from Roboto Mono, never '?' (tofu) or blank.
    uint64_t q=face_hash("?",&ht_arc_roboto,&a);
    static const unsigned tail[]={0x102,0x103,0x110,0x111,0x1a0,0x1a1,0x1af,0x1b0};
    for (unsigned n=0;n<0x5a+sizeof tail/sizeof tail[0];n++) {
        unsigned c=n<0x5a?0x1ea0+n:tail[n-0x5a];
        char one[4]={0};
        if (c<0x800) { one[0]=(char)(0xc0|(c>>6)); one[1]=(char)(0x80|(c&63)); }
        else { one[0]=(char)(0xe0|(c>>12)); one[1]=(char)(0x80|((c>>6)&63)); one[2]=(char)(0x80|(c&63)); }
        assert(face_hash(one,&ht_arc_roboto,&a)!=q && a>0);
    }
}
#endif
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
    roboto_face();
    puts("arc pixels: Roboto Mono face differs from GeistMono, stays in r230, 98 Vietnamese letters inked");
    printf("arc pixels: all %u upper/lower 24 px angle/color hashes preserved\n",2*HT_ARC_COLS);
#endif
}
