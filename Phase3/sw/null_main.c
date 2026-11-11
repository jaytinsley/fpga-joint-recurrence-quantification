/* Bare-metal driver for the independence-baseline experiment (Cortex-A53 core 0, no OS).
 * For each window k of sw/null_tables.h (one random pairing of two separate recordings) it runs the board three times on the
 * same samples: both channels, channel x alone (eps_y = max), channel y alone (eps_x = max), and logs the off-diagonal
 * recurrence counts rr_joint, rr_x, rr_y next to the values the integer model expects. Samples are in OCM at SAMPLE_BASE,
 * window k at byte offset k * NS * 8 (8 bytes per time step, {y, x}). Log at LOG_BASE, 8 words per window from word 8:
 *   hw_j hw_x hw_y exp_j exp_x exp_y status cycles(joint run).  status: 0 ok, 1 count mismatch, 2 timeout.
 */
#include "null_tables.h"

typedef unsigned int u32;
typedef unsigned long long u64;

#define CORE      0x80000000UL
#define DMA       0x80100000UL
#define RQA       (CORE + 0x20000UL)
#define RT        (CORE + 0x60000UL)
#define CLKC      (CORE + 0x80000UL)
#define SAMPLE_BASE 0xFFFD0000UL
#define LOG_BASE  0xFFFCF000UL

#define R32(a)    (*(volatile u32 *)(a))
#define W32(a, v) (*(volatile u32 *)(a) = (u32)(v))

static u64 now(void)
{
    u32 hi, lo, hi2;
    do { hi = R32(CLKC + 4); lo = R32(CLKC); hi2 = R32(CLKC + 4); } while (hi != hi2);
    return ((u64)hi << 32) | lo;
}

/* mode 0: joint, 1: x only, 2: y only. Returns the rr_count, or 0xFFFFFFFF on timeout. */
static u32 run_window(int w, int mode, u32 *cycles)
{
    u64 t0;
    u32 st;
    W32(CORE + 0x008, NS);              W32(CORE + 0x00C, T_mx[w]);       W32(CORE + 0x010, T_tx[w]);
    W32(CORE + 0x014, mode == 2 ? 0xFFFFFFFFu : T_e2x[w]);
    W32(CORE + 0x024, T_my[w]);         W32(CORE + 0x028, T_ty[w]);
    W32(CORE + 0x02C, mode == 1 ? 0xFFFFFFFFu : T_e2y[w]);
    W32(CORE + 0x018, 2);               W32(CORE + 0x01C, 2);
    W32(CORE + 0x034, T_base_x[w]);     W32(CORE + 0x038, T_base_y[w]);   W32(CORE + 0x03C, T_n[w]);
    W32(RT + 0x00, 0x2);                /* disable, clear counters and flags */
    W32(RT + 0x08, 0); W32(RT + 0x0C, 0);
    W32(DMA + 0x00, 0x4);               /* DMA reset (idle at this point: the previous window was consumed exactly) */
    while (R32(DMA + 0x00) & 0x4) { }
    W32(DMA + 0x00, 0x1);
    W32(DMA + 0x18, (u32)(SAMPLE_BASE + (u64)w * NS * 8)); W32(DMA + 0x1C, 0);
    W32(RT + 0x00, 1u);                 /* enable, backpressure */
    t0 = now();
    W32(DMA + 0x28, NS * 8u);
    for (;;) {
        st = R32(RT + 0x04);
        if (st & 1u) break;
        if (now() - t0 > 150000000ULL) return 0xFFFFFFFFu;    /* 1 s */
    }
    *cycles = (u32)(now() - t0);
    {
        u32 rr = R32(RQA + 0x008);
        W32(RT + 0x00, 1u | 4u);        /* acknowledge */
        W32(RT + 0x00, 0u);
        return rr;
    }
}

int main(void)
{
    volatile u32 *L = (volatile u32 *)LOG_BASE;
    int w;
    L[0] = 0; L[1] = 0; L[2] = NWIN; L[3] = R32(CORE + 0x48);
    for (w = 0; w < NWIN; w++) {
        volatile u32 *r = L + 8 + 8 * w;
        u32 cyc = 0, cyc2, hj, hx, hy, status = 0;
        L[1] = (u32)(w + 1);
        hj = run_window(w, 0, &cyc);
        hx = run_window(w, 1, &cyc2);
        hy = run_window(w, 2, &cyc2);
        if (hj == 0xFFFFFFFFu || hx == 0xFFFFFFFFu || hy == 0xFFFFFFFFu) status = 2;
        else if (hj != T_rr_j[w] || hx != T_rr_x[w] || hy != T_rr_y[w]) status = 1;
        r[0] = hj; r[1] = hx; r[2] = hy; r[3] = T_rr_j[w]; r[4] = T_rr_x[w]; r[5] = T_rr_y[w]; r[6] = status; r[7] = cyc;
    }
    L[1] = 0xFFFFu;
    L[0] = 0x52544C47u;
    return 0;
}
