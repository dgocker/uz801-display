/*
 * router-display - status dashboard for the 128x128 SPI panel
 * of MSM8916 LTE sticks (GC9107 / fbtft).
 *
 * Renders one of two screens into a 128x128 RGB565 framebuffer on stdout:
 *   default : status dashboard  (signal, network, clients, battery, traffic)
 *   -Q      : Wi-Fi QR code with SSID and password
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <getopt.h>
#include <unistd.h>
#include <ctype.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include "qrcodegen.h"

#define WIDTH  128
#define HEIGHT 128

#define RGB565(r, g, b) ((((r) & 0xF8) << 8) | (((g) & 0xFC) << 3) | (((b) & 0xF8) >> 3))

/* palette */
#define C_BG        RGB565(  8,  12,  18)
#define C_CARD      RGB565( 18,  24,  33)
#define C_RULE      RGB565( 32,  42,  56)
#define C_TEXT      RGB565(230, 237, 243)
#define C_DIM       RGB565(125, 133, 144)
#define C_ACCENT    RGB565( 34, 211, 238)
#define C_GOOD      RGB565( 63, 185,  80)
#define C_WARN      RGB565(210, 153,  34)
#define C_BAD       RGB565(248,  81,  73)
#define C_UP        RGB565(255, 166,  87)
#define C_DOWN      RGB565( 88, 166, 255)
#define C_WHITE     RGB565(255, 255, 255)
#define C_BLACK     RGB565(  0,   0,   0)

#define MIN_MODULE_SIZE 2

typedef struct {
    uint16_t data[WIDTH * HEIGHT];
} Framebuffer;

typedef struct {
    char operator[32];
    char network_type[8];
    char ssid[64];
    char password[64];
    char ip[24];
    int  signal;        /* 0..100, -1 = unknown */
    int  rssi;          /* dBm, 0 = unknown     */
    int  clients;
    int  battery;       /* 0..100, -1 = no gauge */
    int  charging;
    int  up_kbps;
    int  down_kbps;
    int  show_qr;
} DisplayConfig;

/* ---------------------------------------------------------------- drawing */

static void fb_init(Framebuffer *fb, uint16_t color)
{
    for (int i = 0; i < WIDTH * HEIGHT; i++)
        fb->data[i] = color;
}

static void fb_put_pixel(Framebuffer *fb, int x, int y, uint16_t color)
{
    if (x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT)
        fb->data[y * WIDTH + x] = color;
}

/* alpha-blend `color` over the existing pixel, `a` = 0..255 */
static void fb_blend_pixel(Framebuffer *fb, int x, int y, unsigned char a, uint16_t color)
{
    if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT || a == 0)
        return;

    if (a == 255) {
        fb->data[y * WIDTH + x] = color;
        return;
    }

    uint16_t bg = fb->data[y * WIDTH + x];
    int bg_r = (bg >> 11) << 3, bg_g = ((bg >> 5) & 0x3F) << 2, bg_b = (bg & 0x1F) << 3;
    int fg_r = (color >> 11) << 3, fg_g = ((color >> 5) & 0x3F) << 2, fg_b = (color & 0x1F) << 3;

    int r = (fg_r * a + bg_r * (255 - a)) / 255;
    int g = (fg_g * a + bg_g * (255 - a)) / 255;
    int b = (fg_b * a + bg_b * (255 - a)) / 255;

    fb->data[y * WIDTH + x] = RGB565(r, g, b);
}

static void fb_rect(Framebuffer *fb, int x, int y, int w, int h, uint16_t color)
{
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            fb_put_pixel(fb, x + i, y + j, color);
}

/* filled rect with the four corner pixels dropped - reads as rounded at this size */
static void fb_round_rect(Framebuffer *fb, int x, int y, int w, int h, uint16_t color)
{
    fb_rect(fb, x, y, w, h, color);
    fb_put_pixel(fb, x, y, C_BG);
    fb_put_pixel(fb, x + w - 1, y, C_BG);
    fb_put_pixel(fb, x, y + h - 1, C_BG);
    fb_put_pixel(fb, x + w - 1, y + h - 1, C_BG);
}

/* ------------------------------------------------------------------- text */

