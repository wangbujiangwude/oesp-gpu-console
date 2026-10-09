/* avetest10.c —— OESP AVE 硬编「真实验收」程序
 *
 * 依据本地 libvpcodec 源码（amvenc_src_c2_vpcodec/）确认的 API 契约：
 *   vl_codec_handle_t vl_video_encoder_init(codec_id, w, h, frame_rate, bit_rate, gop, img_format)
 *   int  vl_video_encoder_encode(handle, frame_type, char *in, int out_cap /*被复用为出参*\/, char **out)
 *   int  vl_video_encoder_destory(handle)
 *   const char *vl_get_version(void)
 *
 * ★ 关键 ABI 事实（源码 libvpcodec.cpp 实证）：
 *   - encode 的第 4 参 in_size 实际是 **输出缓冲容量**（内部被复用为 dataLength）
 *   - 输出写入 *out 指向的**调用者分配**的缓冲区；返回值为有效长度
 *   - 输入必须是 NV12/NV21 连续帧（YCbCr[0]=in, YCbCr[1]=in+height*pitch）
 *   - initEncParams 要求 width%16==0 且 height%2==0
 *
 * 模式：
 *   version            只打印版本
 *   init_only          init 后立即 exit（基线）
 *   encode_1           init + 编 1 帧（最小暴露）
 *   encode_n <N>       init + 编 N 帧
 *   sync_storm <S>     纯 sync() 循环 S 秒（磁盘假设对照，不碰 AVE）
 *
 * 环境变量：
 *   NOSYNC=1           关闭全局 sync()，只做 fsync（用于分离磁盘变量）
 *   BR=<bps>           码率（默认 512000）
 *   FPS=<fps>          帧率（默认 25）
 *   GOP=<n>            GOP（默认 25）
 *   DUMPIN=1           把输入 NV12 帧写到 /root/vdec/ave/dp/in.nv12（同内容软编对照用）
 *   RCFIX=1            运行时修复设备 libvpcodec 被清零的码率控制表：
 *                      根因（2026-10-08 ELF 实证）——大佬把 gx_fast_rc 结构体的 5 个
 *                      函数指针 RELATIVE 重定位 addend 全部清 0（代码保留、指针断开），
 *                      AMInitRateControlModule 拿到 NULL 静默失败 ⇒ 码率控制全程 no-op。
 *                      修复：grc 符号导出且在可写 .data ⇒ 自建 5 指针表（dlsym 取
 *                      GxFast* 五函数）替换 grc[2]（gx_fast 槽位）。
 *
 * 性能摸底（52 批）：
 *   NOSYNC=1 时对 enc() 调用做纯计时（不含 fill/stamp/写盘），
 *   结束打印 PERF 行：avg/min/max ms、等效 fps、平均码率 kbps
 *
 * 落盘（跨硬挂保留）：
 *   /root/vdec/ave/dp/atest10_status.txt   逐阶段时间戳
 *   /root/vdec/ave/dp/out10.h264           编码输出（NOSYNC 时收尾统一 fsync）
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <time.h>

typedef enum { CODEC_ID_NONE, CODEC_ID_VP8, CODEC_ID_H261, CODEC_ID_H263, CODEC_ID_H264, CODEC_ID_H265 } vl_codec_id_t;
typedef enum { IMG_FMT_NONE, IMG_FMT_NV12, IMG_FMT_NV21, IMG_FMT_YV12 } vl_img_format_t;
typedef enum { FRAME_TYPE_NONE, FRAME_TYPE_AUTO, FRAME_TYPE_IDR, FRAME_TYPE_I, FRAME_TYPE_P } vl_frame_type_t;
typedef struct { int framerate, bitrate, gop; } vl_encoder_param_t;

#define SF   "/root/vdec/ave/dp/atest10_status.txt"
#define OF   "/root/vdec/ave/dp/out10.h264"
#define OUT_CAP (1u << 20)

static double T0;
static int    NOSYNC;
static void  *g_lib;   /* dlopen 的编码库句柄（路径可由 VPLIB 覆盖） */

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void stamp(const char *s)
{
	int fd = open(SF, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd >= 0) {
		ssize_t r = write(fd, s, strlen(s));
		(void)r;
		fsync(fd);
		close(fd);
	}
	if (!NOSYNC)
		sync();
}

static void stag(const char *fmt, ...)
{
	char b[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b, sizeof b, fmt, ap);
	va_end(ap);
	stamp(b);
}

