/*
 * ge2d_selftest.c —— OESP GE2D（Amlogic 2D 加速单元）自检
 *
 * 目的：证明 2D 加速单元「真的在工作」，而不只是"模块加载着"。
 *   主线 ge2d 驱动在 G12A/G12B 上有个著名陷阱：它按 AXG 的方式写 BADDR，
 *   而 G12 必须用 canvas 索引寻址 —— 结果是【命令照常完成、中断照常响，
 *   但目标缓冲一个字节都没被写】（"跑通了却全零"）。
 *   → 所以本程序不信任返回码，坚持做逐像素比对。
 *
 * 做法（V4L2 内存到内存）：
 *   OUTPUT  = RGB24  (3 bytes/px)   填一幅梯度测试图
 *   CAPTURE = XRGB32 (4 bytes/px)
 *   转换完成逐像素比对；同时跑一遍 CPU 软转做时间对照。
 *
 * 用法： ge2d_selftest [边长(默认512)] [重复次数(默认10)]
 * 输出： 单行 JSON（mpx_s = 百万像素/秒，反映 2D 单元实际吞吐）
 *
 * ⛔ 安全边界：只碰 name == meson-ge2d 的设备节点，绝不碰 video26（雷区）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <poll.h>
#include <linux/videodev2.h>

#define FMT_OUT V4L2_PIX_FMT_RGB24    /* 'RGB3' */
#define FMT_CAP V4L2_PIX_FMT_XRGB32   /* 'XR24' */

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}
static double cpu_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* 按名字找设备：⛔ 不能写死编号 —— ge2d 抢号后 vdec 会顺延 */
static int find_dev(char *out, size_t n)
{
    DIR *d = opendir("/sys/class/video4linux");
    struct dirent *e;
    if (!d) return -1;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "video", 5)) continue;
        char p[320], nm[320];
        snprintf(p, sizeof p, "/sys/class/video4linux/%s/name", e->d_name);
        FILE *f = fopen(p, "r");
        if (!f) continue;
        if (!fgets(nm, sizeof nm, f)) { fclose(f); continue; }
        fclose(f);
        if (strstr(nm, "ge2d")) {
            snprintf(out, n, "/dev/%s", e->d_name);
            closedir(d);
            return 0;
        }
    }
    closedir(d);
    return -1;
}

#define ck(fd, req, arg) do {                                   \
    if (ioctl((fd), (req), (arg)) < 0) {                        \
        fprintf(stderr, "ioctl %s failed: %s\n", #req, strerror(errno)); \
        goto fail;                                              \
    }                                                           \
} while (0)