/* decode one UTF-8 code point; advances *p past the sequence */
static unsigned long utf8_next(const char **p)
{
    const unsigned char *s = (const unsigned char *)*p;
    unsigned long cp = *s;
    int extra = 0;

    if (cp >= 0xF0)      { cp &= 0x07; extra = 3; }
    else if (cp >= 0xE0) { cp &= 0x0F; extra = 2; }
    else if (cp >= 0xC0) { cp &= 0x1F; extra = 1; }

    s++;
    while (extra-- && (*s & 0xC0) == 0x80)
        cp = (cp << 6) | (*s++ & 0x3F);

    *p = (const char *)s;
    return cp;
}

static void draw_text(Framebuffer *fb, FT_Face face, const char *text,
                      int x, int baseline, int size, uint16_t color)
{
    int pen = x;
    FT_Set_Pixel_Sizes(face, 0, size);

    for (const char *p = text; *p; ) {
        unsigned long cp = utf8_next(&p);
        if (FT_Load_Char(face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL))
            continue;

        FT_GlyphSlot g = face->glyph;
        for (unsigned int row = 0; row < g->bitmap.rows; row++)
            for (unsigned int col = 0; col < g->bitmap.width; col++)
                fb_blend_pixel(fb,
                               pen + g->bitmap_left + col,
                               baseline - g->bitmap_top + row,
                               g->bitmap.buffer[row * g->bitmap.pitch + col],
                               color);

        pen += g->advance.x >> 6;
    }
}

static int text_width(FT_Face face, const char *text, int size)
{
    int w = 0;
    FT_Set_Pixel_Sizes(face, 0, size);

    for (const char *p = text; *p; ) {
        unsigned long cp = utf8_next(&p);
        if (FT_Load_Char(face, cp, FT_LOAD_DEFAULT))
            continue;
        w += face->glyph->advance.x >> 6;
    }
    return w;
}

static void draw_text_right(Framebuffer *fb, FT_Face face, const char *text,
                            int right, int baseline, int size, uint16_t color)
{
    draw_text(fb, face, text, right - text_width(face, text, size), baseline, size, color);
}

static void draw_text_center(Framebuffer *fb, FT_Face face, const char *text,
                             int baseline, int size, uint16_t color)
{
    draw_text(fb, face, text, (WIDTH - text_width(face, text, size)) / 2, baseline, size, color);
}

/* --------------------------------------------------------------- widgets */

static uint16_t level_color(int pct)
{
    if (pct < 0)  return C_DIM;
    if (pct < 25) return C_BAD;
    if (pct < 55) return C_WARN;
    return C_GOOD;
}

/* four bars of growing height, filled according to `pct` */
static void draw_signal_bars(Framebuffer *fb, int x, int bottom, int pct)
{
    const int bar_w = 5, gap = 3;
    const int heights[4] = { 5, 8, 11, 14 };
    int lit = (pct < 0) ? 0 : (pct + 24) / 25;   /* 0..4 */
    uint16_t on = level_color(pct);

    for (int i = 0; i < 4; i++) {
        int h = heights[i];
        int bx = x + i * (bar_w + gap);
        fb_round_rect(fb, bx, bottom - h, bar_w, h, (i < lit) ? on : C_RULE);
    }
}

static void draw_battery(Framebuffer *fb, int x, int y, int pct, int charging)
{
    const int w = 22, h = 11;
    uint16_t col = charging ? C_ACCENT : level_color(pct);

    /* shell + terminal nub */
    fb_round_rect(fb, x, y, w, h, C_RULE);
    fb_rect(fb, x + 1, y + 1, w - 2, h - 2, C_BG);
    fb_rect(fb, x + w, y + 3, 2, h - 6, C_RULE);

    if (pct < 0)
        return;

    int fill = ((w - 4) * pct) / 100;
    if (fill < 1 && pct > 0)
        fill = 1;
    fb_rect(fb, x + 2, y + 2, fill, h - 4, col);
}

/* small triangle: dir -1 = up, +1 = down */
static void draw_arrow(Framebuffer *fb, int x, int y, int dir, uint16_t color)
{
    for (int i = 0; i < 4; i++) {
        int w = (dir < 0) ? (i * 2 + 1) : (7 - i * 2);
        fb_rect(fb, x + 3 - w / 2, y + i, w, 1, color);
    }
}