/* 生成一帧 NV12（含运动，避免被编码器判为静止帧跳过） */
static void fill_nv12(unsigned char *buf, int w, int h, int frame)
{
	int pitch = ((w + 15) >> 4) << 4;
	int y, x;
	for (y = 0; y < h; y++)
		for (x = 0; x < pitch; x++)
			buf[y * pitch + x] = (unsigned char)((x + y * 2 + frame * 7) & 0xff);
	{
		unsigned char *uv = buf + pitch * h;
		for (y = 0; y < h / 2; y++)
			for (x = 0; x < pitch; x++)
				uv[y * pitch + x] = (unsigned char)(128 + ((x + frame * 5) & 0x3f));
	}
}

static void on_segv(int sig, siginfo_t *si, void *uc)
{
	char b[512];
	ucontext_t *u = (ucontext_t *)uc;
	unsigned long pc = u->uc_mcontext.pc;
	int fd = open(SF, O_WRONLY | O_CREAT | O_APPEND, 0644), mfd;
	char line[512];
	if (fd >= 0) {
		int n = snprintf(b, sizeof b, "SIGSEGV addr=%p code=%d pc=%#lx lr=?\n",
		                 si->si_addr, si->si_code, pc);
		write(fd, b, n);
		close(fd);
	}
	printf("SIGSEGV addr=%p code=%d pc=%#lx\n", si->si_addr, si->si_code, pc);
	mfd = open("/proc/self/maps", O_RDONLY);
	if (mfd >= 0) {
		static char maps[16384];
		ssize_t r, tot = 0;
		while (tot < (ssize_t)sizeof maps - 1 &&
		       (r = read(mfd, maps + tot, sizeof maps - 1 - tot)) > 0)
			tot += r;
		maps[tot] = 0;
		close(mfd);
		{
			char *nl = maps;
			while (nl && *nl) {
				char *e = strchr(nl, '\n');
				if (e) *e = 0;
				if (strstr(nl, "libvpcodec") || strstr(nl, "avetest10") ||
				    strstr(nl, "libc.so"))
					printf("MAP %s\n", nl);
				nl = e ? e + 1 : NULL;
			}
		}
	}
	fflush(stdout);
	_exit(88);
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "encode_1";
	int W = 176, H = 144, N = 1;

	setvbuf(stdout, NULL, _IONBF, 0);
	{
		struct sigaction sa;
		memset(&sa, 0, sizeof sa);
		sa.sa_sigaction = on_segv;
		sa.sa_flags = SA_SIGINFO;
		sigaction(SIGSEGV, &sa, NULL);
		sigaction(SIGBUS, &sa, NULL);
	}
	T0 = now_s();
	NOSYNC = getenv("NOSYNC") != NULL;

	unlink(SF);
	stag("=== avetest10 MODE %s pid=%d nosync=%d ===\n", mode, (int)getpid(), NOSYNC);
	printf("PID=%d mode=%s\n", (int)getpid(), mode);

	/* ---- sync_storm：纯磁盘压力对照（不加载 AVE）---- */
	if (strcmp(mode, "sync_storm") == 0) {
		int secs = argc > 2 ? atoi(argv[2]) : 30;
		int i;
		stag("SYNC_STORM start %ds\n", secs);
		for (i = 0; i < secs; i++) {
			sync();
			stag("SYNC_%d t=+%.1fs\n", i + 1, now_s() - T0);
		}
		stag("SYNC_STORM_DONE t=+%.1fs\n", now_s() - T0);
		return 0;
	}

	/* 编码库路径可覆盖（GPU 控制台自检走同一程序；默认 /root/vdec/ave/libvpcodec.so） */
	{
		void *h0 = NULL;
		const char *vplib = getenv("VPLIB");
		if (!vplib || !*vplib)
			vplib = "/root/vdec/ave/libvpcodec.so";
		h0 = dlopen(vplib, RTLD_NOW);
		if (!h0) {
			stag("DLOPEN_FAIL %s\n", dlerror());
			return 1;
		}
		g_lib = h0;
	}
	if (!g_lib) {
		stag("DLOPEN_FAIL\n");
		return 1;
	}
	stag("DLOPEN_OK t=+%.2f\n", now_s() - T0);

	long (*init)(vl_codec_id_t, int, int, vl_encoder_param_t, vl_img_format_t) =
		dlsym(g_lib, "vl_video_encoder_init");
	/* ★ 设备版 libvpcodec 实测 ABI（2026-10-08 反汇编 0xa798 实证）:
	 *   int encode(handle, frame_type, char *in, char *out_buf, unsigned *aux)
	 *   - 第 4 参 = 输出缓冲指针（直接传给 AML_HWEncNAL）
	 *   - 第 5 参 = 辅助标志指针（入口清零，可 NULL）
	 *   - 返回值 = 输出字节数（失败 -1） */
	int (*enc)(long, vl_frame_type_t, char *, char *, unsigned int *) =
		dlsym(g_lib, "vl_video_encoder_encode");
	int (*destory)(long) = dlsym(g_lib, "vl_video_encoder_destory");
	const char *(*ver)(void) = dlsym(g_lib, "vl_get_version");
	if (!init || !enc) {
		stag("DLSYM_FAIL init=%p enc=%p\n", (void *)init, (void *)enc);
		return 2;
	}
	stag("DLSYM_OK t=+%.2f ver=%s\n", now_s() - T0, ver ? ver() : "?");

	/* ---- RCFIX：修复被清零的 gx_fast_rc 码率控制表（用户态，零内核风险）---- */
	if (getenv("RCFIX")) {
		typedef struct {
			void *(*Initialize)(void *);
			long (*PreControl)(void *, void *, int, int);
			long (*PostControl)(void *, void *, int, int *, int);
			long (*InitFrameQP)(void *, void *, int, int, float);
			void (*Release)(void *);
		} rc_ops_t;
		/* 设备 libvpcodec.so 静态偏移（2026-10-08 反汇编+reloc 实证，md5 见 STATUS） */
		struct { const char *mangled; unsigned long off; } rcfn[5] = {
			{ "_Z27GxFastInitRateControlModuleP17amvenc_initpara_s", 0xfcc0 }, /* Initialize  */
			{ "_Z20GxFastRCUpdateBufferPvS_ib",                    0xfca4 }, /* PreControl  */
			{ "_Z19GxFastRCUpdateFramePvS_bPii",                   0xf298 }, /* PostControl */
			{ "_Z19GxFastRCInitFrameQPPvS_bif",                    0xf83c }, /* InitFrameQP */
			{ "_Z30GxFastCleanupRateControlModulePv",              0xfcbc }, /* Release     */
		};
		void ***grc = (void ***)dlsym(g_lib, "grc");
		if (!grc) {
			stag("RCFIX_FAIL: grc symbol not exported\n");
			printf("RCFIX: grc not exported\n");
		} else {
			int gi, hi = -1, fi;
			unsigned long base = (unsigned long)grc - 0x43170UL;
			rc_ops_t *t = (rc_ops_t *)calloc(1, sizeof *t);
			void **slot = (void **)t;
			for (gi = 0; gi < 4; gi++) {
				printf("RCFIX: grc[%d] = %p\n", gi, grc[gi]);
				if (grc[gi] && hi < 0)
					hi = gi;   /* 唯一非空槽 = gx_fast_rc（被清零表）*/
			}
			if (hi < 0)
				hi = 2;       /* 兜底：reloc 实证 gx_fast 在 index 2 */
			for (fi = 0; fi < 5; fi++) {
				slot[fi] = dlsym(g_lib, rcfn[fi].mangled);
				if (!slot[fi])
					slot[fi] = (void *)(base + rcfn[fi].off);  /* 偏移兜底 */
			}
			printf("RCFIX: base=%p fns init=%p pre=%p post=%p qp=%p rel=%p\n",
			       (void *)base, t->Initialize, t->PreControl,
			       t->PostControl, t->InitFrameQP, t->Release);
			stag("RCFIX base=%p init=%p pre=%p post=%p qp=%p rel=%p\n",
			     (void *)base, t->Initialize, t->PreControl,
			     t->PostControl, t->InitFrameQP, t->Release);
			grc[hi] = t;
			printf("RCFIX: grc[%d] replaced -> %p\n", hi, (void *)t);
			stag("RCFIX grc[%d] replaced t=+%.2f\n", hi, now_s() - T0);
		}
	}

	if (strcmp(mode, "version") == 0)
		return 0;

	if (argc > 3) W = atoi(argv[3]);
	if (argc > 4) H = atoi(argv[4]);
	if (strcmp(mode, "encode_n") == 0 && argc > 2) N = atoi(argv[2]);
	if (strcmp(mode, "encode_1") == 0) N = 1;
	if (strcmp(mode, "init_only") == 0) N = 0;

	if (W % 16 || H % 2) {
		stag("BAD_DIM w=%d h=%d (need w%%16==0, h%%2==0)\n", W, H);
		return 3;
	}

	vl_encoder_param_t p;
	{
		const char *e;
		p.framerate = 25;
		p.bitrate = 512000;
		p.gop = 25;
		if ((e = getenv("FPS"))  != NULL && atoi(e) > 0)   p.framerate = atoi(e);
		if ((e = getenv("BR"))   != NULL && atoi(e) > 0)   p.bitrate = atoi(e);
		if ((e = getenv("GOP")) != NULL && atoi(e) >= 0)   p.gop = atoi(e);
	}

	stag("CALLING_INIT %dx%d t=+%.2f\n", W, H, now_s() - T0);
	long hd = init(CODEC_ID_H264, W, H, p, IMG_FMT_NV12);
	stag("INIT_RET=%ld t=+%.2f\n", hd, now_s() - T0);
	if (hd == 0) {
		stag("INIT_FAILED\n");
		return 1;
	}

	if (N > 0) {
		int pitch = ((W + 15) >> 4) << 4;
		size_t ysz = (size_t)pitch * H;
		size_t fsz = ysz + ysz / 2;
		unsigned char *nv12 = malloc(fsz);
		char *obuf = malloc(OUT_CAP);
		int ofd, i, total = 0;
		int nok = 0;                 /* 成功帧数 */
		double tsum = 0, tmin = 1e9, tmax = 0; /* enc() 纯计时 */
		double t_enc0, t_enc1;

		if (!nv12 || !obuf) {
			stag("MALLOC_FAIL\n");
			return 4;
		}
		ofd = open(OF, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		{
			int ifd = -1;
			if (getenv("DUMPIN"))
				ifd = open("/root/vdec/ave/dp/in.nv12",
				           O_WRONLY | O_CREAT | O_TRUNC, 0644);
			for (i = 0; i < N; i++) {
				unsigned int aux = 0;
				int n;

				fill_nv12(nv12, W, H, i);
				if (ifd >= 0) {
					if (write(ifd, nv12, fsz) != (ssize_t)fsz)
						stag("DUMPIN_WRITE_FAIL t=+%.2f\n", now_s() - T0);
				}
				stag("ENC_%d_CALL t=+%.2f\n", i, now_s() - T0);
			t_enc0 = now_s();
			n = enc(hd, FRAME_TYPE_AUTO, (char *)nv12, obuf, &aux);
			t_enc1 = now_s();
			if (n > 0) {
				double d = (t_enc1 - t_enc0) * 1000.0;
				tsum += d;
				if (d < tmin) tmin = d;
				if (d > tmax) tmax = d;
				nok++;
			}
			stag("ENC_%d_RET=%d aux=%u t=+%.2f\n", i, n, aux, now_s() - T0);

			if (n > 0) {
				if (ofd >= 0) {
					if (write(ofd, obuf, (size_t)n) == n) {
						if (!NOSYNC) fsync(ofd);
						total += n;
					}
				}
				printf("frame %d -> %d bytes\n", i, n);
			} else {
				printf("frame %d -> ret=%d (skip/timeout)\n", i, n);
			}
		}
		if (ofd >= 0) {
			if (NOSYNC) fsync(ofd);
			close(ofd);
		}
		if (ifd >= 0)
			close(ifd);
		}
		stag("ENCODE_DONE frames=%d total_bytes=%d t=+%.2f\n", N, total, now_s() - T0);
		printf("TOTAL %d bytes\n", total);
		if (nok > 0) {
			double avg = tsum / nok;
			double dur = now_s() - T0;
			(void)dur;
			printf("PERF w=%d h=%d br=%d fps_cfg=%d frames=%d ok=%d "
			       "avg_ms=%.3f min_ms=%.3f max_ms=%.3f enc_fps=%.1f "
			       "bytes=%d kbps=%.1f\n",
			       W, H, p.bitrate, p.framerate, N, nok,
			       avg, tmin, tmax, 1000.0 / avg,
			       total, total * 8.0 / 1000.0 / nok * p.framerate);
			stag("PERF w=%d h=%d br=%d frames=%d ok=%d avg_ms=%.3f min_ms=%.3f max_ms=%.3f enc_fps=%.1f bytes=%d\n",
			     W, H, p.bitrate, N, nok, avg, tmin, tmax, 1000.0 / avg, total);
		} else {
			printf("PERF w=%d h=%d br=%d frames=%d ok=0\n", W, H, p.bitrate, N);
		}
		free(nv12);
		free(obuf);
	}

	stag("CALL_DESTROY t=+%.2f\n", now_s() - T0);
	if (destory)
		destory(hd);
	stag("DESTROY_RET t=+%.2f\n", now_s() - T0);
	stag("ALL_DONE t=+%.2f\n", now_s() - T0);
	printf("ALL_DONE\n");
	return 0;
}