int main(int argc, char **argv)
{
    int side = (argc > 1) ? atoi(argv[1]) : 512;
    if (side < 16) side = 16;
    if (side > 3840) side = 3840;
    const unsigned W = (unsigned)side, H = (unsigned)side;

    char dev[320];
    int fd = -1, rc = 1;
    unsigned char *src = NULL, *dst = NULL, *ref = NULL;
    struct v4l2_buffer b_out, b_cap;
    struct v4l2_plane dummy; /* 未用，占位避免告警 */

    memset(&b_out, 0, sizeof b_out);
    memset(&b_cap, 0, sizeof b_cap);
    memset(&dummy, 0, sizeof dummy);

    const size_t src_sz = (size_t)W * H * 3;
    const size_t dst_sz = (size_t)W * H * 4;

    if (find_dev(dev, sizeof dev) < 0) {
        printf("{\"ok\":false,\"stage\":\"find_dev\",\"msg\":\"未找到 name=meson-ge2d 的设备节点\"}\n");
        return 2;
    }

    fd = open(dev, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        printf("{\"ok\":false,\"stage\":\"open\",\"dev\":\"%s\",\"msg\":\"%s\"}\n", dev, strerror(errno));
        return 2;
    }

    struct v4l2_capability cap; memset(&cap, 0, sizeof cap);
    ck(fd, VIDIOC_QUERYCAP, &cap);

    struct v4l2_format fo; memset(&fo, 0, sizeof fo);
    fo.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fo.fmt.pix.width = W; fo.fmt.pix.height = H;
    fo.fmt.pix.pixelformat = FMT_OUT;
    fo.fmt.pix.field = V4L2_FIELD_NONE;
    fo.fmt.pix.sizeimage = (unsigned)src_sz;
    ck(fd, VIDIOC_S_FMT, &fo);

    struct v4l2_format fc; memset(&fc, 0, sizeof fc);
    fc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fc.fmt.pix.width = W; fc.fmt.pix.height = H;
    fc.fmt.pix.pixelformat = FMT_CAP;
    fc.fmt.pix.field = V4L2_FIELD_NONE;
    fc.fmt.pix.sizeimage = (unsigned)dst_sz;
    ck(fd, VIDIOC_S_FMT, &fc);
    /* 驱动会把 capture 尺寸拉平到 output（它不支持缩放），以回读值为准 */
    unsigned cw = fc.fmt.pix.width, ch = fc.fmt.pix.height;
    unsigned cfmt = fc.fmt.pix.pixelformat;

    struct v4l2_requestbuffers rb; memset(&rb, 0, sizeof rb);
    rb.count = 1; rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; rb.memory = V4L2_MEMORY_MMAP;
    ck(fd, VIDIOC_REQBUFS, &rb);
    memset(&rb, 0, sizeof rb);
    rb.count = 1; rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; rb.memory = V4L2_MEMORY_MMAP;
    ck(fd, VIDIOC_REQBUFS, &rb);

    /* 映射 + 填源图 */
    memset(&b_out, 0, sizeof b_out);
    b_out.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; b_out.memory = V4L2_MEMORY_MMAP; b_out.index = 0;
    ck(fd, VIDIOC_QUERYBUF, &b_out);
    src = mmap(NULL, b_out.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b_out.m.offset);
    if (src == MAP_FAILED) { perror("mmap out"); goto fail; }

    memset(&b_cap, 0, sizeof b_cap);
    b_cap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b_cap.memory = V4L2_MEMORY_MMAP; b_cap.index = 0;
    ck(fd, VIDIOC_QUERYBUF, &b_cap);
    dst = mmap(NULL, b_cap.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b_cap.m.offset);
    if (dst == MAP_FAILED) { perror("mmap cap"); goto fail; }

    ref = malloc(dst_sz);
    if (!ref) goto fail;

    for (unsigned y = 0; y < H; y++) {
        for (unsigned x = 0; x < W; x++) {
            size_t o = ((size_t)y * W + x) * 3;
            unsigned char r = (unsigned char)((x * 3 + y) & 0xff);
            unsigned char g = (unsigned char)((x ^ y) & 0xff);
            unsigned char b = (unsigned char)((x * 5 + y * 2 + 7) & 0xff);
            src[o] = r; src[o + 1] = g; src[o + 2] = b;
            size_t p = ((size_t)y * W + x) * 4;
            ref[p] = 0xff; ref[p + 1] = r; ref[p + 2] = g; ref[p + 3] = b; /* X,R,G,B */
        }
    }
    memset(dst, 0x00, b_cap.length);

    int repeat = (argc > 2) ? atoi(argv[2]) : 10;
    if (repeat < 1) repeat = 1;
    if (repeat > 200) repeat = 200;

    double cpu0 = cpu_s(), t0 = now_s();
    for (int it = 0; it < repeat; it++) {
    memset(&b_out, 0, sizeof b_out);
    b_out.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; b_out.memory = V4L2_MEMORY_MMAP; b_out.index = 0;
    b_out.bytesused = (unsigned)src_sz; b_out.length = (unsigned)src_sz;
    ck(fd, VIDIOC_QBUF, &b_out);

    memset(&b_cap, 0, sizeof b_cap);
    b_cap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b_cap.memory = V4L2_MEMORY_MMAP; b_cap.index = 0;
    ck(fd, VIDIOC_QBUF, &b_cap);

    int on = V4L2_BUF_TYPE_VIDEO_OUTPUT;   ck(fd, VIDIOC_STREAMON, &on);
    on = V4L2_BUF_TYPE_VIDEO_CAPTURE;      ck(fd, VIDIOC_STREAMON, &on);

    struct pollfd pfd = { fd, POLLIN | POLLOUT, 0 };
    if (poll(&pfd, 1, 3000) <= 0) { fprintf(stderr, "poll timeout\n"); goto fail; }

    memset(&b_cap, 0, sizeof b_cap);
    b_cap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b_cap.memory = V4L2_MEMORY_MMAP;
    ck(fd, VIDIOC_DQBUF, &b_cap);
    memset(&b_out, 0, sizeof b_out);
    b_out.type = V4L2_BUF_TYPE_VIDEO_OUTPUT; b_out.memory = V4L2_MEMORY_MMAP;
    ioctl(fd, VIDIOC_DQBUF, &b_out);

    on = V4L2_BUF_TYPE_VIDEO_OUTPUT;  ioctl(fd, VIDIOC_STREAMOFF, &on);
    on = V4L2_BUF_TYPE_VIDEO_CAPTURE; ioctl(fd, VIDIOC_STREAMOFF, &on);
    }
    double wall = now_s() - t0, cpu_use = cpu_s() - cpu0;

    /* ---- 逐像素比对（自适应字节序，避免命名差异误判） ---- */
    unsigned char *d = dst;
    long long zeros = 0;
    for (size_t i = 0; i < dst_sz; i++) if (d[i] == 0) zeros++;

    /* 候选排布：{X,R,G,B} {B,G,R,X} {R,G,B,X} {X,B,G,R} */
    static const int order[4][4] = {
        {3, 0, 1, 2},   /* 内存 [X][R][G][B] */
        {0, 3, 2, 1},   /* 内存 [B][G][R][X] */
        {3, 2, 1, 0},   /* 内存 [R][G][B][X] */
        {0, 1, 2, 3},   /* 内存 [X][B][G][R] */
    };
    static const char *oname[4] = { "XRGB", "BGRX", "RGBX", "XBGR" };
    int best = -1; long long bestbad = -1;
    for (int k = 0; k < 4; k++) {
        long long bad = 0;
        for (unsigned y = 0; y < H; y++) {
            for (unsigned x = 0; x < W; x++) {
                size_t o = ((size_t)y * W + x) * 3;
                size_t p = ((size_t)y * W + x) * 4;
                unsigned char v[3] = { src[o], src[o + 1], src[o + 2] }; /* R,G,B */
                int iR = order[k][1], iG = order[k][2], iB = order[k][3];
                if (d[p + iR] != v[0] || d[p + iG] != v[1] || d[p + iB] != v[2]) bad++;
            }
        }
        if (best < 0 || bad < bestbad) { best = k; bestbad = bad; }
        if (bad == 0) break;
    }

    /* CPU 软转对照 */
    double c0 = cpu_s();
    unsigned char *tmp = malloc(dst_sz);
    if (tmp) {
        for (int it = 0; it < repeat; it++)
        for (unsigned y = 0; y < H; y++)
            for (unsigned x = 0; x < W; x++) {
                size_t o = ((size_t)y * W + x) * 3;
                size_t p = ((size_t)y * W + x) * 4;
                tmp[p] = 0xff; tmp[p + 1] = src[o]; tmp[p + 2] = src[o + 1]; tmp[p + 3] = src[o + 2];
            }
        free(tmp);
    }
    double cpu_soft = cpu_s() - c0;

    long long px = (long long)W * H;
    printf("{"
           "\"ok\":%s,"
           "\"dev\":\"%s\","
           "\"driver\":\"%s\","
           "\"w\":%u,\"h\":%u,\"cap_w\":%u,\"cap_h\":%u,\"cap_fmt\":\"%c%c%c%c\","
           "\"layout\":\"%s\","
           "\"pixels\":%lld,\"mismatch\":%lld,"
           "\"all_zero\":%s,"
           "\"repeat\":%d,"
           "\"wall_ms\":%.2f,\"cpu_ms\":%.2f,\"cpu_soft_ms\":%.2f,"
           "\"mpx_s\":%.1f,\"cpu_soft_mpx_s\":%.1f,"
           "\"msg\":\"%s\"}\n",
           bestbad == 0 ? "true" : "false",
           dev, cap.driver,
           W, H, cw, ch,
           (cfmt >> 0) & 0xff, (cfmt >> 8) & 0xff, (cfmt >> 16) & 0xff, (cfmt >> 24) & 0xff,
           oname[best],
           px, bestbad,
           (zeros == (long long)dst_sz) ? "true" : "false",
           repeat,
           wall * 1000.0, cpu_use * 1000.0, cpu_soft * 1000.0,
           wall > 0 ? (double)px * repeat / wall / 1e6 : 0.0,
           cpu_soft > 0 ? (double)px * repeat / cpu_soft / 1e6 : 0.0,
           bestbad == 0 ? "硬件转换与 CPU 参考逐像素一致"
                        : (zeros == (long long)dst_sz ? "输出全为零 —— canvas 寻址失效（补丁未生效）"
                                                      : "像素比对不一致，2D 单元输出异常"));
    rc = (bestbad == 0) ? 0 : 1;

    if (src) munmap(src, b_out.length ? b_out.length : src_sz);
    if (dst) munmap(dst, b_cap.length ? b_cap.length : dst_sz);
    free(ref);
    close(fd);
    return rc;

fail:
    printf("{\"ok\":false,\"stage\":\"ioctl\",\"dev\":\"%s\",\"msg\":\"%s\"}\n", dev, strerror(errno));
    if (fd >= 0) close(fd);
    free(ref);
    return 3;
}