static void format_speed(char *buf, size_t n, int kbps)
{
    if (kbps >= 1024)
        snprintf(buf, n, "%.1fM", kbps / 1024.0);
    else
        snprintf(buf, n, "%dK", kbps);
}

/* ------------------------------------------------------------- QR screen */

static int draw_qr(Framebuffer *fb, const char *text, int top, int box)
{
    uint8_t qr[qrcodegen_BUFFER_LEN_MAX];
    uint8_t tmp[qrcodegen_BUFFER_LEN_MAX];

    if (!qrcodegen_encodeText(text, tmp, qr, qrcodegen_Ecc_LOW,
                              qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX,
                              qrcodegen_Mask_AUTO, true))
        return 0;

    int modules = qrcodegen_getSize(qr);
    int scale = box / modules;
    if (scale < MIN_MODULE_SIZE)
        return 0;

    int size = modules * scale;
    int ox = (WIDTH - size) / 2;

    /* quiet zone: QR needs a light border to scan reliably */
    fb_rect(fb, ox - 3, top - 3, size + 6, size + 6, C_WHITE);

    for (int r = 0; r < modules; r++)
        for (int c = 0; c < modules; c++)
            if (qrcodegen_getModule(qr, c, r))
                fb_rect(fb, ox + c * scale, top + r * scale, scale, scale, C_BLACK);

    return size;
}

static void render_qr_screen(Framebuffer *fb, DisplayConfig *cfg, FT_Face face)
{
    char payload[320];

    fb_init(fb, C_BG);

    draw_text_center(fb, face, "Wi-Fi", 12, 12, C_ACCENT);

    snprintf(payload, sizeof(payload), "WIFI:T:WPA;S:%s;P:%s;;", cfg->ssid, cfg->password);

    int qr_px = draw_qr(fb, payload, 20, 84);
    int y = (qr_px ? 20 + qr_px + 3 : 40);

    draw_text_center(fb, face, cfg->ssid, y + 14, 12, C_TEXT);

    if (cfg->password[0])
        draw_text_center(fb, face, cfg->password, y + 27, 11, C_DIM);
    else
        draw_text_center(fb, face, "без пароля", y + 27, 11, C_DIM);
}

/* ------------------------------------------------------------- dashboard */

static void render_dashboard(Framebuffer *fb, DisplayConfig *cfg, FT_Face face)
{
    char buf[64], up[16], down[16];

    fb_init(fb, C_BG);

    /* --- header: operator + network badge ------------------------------ */
    const char *op = cfg->operator[0] ? cfg->operator : "нет сети";
    draw_text(fb, face, op, 4, 14, 13, cfg->operator[0] ? C_TEXT : C_DIM);

    if (cfg->network_type[0]) {
        int tw = text_width(face, cfg->network_type, 10);
        int bw = tw + 9;
        fb_round_rect(fb, WIDTH - bw - 4, 4, bw, 13, C_ACCENT);
        draw_text(fb, face, cfg->network_type, WIDTH - bw, 14, 10, C_BG);
    }

    /* --- signal -------------------------------------------------------- */
    draw_signal_bars(fb, 4, 36, cfg->signal);

    if (cfg->rssi)
        snprintf(buf, sizeof(buf), "%d dBm", cfg->rssi);
    else if (cfg->signal >= 0)
        snprintf(buf, sizeof(buf), "%d%%", cfg->signal);
    else
        snprintf(buf, sizeof(buf), "—");
    draw_text(fb, face, buf, 40, 36, 12, level_color(cfg->signal));

    fb_rect(fb, 4, 43, WIDTH - 8, 1, C_RULE);

    /* --- network block ------------------------------------------------- */
    draw_text(fb, face, cfg->ssid[0] ? cfg->ssid : "Wi-Fi выкл", 4, 58, 12,
              cfg->ssid[0] ? C_TEXT : C_DIM);

    draw_text(fb, face, cfg->ip[0] ? cfg->ip : "—", 4, 73, 12, C_DIM);

    /* clients: up to 5 dots, then the number */
    int dots = cfg->clients > 5 ? 5 : cfg->clients;
    for (int i = 0; i < dots; i++)
        fb_round_rect(fb, 4 + i * 7, 82, 5, 5, C_ACCENT);

    snprintf(buf, sizeof(buf), "%d", cfg->clients);
    draw_text(fb, face, buf, dots ? 4 + dots * 7 + 3 : 4, 88, 12,
              cfg->clients ? C_TEXT : C_DIM);

    fb_rect(fb, 4, 96, WIDTH - 8, 1, C_RULE);

    /* --- footer: battery + traffic ------------------------------------- */
    draw_battery(fb, 4, 104, cfg->battery, cfg->charging);

    if (cfg->battery >= 0) {
        snprintf(buf, sizeof(buf), "%d%%", cfg->battery);
        draw_text(fb, face, buf, 32, 113, 11,
                  cfg->charging ? C_ACCENT : level_color(cfg->battery));
    }

    format_speed(up, sizeof(up), cfg->up_kbps);
    format_speed(down, sizeof(down), cfg->down_kbps);

    int dw = text_width(face, down, 10);
    draw_text_right(fb, face, down, WIDTH - 4, 124, 10, C_DIM);
    draw_arrow(fb, WIDTH - 4 - dw - 8, 117, +1, C_DOWN);

    int uw = text_width(face, up, 10);
    draw_text_right(fb, face, up, WIDTH - 4, 112, 10, C_DIM);
    draw_arrow(fb, WIDTH - 4 - uw - 8, 105, -1, C_UP);
}

