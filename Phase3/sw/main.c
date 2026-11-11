/* Bare-metal driver for the real-time JRP front end, Cortex-A53 core 0, no OS and no board support package.
 *
 * Replaces the JTAG host in the loop: it configures jrp_rt_core and the AXI DMA through the PS M_AXI_HPM0_LPD port
 * (core at 0x80000000, DMA control at 0x80100000), waits for each window result, checks the seven counters and the
 * DET / LAM histograms against the golden values (expected.h) and acknowledges, so the next window can start while the
 * samples keep arriving. It repeats the same 6-window stream at several sample rates (the pacer in jrp_ingest releases
 * one sample every `period` clocks) in drop mode, as a sensor that cannot be stalled would behave, and logs per run
 * the frames done, dropped samples, windows with a gap, ring occupancy peak, mismatches and the time from "window
 * ready" to "acknowledged". The log is plain memory at LOG_BASE; the host reads it with xsdb (hw_sw_run.tcl).
 * Samples (8 bytes per time step {y, x}) are in OCM at SAMPLE_BASE.
 */
#include "expected.h"

typedef unsigned int u32;
typedef unsigned long long u64;

#define CORE      0x80000000UL
#define DMA       0x80100000UL
#define RQA       (CORE + 0x20000UL)
#define RT        (CORE + 0x60000UL)
#define CLKC      (CORE + 0x80000UL)
#define SAMPLE_BASE 0xFFFD0000UL
#define LOG_BASE  0xFFFCF000UL
#define HIST_K    8192

#define R32(a)    (*(volatile u32 *)(a))
#define W32(a, v) (*(volatile u32 *)(a) = (u32)(v))

static u64 now(void)
{
    u32 hi, lo, hi2;
    do { hi = R32(CLKC + 4); lo = R32(CLKC); hi2 = R32(CLKC + 4); } while (hi != hi2);
    return ((u64)hi << 32) | lo;
}

/* ---- log ---- */
#define LOG_WORDS_PER_RUN 24
static volatile u32 *const logw = (volatile u32 *)LOG_BASE;

/* Which golden window does the result on the core equal? Returns 0..NWIN-1, or -1 if it matches none (counters first, then every bin). */
static int match_window(void)
{
    static const u32 off[7] = {0x008, 0x010, 0x018, 0x01C, 0x020, 0x028, 0x02C};
    u32 c[7];
    int k, b, w;
    for (k = 0; k < 7; k++) c[k] = R32(RQA + off[k]);
    if (R32(RQA + 0x038) != (u32)CASE_N * (u32)CASE_N) return -1;
    for (w = 0; w < NWIN; w++) {
        int ok = 1;
        for (k = 0; k < 7; k++) if (c[k] != exp_cnt[w][k]) { ok = 0; break; }
        if (!ok) continue;
        for (b = 0; b < HIST_BINS && ok; b++) {
            if (R32(RQA + 0x1000 + 4 * b) != exp_det[w][b]) ok = 0;
            else if (R32(RQA + 0x1000 + 4 * HIST_K + 4 * b) != exp_lam[w][b]) ok = 0;
        }
        if (ok) return w;
    }
    return -1;
}

static void configure_core(void)
{
    W32(CORE + 0x008, CASE_NS);  W32(CORE + 0x00C, CASE_MX); W32(CORE + 0x010, CASE_TX); W32(CORE + 0x014, CASE_E2X);
    W32(CORE + 0x024, CASE_MY);  W32(CORE + 0x028, CASE_TY); W32(CORE + 0x02C, CASE_E2Y);
    W32(CORE + 0x018, 2);        W32(CORE + 0x01C, 2);
    W32(CORE + 0x034, CASE_BASE_X); W32(CORE + 0x038, CASE_BASE_Y); W32(CORE + 0x03C, CASE_N);
}

