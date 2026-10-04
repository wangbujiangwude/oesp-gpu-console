/*
 * meson_vdec 硬解取帧 -> stdout 管道 (可直接喂给 ffmpeg 软编)
 *
 * 用法: vdec_test3 <设备> <裸码流> <最大帧数> [输出]
 *       输出: 文件路径, 或 "-" 表示 stdout(帧数据), 日志一律走 stderr
 *
 * 关键: G12A H.264 是 V4L2_FMT_FLAG_DYN_RESOLUTION 动态分辨率:
 *   STREAMON OUTPUT -> 送含 SPS 的 AU -> 等 V4L2_EVENT_SOURCE_CHANGE
 *   -> G_FMT 取真实分辨率 -> REQBUFS/QBUF capture -> STREAMON CAPTURE(驱动 resume)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <poll.h>
#include <linux/videodev2.h>

#define LOG(...) fprintf(stderr, __VA_ARGS__)
#define MAX_BUF   32
#define MAX_PLANES 3

static int fd = -1;
static int mplane = 0;

struct bufinfo {
	void *start[MAX_PLANES];
	size_t len[MAX_PLANES];
	unsigned int bpl[MAX_PLANES];
	int nplanes;
};

static struct bufinfo out_bufs[MAX_BUF], cap_bufs[MAX_BUF];
static int n_out = 0, n_cap = 0;
static unsigned int g_cap_w = 0, g_cap_h = 0, g_cap_bpl = 0;
static int g_sample_every = 0;   /* 每 N 帧采样打印一次; 0=关闭 */

/* ---- 预热(prelude)机制 ----
 * 实测: G12A H.264 硬解的 Y 平面在第一个 GOP 内带有随机 DC 偏移 (每次会话不同)。
 * 根因是固件帧间预测缓冲首次被使用时取到未初始化内容。
 * 解法: 把码流最前面 N 个 AU 复制一份拼到码流前面作"牺牲段", 固件先解它把缓冲
 *       填充为有效数据, 随后正式码流的第一帧起即完全正确。
 *       必须含 P 帧才有效 (只预热 IDR 无效)。N=2 (IDR + 第1个P) 实测足够。
 * 代价: 输出帧序列前移 1 帧 —— 预热产生的第 1 帧必须丢弃, 之后精确对齐。
 */
static int g_prelude_au = 0;     /* 预热 AU 数; 0=关闭 (默认由环境变量 PRELUDE_AU 设) */
static int g_nodrain = 0;        /* 1=禁用尾部 drain (对照实验用, NODRAIN=1) */
static int g_cap_bufs = 24;      /* capture 缓冲数 (CAP_BUFS; 平台上限 24) */
static size_t g_out_size = 2 * 1024 * 1024;  /* OUTPUT 码流缓冲 (OUT_SIZE, 默认 2MB) */
static int    g_out_bufs = 8;                /* OUTPUT 缓冲个数 (OUT_BUFS; 总量受 CMA 限制) */
static int g_truncated = 0;      /* 被截断的 AU 计数 */
static int g_tail_au = 1;        /* 尾部追加的 IDR AU 数 (TAIL_AU), 用于顶出固件压着的尾帧 */
static int g_compact = 0;        /* 1=输出去掉对齐 padding 的紧凑 NV12 */
static unsigned int g_cap_vis_h = 0;  /* G_FMT 给出的真实画面高度 (720), 区别于 g_cap_h(对齐后 768) */
static int g_drop = 0;           /* 还需丢弃的输出帧数 */
static int g_drop_init = 0;      /* 预热丢弃帧数初始值 (用于推算预期帧数) */
static int g_expect = 0;         /* 预期输出帧数; 达到后即可快速退出, 不必空等 drain 超时 */

static int g_idle_ms = 800;  /* 码流送完后, 连续多久没有新帧就结束 (IDLE_MS; 会叠加到总用时) */
/* drain 阶段的等待: LAST 标志只在 should_stop && esparser_queued_bufs<=1 时才置,
   实测经常不触发, 只能靠等。太短会漏掉尾部 3 帧(1080p 需 >=2s, 720p 需 >=5s)。
   注意: 若帧能全部取回, 循环会因达到 max_frames 提前退出, 不会平白等这么久。 */