/* ------------------------------------------------------------------ main */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options] > /dev/fb0\n"
        "  -n NAME   operator name\n"
        "  -t TYPE   network type (4G/3G/2G)\n"
        "  -q NUM    signal quality 0..100\n"
        "  -r NUM    signal strength, dBm (negative)\n"
        "  -s SSID   Wi-Fi SSID\n"
        "  -p PASS   Wi-Fi password\n"
        "  -i IP     LAN address\n"
        "  -C NUM    connected clients\n"
        "  -b NUM    battery 0..100 (-1: no gauge)\n"
        "  -c        charging\n"
        "  -u NUM    upload kbit/s\n"
        "  -d NUM    download kbit/s\n"
        "  -Q        draw the Wi-Fi QR screen instead of the dashboard\n",
        prog);
}

int main(int argc, char *argv[])
{
    DisplayConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.signal = -1;
    cfg.battery = -1;

    int opt;
    while ((opt = getopt(argc, argv, "n:t:q:r:s:p:i:C:b:cu:d:Qh")) != -1) {
        switch (opt) {
        case 'n': strncpy(cfg.operator, optarg, sizeof(cfg.operator) - 1); break;
        case 't': strncpy(cfg.network_type, optarg, sizeof(cfg.network_type) - 1); break;
        case 'q': cfg.signal = atoi(optarg); break;
        case 'r': cfg.rssi = atoi(optarg); break;
        case 's': strncpy(cfg.ssid, optarg, sizeof(cfg.ssid) - 1); break;
        case 'p': strncpy(cfg.password, optarg, sizeof(cfg.password) - 1); break;
        case 'i': strncpy(cfg.ip, optarg, sizeof(cfg.ip) - 1); break;
        case 'C': cfg.clients = atoi(optarg); break;
        case 'b': cfg.battery = atoi(optarg); break;
        case 'c': cfg.charging = 1; break;
        case 'u': cfg.up_kbps = atoi(optarg); break;
        case 'd': cfg.down_kbps = atoi(optarg); break;
        case 'Q': cfg.show_qr = 1; break;
        default:  usage(argv[0]); return 1;
        }
    }

    FT_Library ft;
    FT_Face face;

    if (FT_Init_FreeType(&ft)) {
        fprintf(stderr, "freetype init failed\n");
        return 1;
    }

    const char *fonts[] = {
        "/usr/share/fonts/ttf-dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/ttf-dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/DejaVuSans-Bold.ttf",
        NULL
    };

    int loaded = 0;
    for (int i = 0; fonts[i]; i++) {
        if (!FT_New_Face(ft, fonts[i], 0, &face)) {
            loaded = 1;
            break;
        }
    }
    if (!loaded) {
        fprintf(stderr, "no usable font found\n");
        FT_Done_FreeType(ft);
        return 1;
    }

    static Framebuffer fb;
    if (cfg.show_qr)
        render_qr_screen(&fb, &cfg, face);
    else
        render_dashboard(&fb, &cfg, face);

    fwrite(fb.data, sizeof(fb.data), 1, stdout);

    FT_Done_Face(face);
    FT_Done_FreeType(ft);
    return 0;
}