/* one run of the stream at the given pacer period; drop selects drop mode, check selects window-by-window comparison */
static void run(int idx, u32 period, int drop, int check)
{
    volatile u32 *L = logw + 8 + idx * LOG_WORDS_PER_RUN;
    u32 ctrl_en = 1u | (drop ? 8u : 0u);
    u32 mism = 0, checked = 0, windows = 0, st, dsr;
    u64 t_ack, lat_max = 0, lat_ack_max = 0, proc_max = 0, t0, tr;
    u32 seq = 0;
    u32 idle_count = 0;

    W32(RT + 0x00, 0x2 | (drop ? 8u : 0u));          /* disable, clear counters and flags */
    W32(RT + 0x08, 0);  W32(RT + 0x0C, period);
    W32(DMA + 0x00, 0x4);                              /* DMA reset */
    while (R32(DMA + 0x00) & 0x4) { }
    W32(RT + 0x00, ctrl_en);
    W32(DMA + 0x00, 0x1);                              /* run */
    W32(DMA + 0x18, (u32)SAMPLE_BASE); W32(DMA + 0x1C, 0);
    t0 = now();
    W32(DMA + 0x28, NWIN * CASE_NS * 8u);              /* starts the transfer */

    for (;;) {
        st = R32(RT + 0x04);
        if (st & 1u) {
            u64 tres, trdy;
            int w;
            tr = now();
            /* timestamps first: the ring may already hold the next window and overwrite T_READY once we acknowledge */
            tres = ((u64)R32(RT + 0x2C) << 32) | R32(RT + 0x28);
            trdy = ((u64)R32(RT + 0x24) << 32) | R32(RT + 0x20);
            w = check ? match_window() : -2;
            if (windows < 8) seq |= (u32)((w + 1) & 0xF) << (4 * windows);
            if (w < 0 && check) mism++;
            if (w >= 0) checked++;
            W32(RT + 0x00, ctrl_en | 4u);              /* acknowledge */
            t_ack = now();
            if (tres - trdy > lat_max) lat_max = tres - trdy;     /* window ready -> result valid */
            if (t_ack - trdy > lat_ack_max) lat_ack_max = t_ack - trdy;   /* window ready -> result read and acknowledged */
            if (t_ack - tr > proc_max) proc_max = t_ack - tr;
            windows++;
            idle_count = 0;
        } else {
            dsr = R32(DMA + 0x04);
            /* done: the DMA is idle, the sequencer is not running and the ring holds less than a window */
            if ((dsr & 0x2u) && !(st & 0x8u) && R32(RT + 0x10) < CASE_NS) {
                if (++idle_count > 20000) break;
            } else idle_count = 0;
            if (now() - t0 > 3000000000ULL) break;     /* 20 s */
        }
    }
    L[0] = period;
    L[1] = R32(RT + 0x1C);             /* FRAMES_DONE */
    L[2] = R32(RT + 0x18);             /* DROPPED */
    L[3] = R32(RT + 0x30);             /* frames flagged with a gap */
    L[4] = R32(RT + 0x14);             /* OCC_MAX */
    L[5] = windows;
    L[6] = checked;
    L[7] = mism;
    L[8] = (u32)lat_max;               /* window ready -> result valid, cycles, worst */
    L[9] = (u32)proc_max;              /* result seen -> acknowledged, cycles, worst */
    L[10] = R32(DMA + 0x04);
    L[11] = R32(RT + 0x04);
    L[12] = (u32)(now() - t0);         /* run duration, cycles */
    L[13] = drop;
    L[14] = seq;                       /* matched golden window per result, 1-based nibbles, 0 = no match */
    L[15] = (u32)lat_ack_max;
}

#ifdef SOAK
/* ---- steady-state rate test: the 6-window stream is replayed over and over; result k must equal golden window k mod 6 ---- */
static void dma_start(u32 bytes)
{
    W32(DMA + 0x28, bytes);
}

static void dma_reset_run(void)
{
    W32(DMA + 0x00, 0x4);
    while (R32(DMA + 0x00) & 0x4) { }
    W32(DMA + 0x00, 0x1);
    W32(DMA + 0x18, (u32)SAMPLE_BASE); W32(DMA + 0x1C, 0);
}

/* Empty the ring so the next run starts window-aligned: top up a partial window with samples from OCM (any data), let
 * every complete window run and acknowledge. Backpressure mode, no pacing. */
static u32 fl_occ0, fl_junk, fl_topped, fl_dmasr, fl_iter, fl_exit;      /* clean-up diagnostics, logged per run */

/* Empty the ring so the next run starts window-aligned. The DMA is NOT reset in the middle of a transfer (a reset with a
 * transfer in flight left it busy and stuck, which is what broke the first version of this routine): the transfer is
 * allowed to finish into the ring (backpressure, no pacing), every complete window runs and is acknowledged, then a
 * partial window left over is topped up with samples from OCM (any data) and consumed. */
static void flush_ring(void)
{
    u32 st, occ, dsr, topped = 0;
    u64 t0 = now();
    fl_junk = 0; fl_iter = 0; fl_exit = 0;
    fl_occ0 = R32(RT + 0x10);
    fl_dmasr = R32(DMA + 0x04);
    if (fl_dmasr & 1u) dma_reset_run();       /* halted (never started): safe to reset and arm */
    W32(RT + 0x00, 0x2);                      /* disable, clear counters and flags */
    W32(RT + 0x0C, 0);
    W32(RT + 0x00, 1u);                       /* enable, backpressure */
    while (now() - t0 < 3000000000ULL) {
        fl_iter++;
        st = R32(RT + 0x04); occ = R32(RT + 0x10); dsr = R32(DMA + 0x04);
        if (st & 1u) { W32(RT + 0x00, 1u | 4u); fl_junk++; continue; }
        if (!(dsr & 2u)) continue;            /* a transfer is still delivering: wait for it */
        if (!(st & 8u) && occ == 0) { fl_exit = 1; break; }
        if (!topped && occ > 0 && occ < CASE_NS && !(st & 8u)) { dma_start((CASE_NS - occ) * 8u); topped = 1; }
    }
    fl_topped = topped;
    W32(RT + 0x00, 0x2);                      /* disable again */
}