static int g_drain_ms = 5000;
#define TOTAL_MS 120000  /* 总保险超时 */

static long long now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static const char *errs(int e)
{
	switch (e) {
	case 0: return "OK";
	case EAGAIN: return "EAGAIN";
	case EBUSY: return "EBUSY";
	case EINVAL: return "EINVAL";
	case ENOMEM: return "ENOMEM";
	case ENODATA: return "ENODATA";
	case EPERM: return "EPERM";
	default: return strerror(e);
	}
}

static int xioctl(unsigned long req, void *arg)
{
	int r;
	do { r = ioctl(fd, req, arg); } while (r == -1 && (errno == EINTR));
	return r ? -1 : 0;
}

static unsigned char *stream;
static size_t stream_len;
static size_t *au_off;
static size_t au_count;

static void split_au(void)
{
	size_t i, cap = 8192;
	au_off = malloc(cap * sizeof(size_t));
	au_count = 0;
	for (i = 0; i + 3 < stream_len; i++) {
		if (stream[i] == 0 && stream[i+1] == 0 && stream[i+2] == 1) {
			unsigned char t = stream[i+3] & 0x1f;
			int is_slice = (t == 1 || t == 5);
			if (au_count == 0) {
				au_off[au_count++] = i;
			} else if (is_slice) {
				if (au_count >= cap) { cap *= 2; au_off = realloc(au_off, cap * sizeof(size_t)); }
				au_off[au_count++] = i;
			}
		}
	}
}

static size_t au_len(size_t idx)
{
	return (idx + 1 < au_count) ? (au_off[idx+1] - au_off[idx]) : (stream_len - au_off[idx]);
}

static int req_bufs(int type, int count, struct bufinfo *bi, int *n)
{
	struct v4l2_requestbuffers req;
	struct v4l2_buffer buf;
	struct v4l2_plane planes[MAX_PLANES];
	int i, p;

	memset(&req, 0, sizeof(req));
	req.count = count; req.type = type; req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(VIDIOC_REQBUFS, &req)) { LOG("  REQBUFS type=%d FAIL: %s\n", type, errs(errno)); return -1; }
	*n = req.count;
	LOG("  REQBUFS type=%d granted=%d\n", type, req.count);

	for (i = 0; i < (int)req.count; i++) {
		memset(&buf, 0, sizeof(buf));
		memset(planes, 0, sizeof(planes));
		buf.type = type; buf.memory = V4L2_MEMORY_MMAP; buf.index = i;
		buf.length = MAX_PLANES; buf.m.planes = planes;
		if (xioctl(VIDIOC_QUERYBUF, &buf)) { LOG("  QUERYBUF[%d] FAIL: %s\n", i, errs(errno)); return -1; }
		bi[i].nplanes = mplane ? buf.length : 1;
		for (p = 0; p < bi[i].nplanes; p++) {
			size_t len = mplane ? planes[p].length : buf.length;
			off_t  off = mplane ? planes[p].m.mem_offset : buf.m.offset;
			bi[i].len[p] = len;
			bi[i].start[p] = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off);
			if (bi[i].start[p] == MAP_FAILED) {
				LOG("  MMAP buf[%d] plane[%d] FAIL: %s\n", i, p, errs(errno));
				return -1;
			}
		}
	}
	LOG("  %d 个 buffer 已 mmap (plane0 len=%zu)\n", (int)req.count, bi[0].len[0]);
	if (type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
		/* 由 plane 长度与 bytesperline 反推 stride/高度 */
		g_cap_bpl = bi[0].bpl[0] ? bi[0].bpl[0] : g_cap_w;
		if (g_cap_bpl) g_cap_h = bi[0].len[0] / g_cap_bpl;
	}
	return 0;
}

static int qbuf_out(int idx, size_t bytesused)
{
	struct v4l2_buffer buf;
	struct v4l2_plane planes[MAX_PLANES];
	memset(&buf, 0, sizeof(buf));
	memset(planes, 0, sizeof(planes));
	buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	buf.memory = V4L2_MEMORY_MMAP;
	buf.index = idx;
	buf.length = 1;
	buf.m.planes = planes;
	buf.timestamp.tv_sec = idx / 1000000;
	buf.timestamp.tv_usec = idx % 1000000;
	if (mplane) planes[0].bytesused = bytesused;
	else buf.bytesused = bytesused;
	return xioctl(VIDIOC_QBUF, &buf);
}

static int qbuf_cap(int idx)
{
	struct v4l2_buffer buf;
	struct v4l2_plane planes[MAX_PLANES];
	memset(&buf, 0, sizeof(buf));
	memset(planes, 0, sizeof(planes));
	buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	buf.memory = V4L2_MEMORY_MMAP;
	buf.index = idx;
	buf.length = MAX_PLANES;
	buf.m.planes = planes;
	return xioctl(VIDIOC_QBUF, &buf);
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/video0";
	const char *path = argc > 2 ? argv[2] : "/tmp/in.h264";
	int max_frames = argc > 3 ? atoi(argv[3]) : 20;
	/* 0 或负数 = 不限帧数(解完整段)。曾经漏了这个转换, 传 0 会一帧都不解。 */
	if (max_frames <= 0) max_frames = 0x7fffffff;
	const char *outpath = argc > 4 ? argv[4] : "/tmp/frames.nv12";
	/* 第 5 参: OUTPUT fourcc, 如 H264 / VP90 / HEVC / MPEG2 */
	const char *fcc = argc > 5 ? argv[5] : "H264";
	unsigned int out_fourcc = v4l2_fourcc(fcc[0], fcc[1], fcc[2], fcc[3]);
	{
		const char *se = getenv("SAMPLE_EVERY");
		if (se && atoi(se) > 0) { g_sample_every = atoi(se); LOG("周期采样: 每 %d 帧\n", g_sample_every); }
		{
			const char *pa = getenv("PRELUDE_AU");
			if (pa && atoi(pa) > 0) g_prelude_au = atoi(pa);
			const char *cp = getenv("COMPACT");
			if (cp && atoi(cp) > 0) g_compact = 1;
			const char *nd = getenv("NODRAIN");
			if (nd && atoi(nd) > 0) { g_nodrain = 1; LOG("对照模式: 禁用尾部 drain\n"); }
			{
				const char *cb = getenv("CAP_BUFS");
				if (cb && atoi(cb) >= 2 && atoi(cb) <= 32) g_cap_bufs = atoi(cb);
				const char *os = getenv("OUT_SIZE");
				if (os && atol(os) >= 65536) g_out_size = (size_t)atol(os);
				const char *ob = getenv("OUT_BUFS");
				if (ob && atoi(ob) >= 2 && atoi(ob) <= 32) g_out_bufs = atoi(ob);
				const char *im = getenv("IDLE_MS");
				if (im && atoi(im) >= 50) g_idle_ms = atoi(im);
				const char *dm = getenv("DRAIN_MS");
				if (dm && atoi(dm) >= 50) g_drain_ms = atoi(dm);
				const char *ta = getenv("TAIL_AU");
				if (ta && atoi(ta) > 0 && atoi(ta) <= 16) g_tail_au = atoi(ta);
			}
		}
	}
	struct v4l2_capability cap;
	struct v4l2_format fmt;
	struct v4l2_event_subscription sub;
	struct v4l2_event ev;
	struct stat st;
	int i, rc, t;
	size_t sent = 0;
	int frames = 0, got_src_change = 0;
	FILE *fp = NULL;
	struct timespec t0, t1;

	setvbuf(stdout, NULL, _IONBF, 0);

	LOG("=== meson_vdec 硬解取帧 (stdout 管道模式) ===\n");
	LOG("设备=%s 码流=%s 目标帧数=%d 输出=%s\n\n", dev, path, max_frames, outpath);

	if (stat(path, &st)) { LOG("码流不存在\n"); return 1; }
	fp = fopen(path, "rb");
	stream = malloc(st.st_size);
	stream_len = fread(stream, 1, st.st_size, fp);
	fclose(fp);
	split_au();
	LOG("[1] 码流 %zu 字节, %zu 个 AU\n", stream_len, au_count);
	if (!au_count) return 1;

	/* 构造预热码流: 前 g_prelude_au 个 AU 复制一份拼到最前面 */
	if (g_prelude_au > 0 && (size_t)g_prelude_au < au_count) {
		size_t pre_len = au_off[g_prelude_au];
		unsigned char *ns = malloc(pre_len + stream_len);
		if (ns) {
			memcpy(ns, stream, pre_len);
			memcpy(ns + pre_len, stream, stream_len);
			free(stream);
			stream = ns;
			stream_len = pre_len + stream_len;
			split_au();                  /* 按新码流重新切 AU */
			/* 实测: 预热 N 个 AU 时, 前 N-1 帧带偏移, 第 N 帧起正确 -> 丢弃 N-1 帧 */
			g_drop = g_prelude_au - 1;
			g_drop_init = g_drop;
			g_expect = (int)au_count - g_drop_init - g_tail_au;
			LOG("[1b] 预热: 复制前 %d 个 AU (%zu 字节) 拼到码流前 -> %zu 字节 / %zu AU, 丢弃前 %d 帧输出\n",
			    g_prelude_au, pre_len, stream_len, au_count, g_drop);
		}
	}

	/* 尾部追加: 固件有输出延迟 —— 解 N 帧需要末尾再多若干个 AU 才把最后几帧顶出来。
	   实测不加时尾部恒少 3 帧, 且单纯延长等待(5s)无效。追加若干份首帧 IDR
	   (自包含, 解码安全) 即可把尾帧顶出来; 多产生的帧由 max_frames 截断。 */
	if (g_tail_au > 0 && au_count > 1) {
		size_t idr_len = au_len(0);
		unsigned char *ns = malloc(stream_len + idr_len * (size_t)g_tail_au);
		if (ns && idr_len) {
			memcpy(ns, stream, stream_len);
			for (int k = 0; k < g_tail_au; k++)
				memcpy(ns + stream_len + k * idr_len, stream + au_off[0], idr_len);
			free(stream);
			stream = ns;
			stream_len += idr_len * (size_t)g_tail_au;
			split_au();
			LOG("[1c] 尾部追加 %d 个 IDR AU (每个 %zu 字节) -> %zu 字节 / %zu AU\n",
			    g_tail_au, idr_len, stream_len, au_count);
		}
	}

	fd = open(dev, O_RDWR | O_NONBLOCK);
	if (fd < 0) { LOG("[2] open FAIL: %s\n", errs(errno)); return 1; }
	memset(&cap, 0, sizeof(cap));
	if (xioctl(VIDIOC_QUERYCAP, &cap)) { LOG("[2] QUERYCAP FAIL\n"); return 1; }
	unsigned int dc = cap.device_caps ? cap.device_caps : cap.capabilities;
	mplane = !!(dc & V4L2_CAP_VIDEO_M2M_MPLANE);

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	fmt.fmt.pix_mp.pixelformat = out_fourcc;
	fmt.fmt.pix_mp.width = 1280;
	fmt.fmt.pix_mp.height = 720;
	/* OUTPUT(码流) 缓冲大小。驱动 vdec_s_fmt 会把 src_buffer_size 取为此值。
	   太小会把大 AU(1080p 的 IDR) 截断 -> 静默丢帧。默认 4MB。 */
	fmt.fmt.pix_mp.plane_fmt[0].sizeimage = (unsigned int)g_out_size;
	fmt.fmt.pix_mp.num_planes = 1;
	if (xioctl(VIDIOC_S_FMT, &fmt)) { LOG("[3] S_FMT OUTPUT FAIL: %s\n", errs(errno)); return 1; }

	LOG("[4] 申请 OUTPUT buffer:\n");
	{
		/* CMA 有限(本设备 CmaFree 常只剩 ~270MB), 数量*大小超了驱动只会给很少的 buffer,
		   表现为"码流只送进去几个 AU 就停"。这里自适应缩小单缓冲重试。 */
		int attempt, k, q;
		for (attempt = 0; attempt < 5; attempt++) {
			if (req_bufs(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
			             g_out_bufs, out_bufs, &n_out)) return 1;
			if (n_out >= 4) break;
			LOG("    ! CMA 不足: 只分到 %d/%d 个 (每个 %zu 字节), 缩小后重试\n",
			    n_out, g_out_bufs, g_out_size);
			for (k = 0; k < n_out; k++)
				for (q = 0; q < out_bufs[k].nplanes; q++)
					munmap(out_bufs[k].start[q], out_bufs[k].len[q]);
			n_out = 0;
			g_out_size /= 2;
			if (g_out_size < 262144) { LOG("[4] 缓冲过小, 放弃\n"); return 1; }
			fmt.fmt.pix_mp.plane_fmt[0].sizeimage = (unsigned int)g_out_size;
			if (xioctl(VIDIOC_S_FMT, &fmt)) {
				LOG("[3] S_FMT OUTPUT FAIL: %s\n", errs(errno)); return 1;
			}
		}
		if (n_out < 2) { LOG("[4] OUTPUT 缓冲不足\n"); return 1; }
	}

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2_EVENT_SOURCE_CHANGE;
	if (xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub)) LOG("[5] SUBSCRIBE FAIL: %s\n", errs(errno));

	t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	if (xioctl(VIDIOC_STREAMON, &t)) { LOG("[6] STREAMON OUTPUT FAIL: %s\n", errs(errno)); return 1; }

	for (i = 0; i < n_out && sent < au_count && sent < 2; i++) {
		size_t len = au_len(sent);
		if (len > out_bufs[i].len[0]) len = out_bufs[i].len[0];
		memcpy(out_bufs[i].start[0], stream + au_off[sent], len);
		if (qbuf_out(i, len)) break;
		sent++;
	}
	LOG("[7] 已送 %zu AU, 等 source change...\n", sent);

	for (i = 0; i < 50; i++) {
		usleep(100000);
		memset(&ev, 0, sizeof(ev));
		rc = xioctl(VIDIOC_DQEVENT, &ev);
		if (rc == 0 && ev.type == V4L2_EVENT_SOURCE_CHANGE) {
			got_src_change = 1;
			LOG("[8] 收到 SOURCE_CHANGE (第 %d 次轮询)\n", i + 1);
			break;
		}
		struct v4l2_buffer b; struct v4l2_plane pl[MAX_PLANES];
		memset(&b, 0, sizeof(b)); memset(pl, 0, sizeof(pl));
		b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE; b.memory = V4L2_MEMORY_MMAP;
		b.length = MAX_PLANES; b.m.planes = pl;
		if (xioctl(VIDIOC_DQBUF, &b) == 0 && sent < au_count) {
			size_t len = au_len(sent);
			if (len > out_bufs[b.index].len[0]) len = out_bufs[b.index].len[0];
			memcpy(out_bufs[b.index].start[0], stream + au_off[sent], len);
			qbuf_out(b.index, len);
			sent++;
		}
	}
	if (!got_src_change) LOG("[8] 未收到 SOURCE_CHANGE, 继续\n");

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (xioctl(VIDIOC_G_FMT, &fmt)) { LOG("[9] G_FMT CAPTURE FAIL: %s\n", errs(errno)); return 1; }
	g_cap_w = fmt.fmt.pix_mp.width;
	g_cap_h = fmt.fmt.pix_mp.height;
	g_cap_vis_h = g_cap_h;      /* 真实画面高度, req_bufs 之后 g_cap_h 会被改成对齐高度 */
	LOG("[9] CAPTURE: %c%c%c%c %ux%u sizeimage=%u bytesperline=%u\n",
	    fmt.fmt.pix_mp.pixelformat & 0xff, (fmt.fmt.pix_mp.pixelformat >> 8) & 0xff,
	    (fmt.fmt.pix_mp.pixelformat >> 16) & 0xff, (fmt.fmt.pix_mp.pixelformat >> 24) & 0xff,
	    g_cap_w, g_cap_h, fmt.fmt.pix_mp.plane_fmt[0].sizeimage,
	    fmt.fmt.pix_mp.plane_fmt[0].bytesperline);

	LOG("[10] 申请 CAPTURE buffer:\n");
	/* capture 缓冲数: 平台 G12A H.264 声明 max_buffers=24。给少了固件排不空尾部帧,
	   实测 20 个时 1080p 恒定少 3 帧、720p 偶发少 1 帧; 给到 24 即完整。 */
	if (req_bufs(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, g_cap_bufs, cap_bufs, &n_cap)) return 1;
	for (i = 0; i < n_cap; i++) qbuf_cap(i);

	t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (xioctl(VIDIOC_STREAMON, &t)) { LOG("[11] STREAMON CAPTURE FAIL: %s\n", errs(errno)); return 1; }
	LOG("[11] STREAMON CAPTURE OK, 开始解码\n");

	/* 输出目标 */
	if (!strcmp(outpath, "-")) {
		fp = stdout;
	} else {
		fp = fopen(outpath, "wb");
		if (!fp) { LOG("无法打开输出 %s\n", outpath); return 1; }
	}
	LOG("     stride=%u 对齐高度=%u  (画面 %ux%u)\n", g_cap_bpl, g_cap_h, g_cap_w, g_cap_h);

	clock_gettime(CLOCK_MONOTONIC, &t0);
	long long t0ms = now_ms(), last_ms = t0ms;
	int stop_sent = 0, eos = 0;
	while (frames < max_frames) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN | POLLOUT };
		int r = poll(&pfd, 1, 100);
		if (r <= 0) goto chk;
		if ((pfd.revents & POLLOUT) && sent < au_count) {
			struct v4l2_buffer b; struct v4l2_plane pl[MAX_PLANES];
			memset(&b, 0, sizeof(b)); memset(pl, 0, sizeof(pl));
			b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE; b.memory = V4L2_MEMORY_MMAP;
			b.length = MAX_PLANES; b.m.planes = pl;
			if (xioctl(VIDIOC_DQBUF, &b) == 0) {
				size_t len = au_len(sent);
				if (len > out_bufs[b.index].len[0]) {
					g_truncated++;
					LOG("! AU %zu 长 %zu 超过 OUTPUT 缓冲 %zu, 被截断(会丢帧)\n",
					    sent, len, out_bufs[b.index].len[0]);
					len = out_bufs[b.index].len[0];
				}
				memcpy(out_bufs[b.index].start[0], stream + au_off[sent], len);
				qbuf_out(b.index, len);
				sent++;
			}
		}
		/* 码流送完 -> 发 V4L2_DEC_CMD_STOP, 让固件把尾部还压着的帧 flush 出来。
		   (staging/meson/vdec 的 vdec_decoder_cmd 会向 esparser 投递 4KB EOS 序列;
		    其中 vdec_wait_inactive() 最多等 50ms 即返回, 不会永久阻塞) */
		if (sent >= au_count && !stop_sent && !g_nodrain) {
			struct v4l2_decoder_cmd dc;
			memset(&dc, 0, sizeof(dc));
			dc.cmd = V4L2_DEC_CMD_STOP;
			if (xioctl(VIDIOC_DECODER_CMD, &dc) == 0)
				LOG("[drain] V4L2_DEC_CMD_STOP 已发送, 等待尾部帧\n");
			else
				LOG("[drain] STOP 失败: %s (放弃 drain, 靠超时退出)\n", errs(errno));
			stop_sent = 1;
			last_ms = now_ms();
		}
		if (pfd.revents & POLLIN) {
			struct v4l2_buffer b; struct v4l2_plane pl[MAX_PLANES];
			memset(&b, 0, sizeof(b)); memset(pl, 0, sizeof(pl));
			b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; b.memory = V4L2_MEMORY_MMAP;
			b.length = MAX_PLANES; b.m.planes = pl;
			if (xioctl(VIDIOC_DQBUF, &b) == 0) {
				/* 丢弃预热段产生的带偏移帧 */
				if (g_drop > 0) {
					g_drop--;
					LOG("[drop] 丢弃预热帧 (还剩 %d 帧待丢)\n", g_drop);
					qbuf_cap(b.index);
					last_ms = now_ms();
					continue;
				}
				if (g_compact) {
					/* 紧凑 NV12: 只写有效行, 去掉 720->768 的对齐 padding */
					size_t vh = g_cap_vis_h ? g_cap_vis_h : g_cap_h;
					size_t yb = (size_t)g_cap_bpl * vh;
					size_t ub = (size_t)g_cap_bpl * (vh / 2);
					if (fp) {
						fwrite(cap_bufs[b.index].start[0], 1, yb, fp);
						if (mplane && b.length > 1)
							fwrite(cap_bufs[b.index].start[1], 1, ub, fp);
					}
				} else {
					int np2 = mplane ? b.length : 1, p;
					for (p = 0; p < np2; p++) {
						size_t bl = mplane ? pl[p].bytesused : b.bytesused;
						if (fp && bl) { fwrite(cap_bufs[b.index].start[p], 1, bl, fp); }
					}
				}
				frames++;
				/* 周期采样: SAMPLE_EVERY=N 时每 N 帧打印中间行 16 个 Y 采样点 */
				if (g_sample_every && (frames % g_sample_every) == 0) {
					unsigned char *y0 = cap_bufs[b.index].start[0];
					size_t row = g_cap_h > 1 ? g_cap_h / 2 : 0;
					unsigned char *rowp = y0 + row * (size_t)g_cap_bpl;
					LOG("SMPL f=%d:", frames);
					for (int k = 0; k < 16; k++) {
						int x = 40 + k * 80;
						if (x < (int)g_cap_w) LOG(" %d", rowp[x]);
					}
					LOG("\n");
				}
				if (b.flags & V4L2_BUF_FLAG_LAST) {
					LOG("[drain] 收到 LAST 帧, 固件已排空\n");
					eos = 1;
				}
				qbuf_cap(b.index);
				last_ms = now_ms();
			}
		}