static void run_soak(int idx, u32 period, int drop, u32 target)
{
    volatile u32 *L = logw + 8 + idx * LOG_WORDS_PER_RUN;
    u32 ctrl_en = 1u | (drop ? 8u : 0u);
    u32 windows = 0, mism = 0, st, transfers = 1;
    u32 first_drop = 0xFFFFFFFFu, first_mism = 0xFFFFFFFFu, seq = 0, occ_start;
    u64 t0, tr, t_ack, proc_max = 0, lat_ack_max = 0, lat_max = 0;
    const u32 len = NWIN * CASE_NS * 8u;

    flush_ring();
    occ_start = R32(RT + 0x10);              /* ring occupancy after the clean-up: must be 0 */
    W32(RT + 0x00, 0x2 | (drop ? 8u : 0u));    /* clear counters and flags */
    W32(RT + 0x08, 0);  W32(RT + 0x0C, period);
    dma_reset_run();
    W32(RT + 0x00, ctrl_en);
    t0 = now();
    dma_start(len);

    while (windows < target && now() - t0 < 24000000000ULL) {      /* 160 s cap */
        st = R32(RT + 0x04);
        if ((st & 2u) && first_drop == 0xFFFFFFFFu) first_drop = windows;
        if (st & 1u) {
            u64 tres, trdy;
            int w;
            tr = now();
            tres = ((u64)R32(RT + 0x2C) << 32) | R32(RT + 0x28);
            trdy = ((u64)R32(RT + 0x24) << 32) | R32(RT + 0x20);
            w = match_window();
            if (windows < 8) seq |= (u32)((w + 1) & 0xF) << (4 * windows);
            if (w != (int)(windows % NWIN)) { mism++; if (first_mism == 0xFFFFFFFFu) first_mism = windows; }
            W32(RT + 0x00, ctrl_en | 4u);
            t_ack = now();
            if (tres - trdy > lat_max) lat_max = tres - trdy;
            if (t_ack - trdy > lat_ack_max) lat_ack_max = t_ack - trdy;
            if (t_ack - tr > proc_max) proc_max = t_ack - tr;
            windows++;
        }
        if (R32(DMA + 0x04) & 2u) { dma_start(len); transfers++; }    /* keep the stream going */
    }
    L[0] = period;
    L[1] = R32(RT + 0x1C);
    L[2] = R32(RT + 0x18);
    L[3] = R32(RT + 0x30);
    L[4] = R32(RT + 0x14);
    L[5] = windows;
    L[6] = windows - mism;
    L[7] = mism;
    L[8] = (u32)lat_max;
    L[9] = (u32)proc_max;
    L[10] = R32(DMA + 0x04);
    L[11] = R32(RT + 0x04);
    L[12] = (u32)(now() - t0);
    L[13] = drop;
    L[14] = first_drop;                /* windows completed when the overrun flag was first seen */
    L[15] = (u32)lat_ack_max;
    L[16] = first_mism;
    L[17] = target;
    L[18] = transfers;
    L[19] = seq;                       /* golden window id (1-based nibble) each of the first 8 results equals, 0 = none */
    L[20] = occ_start;
    L[21] = fl_occ0 | (fl_topped << 31);   /* ring occupancy when the clean-up began, top bit: top-up used */
    L[22] = fl_junk;                       /* windows consumed by the clean-up */
    L[23] = (fl_dmasr & 0xFFFFu) | (fl_exit << 16);   /* DMA status after its reset, bit 16: clean-up ended by the empty test */
    W32(RT + 0x00, 0x2);               /* stop the sequencer; flush_ring cleans up at the next run */
}

int main(void)
{
#ifdef SOAK_QUICK
    static const u32 periods[]  = {2500, 2300, 2200, 2100, 0};
    static const u32 targets[]  = {14, 14, 14, 14, 14};
#else
    static const u32 periods[]  = {2500, 2300, 2200, 2100, 2050, 2000, 1900, 1800, 0};
    static const u32 targets[]  = {1000, 500, 500, 500, 500, 500, 500, 500, 300};
#endif
    int i, n = (int)(sizeof(periods) / sizeof(periods[0]));
    logw[0] = 0; logw[1] = 0; logw[2] = (u32)n; logw[3] = R32(CORE + 0x48);
    configure_core();
    for (i = 0; i < n; i++) {
        logw[1] = (u32)(i + 1);
        run_soak(i, periods[i], periods[i] != 0, targets[i]);     /* the last run: DMA at full speed, backpressure: sustained throughput */
    }
    logw[1] = 0xFFFFu;
    logw[0] = 0x52544C47u;
    return 0;
}
#else
int main(void)
{
    static const u32 periods[] = {0, 6000, 3000, 2200, 1800, 1200, 600};
    int i, n = (int)(sizeof(periods) / sizeof(periods[0]));
    logw[0] = 0; logw[1] = 0; logw[2] = (u32)n; logw[3] = R32(CORE + 0x48);
    configure_core();
    for (i = 0; i < n; i++) {
        logw[1] = (u32)(i + 1);
        /* period 0 (DMA at full speed): backpressure mode, every window checked; others: drop mode, checked if nothing was lost */
        run(i, periods[i], periods[i] != 0, 1);
    }
    logw[1] = 0xFFFFu;
    logw[0] = 0x52544C47u;             /* 'RTLG': log complete */
    return 0;
}

#endif