chk:
		if (eos) break;   /* drain 完成, 尾部帧已全部取回 */
		/* 退出判据(用真实时钟): 码流送完且连续 IDLE_MS 无新帧 -> 结束; 总保险 TOTAL_MS */
		{
			/* 预期帧数已达到(或超出) -> 只需确认没有新帧即可退出, 不必空等 g_drain_ms。
			   否则(帧数不足, 固件可能还压着)仍按 g_drain_ms 等, 尽量把尾帧捞回来。 */
			int idle;
			if (g_expect > 0 && frames >= g_expect) idle = 150;
			else idle = stop_sent ? g_drain_ms : g_idle_ms;
			if (sent >= au_count && (now_ms() - last_ms) > idle) break;
		}
		if ((now_ms() - t0ms) > TOTAL_MS) { LOG("! 总超时 %dms\n", (int)TOTAL_MS); break; }
	}
	clock_gettime(CLOCK_MONOTONIC, &t1);
	double sec = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
	if (fp && fp != stdout) fclose(fp);
	else if (fp == stdout) fflush(fp);

	LOG("\n=== 结果 ===\n");
	LOG("取出帧数: %d\n", frames);
	LOG("送入 AU : %zu / %zu   (截断 %d 个, OUTPUT 缓冲 %zu 字节)\n",
	    sent, au_count, g_truncated, out_bufs[0].len[0]);
	LOG("用时: %.3f 秒  速度: %.2fx 实时(30fps)\n", sec, frames / 30.0 / (sec > 0 ? sec : 1));
	LOG("帧尺寸: 画面 %ux%u (对齐高 %u) stride=%u 平面: Y=%zu UV=%zu  输出=%s\n",
	    g_cap_w, g_cap_vis_h ? g_cap_vis_h : g_cap_h, g_cap_h, g_cap_bpl,
	    cap_bufs[0].len[0], cap_bufs[0].len[1], g_compact ? "紧凑" : "保对齐");

	close(fd);
	return frames > 0 ? 0 : 1;
}
