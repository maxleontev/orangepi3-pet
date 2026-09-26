/*
 * Fullscreen Wayland panel: USB UVC preview + pan-servo track control.
 *
 * Selected when INFO_PANEL=track. Redesign home for object-follow:
 *   detect evidence → associate → track FSM → servo (only in LOCK).
 * The old info-panel-camera frame-diff→EMA→Kalman→PID path stays untouched.
 *
 * Capture: V4L2 MMAP. Prefer YUYV (hub-stable), else MJPEG (libjpeg-turbo).
 * Device: INFO_PANEL_CAMERA_DEVICE, else first /dev/video* with CAPTURE.
 * Size: INFO_PANEL_CAMERA_SIZE=WxH (service default 320x240).
 *
 * Servo pan: HW PWM0 on PD22 (CON12 pin 7). Disable with INFO_PANEL_SERVO=0;
 * flip with INFO_PANEL_SERVO_INVERT=1.
 *
 * SIGUSR1 → /tmp/info-panel-screenshot.png (same contract as other panels).
 */

#define _GNU_SOURCE
#include <cairo/cairo.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define SHOT_PNG "/tmp/info-panel-screenshot.png"
#define SHOT_TMP "/tmp/info-panel-screenshot.png.tmp"
#define SHOT_ERR "/tmp/info-panel-screenshot.err"

#define V4L_BUFS 4
#define FRAME_MS 100
#define POLL_MIN_MS 10
#define CAM_RETRY_MS 2000
#define CAM_RETRY_MAX_MS 8000
#define STATUS_H 36
#define DECODE_FAIL_REOPEN 40

/* Pan servo on pwmchip0/pwm0 (PD22). Period 20 ms; pulse 1.0–2.0 ms. */
#define SERVO_PWM_CHIP "/sys/class/pwm/pwmchip0"
#define SERVO_PWM_PATH "/sys/class/pwm/pwmchip0/pwm0"
#define SERVO_PERIOD_NS 20000000L
#define SERVO_DUTY_MIN_NS 1000000L
#define SERVO_DUTY_MAX_NS 2000000L
#define SERVO_DUTY_CENTER_NS 1500000L
#define SERVO_MAX_STEP_NS 80000L

enum track_state {
	TRACK_IDLE = 0,
	TRACK_ACQUIRE,
	TRACK_LOCK,
	TRACK_COAST,
	TRACK_EGO_BLIND,
	TRACK_LOST,
};

struct shm_buffer {
	struct wl_buffer *wl_buffer;
	void *data;
	size_t size;
	int width;
	int height;
	bool busy;
};

struct v4l_buf {
	void *start;
	size_t length;
};

enum cam_pixfmt {
	CAM_FMT_NONE = 0,
	CAM_FMT_MJPEG,
	CAM_FMT_YUYV,
};

struct cam_state {
	int fd;
	enum cam_pixfmt fmt;
	uint32_t fourcc;
	unsigned width;
	unsigned height;
	struct v4l_buf bufs[V4L_BUFS];
	unsigned nbufs;
	bool streaming;
	bool have_frame;
	char status[96];
	char device[64];
	uint64_t next_retry_ms;
	unsigned retry_ms;
	unsigned decode_fails;
	uint8_t *rgb;
	size_t rgb_size;
	unsigned rgb_w;
	unsigned rgb_h;
};

/* Horizontal track estimate in camera pixel coords (filled by detect later). */
struct track_state_data {
	enum track_state state;
	bool have_target;
	float x;
	float y;
	float half_w;
	float half_h;
	unsigned acquire_hits;
	unsigned miss_frames;
	unsigned ego_frames;
};

struct servo_state {
	bool enabled;
	bool ready;
	int pan_sign; /* +1: object on right → increase duty */
	long duty_ns;
};

struct app {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct xdg_wm_base *wm_base;
	struct wl_surface *surface;
	struct xdg_surface *xdg_surface;
	struct xdg_toplevel *xdg_toplevel;
	struct wl_output *output;
	int32_t output_width;
	int32_t output_height;
	int32_t scale;
	bool configured;
	bool running;
	struct shm_buffer buffers[2];
	int buffer_idx;
	int last_committed;
	bool have_committed;
	struct cam_state cam;
	struct servo_state servo;
	struct track_state_data track;
	bool frame_dirty;
};

static volatile sig_atomic_t screenshot_requested;

static const char *track_state_name(enum track_state s)
{
	switch (s) {
	case TRACK_IDLE:
		return "idle";
	case TRACK_ACQUIRE:
		return "acquire";
	case TRACK_LOCK:
		return "lock";
	case TRACK_COAST:
		return "coast";
	case TRACK_EGO_BLIND:
		return "ego";
	case TRACK_LOST:
		return "lost";
	default:
		return "?";
	}
}

static uint64_t monotonic_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

static int create_shm_file(size_t size)
{
	char template[] = "/tmp/info-panel-track-XXXXXX";
	int fd = mkostemp(template, O_CLOEXEC);

	if (fd < 0)
		return -1;
	unlink(template);
	if (ftruncate(fd, (off_t)size) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void buffer_release(void *data, struct wl_buffer *buf)
{
	struct shm_buffer *b = data;

	(void)buf;
	b->busy = false;
}

static const struct wl_buffer_listener buffer_listener = {
	.release = buffer_release,
};

static int shm_buffer_init(struct app *app, struct shm_buffer *b, int width, int height)
{
	const int stride = width * 4;

	b->size = (size_t)stride * (size_t)height;
	b->width = width;
	b->height = height;
	b->busy = false;

	int fd = create_shm_file(b->size);
	if (fd < 0)
		return -1;

	b->data = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (b->data == MAP_FAILED) {
		close(fd);
		return -1;
	}

	struct wl_shm_pool *pool = wl_shm_create_pool(app->shm, fd, (int32_t)b->size);
	close(fd);
	b->wl_buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride,
						 WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	wl_buffer_add_listener(b->wl_buffer, &buffer_listener, b);
	return 0;
}

static void shm_buffer_destroy(struct shm_buffer *b)
{
	if (b->wl_buffer)
		wl_buffer_destroy(b->wl_buffer);
	if (b->data && b->data != MAP_FAILED)
		munmap(b->data, b->size);
	memset(b, 0, sizeof(*b));
}

static void on_sigusr1(int signo)
{
	(void)signo;
	screenshot_requested = 1;
}

static void shot_fail(const char *msg)
{
	FILE *f;

	fprintf(stderr, "info-panel-track: screenshot: %s\n", msg);
	f = fopen(SHOT_ERR, "w");
	if (f) {
		fprintf(f, "%s\n", msg);
		fclose(f);
	}
	unlink(SHOT_PNG);
	unlink(SHOT_TMP);
}

static void dump_screenshot(struct app *app)
{
	struct shm_buffer *b;
	cairo_surface_t *cs;
	cairo_status_t st;

	screenshot_requested = 0;
	unlink(SHOT_ERR);

	if (!app->have_committed) {
		shot_fail("no frame committed yet");
		return;
	}
	b = &app->buffers[app->last_committed];
	if (!b->data || b->data == MAP_FAILED || b->width <= 0 || b->height <= 0) {
		shot_fail("committed buffer is empty");
		return;
	}

	cs = cairo_image_surface_create_for_data(
		b->data, CAIRO_FORMAT_ARGB32, b->width, b->height, b->width * 4);
	if (cairo_surface_status(cs) != CAIRO_STATUS_SUCCESS) {
		cairo_surface_destroy(cs);
		shot_fail("cairo surface failed");
		return;
	}
	cairo_surface_mark_dirty(cs);
	st = cairo_surface_write_to_png(cs, SHOT_TMP);
	cairo_surface_destroy(cs);
	if (st != CAIRO_STATUS_SUCCESS) {
		shot_fail(cairo_status_to_string(st));
		return;
	}
	if (rename(SHOT_TMP, SHOT_PNG) != 0) {
		shot_fail("rename failed");
		return;
	}
	chmod(SHOT_PNG, 0644);
	fprintf(stderr, "info-panel-track: screenshot %dx%d -> %s\n",
		b->width, b->height, SHOT_PNG);
}

/* ---- Servo -------------------------------------------------------------- */

static int servo_write_str(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	ssize_t n;

	if (fd < 0)
		return -1;
	n = write(fd, val, strlen(val));
	close(fd);
	return (n < 0) ? -1 : 0;
}

static int servo_write_ll(const char *path, long long v)
{
	char buf[32];

	snprintf(buf, sizeof(buf), "%lld", v);
	return servo_write_str(path, buf);
}

static void servo_close(struct servo_state *sv)
{
	if (!sv->ready)
		return;
	servo_write_str(SERVO_PWM_PATH "/enable", "0");
	sv->ready = false;
}

static bool servo_init(struct servo_state *sv)
{
	const char *env = getenv("INFO_PANEL_SERVO");
	const char *inv = getenv("INFO_PANEL_SERVO_INVERT");

	memset(sv, 0, sizeof(*sv));
	sv->pan_sign = -1; /* camera-on-servo: object on right → decrease duty */
	sv->duty_ns = SERVO_DUTY_CENTER_NS;
	if (env && (env[0] == '0' || env[0] == 'n' || env[0] == 'N' ||
		    env[0] == 'f' || env[0] == 'F')) {
		sv->enabled = false;
		return false;
	}
	sv->enabled = true;
	if (inv && inv[0] && inv[0] != '0' && inv[0] != 'n' && inv[0] != 'N' &&
	    inv[0] != 'f' && inv[0] != 'F')
		sv->pan_sign = -sv->pan_sign;

	if (access(SERVO_PWM_PATH "/period", F_OK) != 0) {
		if (servo_write_str(SERVO_PWM_CHIP "/export", "0") < 0) {
			fprintf(stderr,
				"info-panel-track: servo pwm0 missing (need root export)\n");
			sv->enabled = false;
			return false;
		}
		usleep(50000);
	}
	servo_write_str(SERVO_PWM_PATH "/enable", "0");
	if (servo_write_ll(SERVO_PWM_PATH "/period", SERVO_PERIOD_NS) < 0 ||
	    servo_write_ll(SERVO_PWM_PATH "/duty_cycle", SERVO_DUTY_CENTER_NS) < 0) {
		fprintf(stderr, "info-panel-track: servo pwm setup failed\n");
		sv->enabled = false;
		return false;
	}
	servo_write_str(SERVO_PWM_PATH "/polarity", "normal");
	if (servo_write_str(SERVO_PWM_PATH "/enable", "1") < 0) {
		fprintf(stderr, "info-panel-track: servo pwm enable failed\n");
		sv->enabled = false;
		return false;
	}
	sv->ready = true;
	sv->duty_ns = SERVO_DUTY_CENTER_NS;
	fprintf(stderr, "info-panel-track: servo pan on %s (sign=%d)\n",
		SERVO_PWM_PATH, sv->pan_sign);
	return true;
}

/* Rate-limited duty step. Returns true if PWM actually changed. */
static bool servo_nudge(struct servo_state *sv, long delta_ns)
{
	long duty;
	long step = delta_ns;

	if (!sv->enabled || !sv->ready || step == 0)
		return false;
	if (step > SERVO_MAX_STEP_NS)
		step = SERVO_MAX_STEP_NS;
	else if (step < -SERVO_MAX_STEP_NS)
		step = -SERVO_MAX_STEP_NS;

	if ((sv->duty_ns >= SERVO_DUTY_MAX_NS && step > 0) ||
	    (sv->duty_ns <= SERVO_DUTY_MIN_NS && step < 0))
		return false;

	duty = sv->duty_ns + step;
	if (duty < SERVO_DUTY_MIN_NS)
		duty = SERVO_DUTY_MIN_NS;
	else if (duty > SERVO_DUTY_MAX_NS)
		duty = SERVO_DUTY_MAX_NS;
	if (duty == sv->duty_ns)
		return false;
	if (servo_write_ll(SERVO_PWM_PATH "/duty_cycle", duty) != 0)
		return false;
	sv->duty_ns = duty;
	return true;
}

/*
 * Servo may move only while LOCK. Detection / association will feed
 * track.have_target + track.x; until then this is a no-op.
 */
static void servo_follow_track(struct servo_state *sv, struct cam_state *cam,
			       struct track_state_data *tr)
{
	float err;
	long step;

	if (!sv->enabled || !sv->ready)
		return;
	if (tr->state != TRACK_LOCK || !tr->have_target || cam->rgb_w < 2)
		return;

	err = tr->x - 0.5f * (float)cam->rgb_w;
	/* Deadzone ~4% of width until a real detector lands. */
	if (fabsf(err) < 0.04f * (float)cam->rgb_w)
		return;

	/* Proportional nudge; gain tuned later with real measurements. */
	step = (long)lroundf((float)sv->pan_sign * err * 400.f);
	if (servo_nudge(sv, step)) {
		tr->state = TRACK_EGO_BLIND;
		tr->ego_frames = 3;
	}
}

/* ---- Track FSM (scaffold; detector fills measurements later) ------------ */

static void track_reset(struct track_state_data *tr)
{
	memset(tr, 0, sizeof(*tr));
	tr->state = TRACK_IDLE;
}

/*
 * Per-frame hook after a new RGB frame. Placeholder: no detector yet, so
 * the FSM stays IDLE and the servo never pans. Association + evidence
 * scoring land here in a later change.
 */
static void track_on_frame(struct track_state_data *tr, struct cam_state *cam)
{
	(void)cam;

	switch (tr->state) {
	case TRACK_EGO_BLIND:
		if (tr->ego_frames > 0)
			tr->ego_frames--;
		if (tr->ego_frames == 0)
			tr->state = tr->have_target ? TRACK_LOCK : TRACK_IDLE;
		break;
	case TRACK_COAST:
		if (tr->miss_frames > 0)
			tr->miss_frames--;
		if (tr->miss_frames == 0) {
			tr->have_target = false;
			tr->state = TRACK_LOST;
		}
		break;
	case TRACK_LOST:
		tr->have_target = false;
		tr->state = TRACK_IDLE;
		break;
	case TRACK_IDLE:
	case TRACK_ACQUIRE:
	case TRACK_LOCK:
	default:
		break;
	}
}

/* ---- V4L2 / decode ------------------------------------------------------ */

static void cam_unmap(struct cam_state *cam)
{
	unsigned i;

	for (i = 0; i < cam->nbufs; i++) {
		if (cam->bufs[i].start && cam->bufs[i].start != MAP_FAILED)
			munmap(cam->bufs[i].start, cam->bufs[i].length);
		cam->bufs[i].start = NULL;
		cam->bufs[i].length = 0;
	}
	cam->nbufs = 0;
}

static void cam_release(struct cam_state *cam)
{
	if (cam->streaming && cam->fd >= 0) {
		enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

		ioctl(cam->fd, VIDIOC_STREAMOFF, &type);
		cam->streaming = false;
	}
	cam_unmap(cam);
	if (cam->fd >= 0) {
		close(cam->fd);
		cam->fd = -1;
	}
	cam->fmt = CAM_FMT_NONE;
}

static void cam_close(struct cam_state *cam)
{
	cam_release(cam);
	free(cam->rgb);
	cam->rgb = NULL;
	cam->rgb_size = 0;
	cam->rgb_w = cam->rgb_h = 0;
	cam->have_frame = false;
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

static bool cam_ensure_rgb(struct cam_state *cam, unsigned w, unsigned h)
{
	size_t need = (size_t)w * (size_t)h * 3u;

	if (cam->rgb && cam->rgb_size >= need && cam->rgb_w == w && cam->rgb_h == h)
		return true;
	free(cam->rgb);
	cam->rgb = malloc(need);
	if (!cam->rgb) {
		cam->rgb_size = 0;
		cam->rgb_w = cam->rgb_h = 0;
		return false;
	}
	cam->rgb_size = need;
	cam->rgb_w = w;
	cam->rgb_h = h;
	return true;
}

struct jpeg_err {
	struct jpeg_error_mgr pub;
	jmp_buf setjmp_buffer;
};

static void jpeg_err_exit(j_common_ptr cinfo)
{
	struct jpeg_err *err = (struct jpeg_err *)cinfo->err;

	longjmp(err->setjmp_buffer, 1);
}

static void jpeg_err_output(j_common_ptr cinfo)
{
	(void)cinfo;
}

static bool decode_mjpeg(struct cam_state *cam, const uint8_t *data, size_t len)
{
	struct jpeg_decompress_struct cinfo;
	struct jpeg_err jerr;
	unsigned w, h;
	int row_stride;
	JSAMPROW rowptr[1];

	if (len < 4)
		return false;

	cinfo.err = jpeg_std_error(&jerr.pub);
	jerr.pub.error_exit = jpeg_err_exit;
	jerr.pub.output_message = jpeg_err_output;
	if (setjmp(jerr.setjmp_buffer)) {
		jpeg_destroy_decompress(&cinfo);
		return false;
	}

	jpeg_create_decompress(&cinfo);
	jpeg_mem_src(&cinfo, (unsigned char *)data, (unsigned long)len);
	if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
		jpeg_destroy_decompress(&cinfo);
		return false;
	}
	cinfo.out_color_space = JCS_RGB;
	jpeg_start_decompress(&cinfo);
	w = cinfo.output_width;
	h = cinfo.output_height;
	if (w == 0 || h == 0 || cinfo.output_components != 3) {
		jpeg_destroy_decompress(&cinfo);
		return false;
	}
	if (!cam_ensure_rgb(cam, w, h)) {
		jpeg_destroy_decompress(&cinfo);
		return false;
	}
	row_stride = (int)w * 3;
	while (cinfo.output_scanline < cinfo.output_height) {
		rowptr[0] = cam->rgb + (size_t)cinfo.output_scanline * (size_t)row_stride;
		jpeg_read_scanlines(&cinfo, rowptr, 1);
	}
	jpeg_finish_decompress(&cinfo);
	jpeg_destroy_decompress(&cinfo);
	cam->have_frame = true;
	return true;
}

#ifndef CLAMP
#define CLAMP(v, lo, hi) ((v) < (lo) ? (lo) : ((v) > (hi) ? (hi) : (v)))
#endif

static void yuyv_to_rgb(const uint8_t *src, uint8_t *dst, unsigned w, unsigned h)
{
	unsigned x, y;

	for (y = 0; y < h; y++) {
		const uint8_t *s = src + (size_t)y * (size_t)w * 2u;
		uint8_t *d = dst + (size_t)y * (size_t)w * 3u;

		for (x = 0; x + 1 < w; x += 2) {
			int y0 = s[0], u = s[1], y1 = s[2], v = s[3];
			int c, d0, e;

			s += 4;
			c = y0 - 16;
			d0 = u - 128;
			e = v - 128;
			d[0] = (uint8_t)CLAMP((298 * c + 409 * e + 128) >> 8, 0, 255);
			d[1] = (uint8_t)CLAMP((298 * c - 100 * d0 - 208 * e + 128) >> 8, 0, 255);
			d[2] = (uint8_t)CLAMP((298 * c + 516 * d0 + 128) >> 8, 0, 255);
			c = y1 - 16;
			d[3] = (uint8_t)CLAMP((298 * c + 409 * e + 128) >> 8, 0, 255);
			d[4] = (uint8_t)CLAMP((298 * c - 100 * d0 - 208 * e + 128) >> 8, 0, 255);
			d[5] = (uint8_t)CLAMP((298 * c + 516 * d0 + 128) >> 8, 0, 255);
			d += 6;
		}
	}
}

static bool decode_yuyv(struct cam_state *cam, const uint8_t *data, size_t len)
{
	size_t need = (size_t)cam->width * (size_t)cam->height * 2u;

	if (len < need || cam->width < 2)
		return false;
	if (!cam_ensure_rgb(cam, cam->width, cam->height))
		return false;
	yuyv_to_rgb(data, cam->rgb, cam->width, cam->height);
	cam->have_frame = true;
	return true;
}

static bool cam_try_fmt(int fd, uint32_t fourcc, unsigned *w, unsigned *h)
{
	struct v4l2_format fmt;

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	fmt.fmt.pix.width = *w;
	fmt.fmt.pix.height = *h;
	fmt.fmt.pix.pixelformat = fourcc;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0)
		return false;
	if (fmt.fmt.pix.pixelformat != fourcc)
		return false;
	*w = fmt.fmt.pix.width;
	*h = fmt.fmt.pix.height;
	return *w > 0 && *h > 0;
}

static bool cam_init_mmap(struct cam_state *cam)
{
	struct v4l2_requestbuffers req;
	unsigned i;

	memset(&req, 0, sizeof(req));
	req.count = V4L_BUFS;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	req.memory = V4L2_MEMORY_MMAP;
	if (xioctl(cam->fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2)
		return false;

	cam->nbufs = req.count > V4L_BUFS ? V4L_BUFS : req.count;
	for (i = 0; i < cam->nbufs; i++) {
		struct v4l2_buffer buf;

		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;
		if (xioctl(cam->fd, VIDIOC_QUERYBUF, &buf) < 0)
			return false;
		cam->bufs[i].length = buf.length;
		cam->bufs[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
					  MAP_SHARED, cam->fd, buf.m.offset);
		if (cam->bufs[i].start == MAP_FAILED)
			return false;
		if (xioctl(cam->fd, VIDIOC_QBUF, &buf) < 0)
			return false;
	}
	return true;
}

static bool parse_size_env(unsigned *w, unsigned *h)
{
	const char *s = getenv("INFO_PANEL_CAMERA_SIZE");
	unsigned tw, th;

	if (!s || !*s)
		return false;
	if (sscanf(s, "%ux%u", &tw, &th) != 2 && sscanf(s, "%uX%u", &tw, &th) != 2)
		return false;
	if (tw < 160 || th < 120 || tw > 3840 || th > 2160)
		return false;
	*w = tw;
	*h = th;
	return true;
}

static bool cam_open_path(struct cam_state *cam, const char *path)
{
	struct v4l2_capability cap;
	static const struct {
		uint32_t fourcc;
		enum cam_pixfmt fmt;
	} formats[] = {
		{ V4L2_PIX_FMT_YUYV, CAM_FMT_YUYV },
		{ V4L2_PIX_FMT_MJPEG, CAM_FMT_MJPEG },
	};
	static const unsigned sizes[][2] = {
		{ 320, 240 },
		{ 640, 480 },
		{ 800, 600 },
	};
	unsigned wi, fi, w, h;
	enum v4l2_buf_type type;
	struct v4l2_streamparm parm;
	int fd;

	fd = open(path, O_RDWR | O_NONBLOCK);
	if (fd < 0)
		return false;
	if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
		close(fd);
		return false;
	}
	if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE) ||
	    !(cap.capabilities & V4L2_CAP_STREAMING)) {
		close(fd);
		return false;
	}

	cam->fd = fd;
	snprintf(cam->device, sizeof(cam->device), "%s", path);

	for (fi = 0; fi < sizeof(formats) / sizeof(formats[0]); fi++) {
		unsigned env_w = 0, env_h = 0;
		bool have_env = parse_size_env(&env_w, &env_h);

		for (wi = 0; wi < sizeof(sizes) / sizeof(sizes[0]) + (have_env ? 1u : 0u); wi++) {
			if (have_env && wi == 0) {
				w = env_w;
				h = env_h;
			} else {
				unsigned idx = have_env ? wi - 1 : wi;

				if (idx >= sizeof(sizes) / sizeof(sizes[0]))
					break;
				w = sizes[idx][0];
				h = sizes[idx][1];
			}
			if (!cam_try_fmt(fd, formats[fi].fourcc, &w, &h))
				continue;
			cam->fmt = formats[fi].fmt;
			cam->fourcc = formats[fi].fourcc;
			cam->width = w;
			cam->height = h;

			memset(&parm, 0, sizeof(parm));
			parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			if (xioctl(fd, VIDIOC_G_PARM, &parm) == 0) {
				parm.parm.capture.timeperframe.numerator = 1;
				parm.parm.capture.timeperframe.denominator = 10;
				xioctl(fd, VIDIOC_S_PARM, &parm);
			}

			if (!cam_init_mmap(cam)) {
				cam_unmap(cam);
				continue;
			}
			type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
				cam_unmap(cam);
				continue;
			}
			cam->streaming = true;
			cam->retry_ms = CAM_RETRY_MS;
			cam->decode_fails = 0;
			{
				struct timespec slp = { .tv_sec = 0, .tv_nsec = 150000000L };

				nanosleep(&slp, NULL);
			}
			snprintf(cam->status, sizeof(cam->status), "%s %ux%u %s",
				 path, w, h,
				 cam->fmt == CAM_FMT_MJPEG ? "MJPEG" : "YUYV");
			fprintf(stderr, "info-panel-track: opened %s\n", cam->status);
			return true;
		}
	}

	cam_release(cam);
	return false;
}

static bool cam_find_and_open(struct cam_state *cam)
{
	const char *env = getenv("INFO_PANEL_CAMERA_DEVICE");
	char path[64];
	int i;

	cam_release(cam);

	if (env && *env) {
		if (cam_open_path(cam, env))
			return true;
		snprintf(cam->status, sizeof(cam->status),
			 cam->have_frame ? "reconnecting… (%s)" : "open failed: %s", env);
		return false;
	}

	for (i = 0; i < 16; i++) {
		snprintf(path, sizeof(path), "/dev/video%d", i);
		if (cam_open_path(cam, path))
			return true;
	}
	snprintf(cam->status, sizeof(cam->status),
		 cam->have_frame ? "reconnecting…" : "no UVC capture device");
	return false;
}

static void cam_note_disconnect(struct cam_state *cam, const char *why)
{
	(void)why;
	snprintf(cam->status, sizeof(cam->status),
		 cam->have_frame ? "reconnecting…" : "camera lost");
	cam_release(cam);
	if (cam->retry_ms < CAM_RETRY_MS)
		cam->retry_ms = CAM_RETRY_MS;
	else if (cam->retry_ms < CAM_RETRY_MAX_MS) {
		cam->retry_ms *= 2;
		if (cam->retry_ms > CAM_RETRY_MAX_MS)
			cam->retry_ms = CAM_RETRY_MAX_MS;
	}
	cam->next_retry_ms = monotonic_ms() + cam->retry_ms;
}

static void cam_grab(struct cam_state *cam, struct track_state_data *tr)
{
	struct v4l2_buffer buf;
	struct v4l2_buffer latest;
	bool have_latest = false;

	if (cam->fd < 0 || !cam->streaming)
		return;

	for (;;) {
		memset(&buf, 0, sizeof(buf));
		buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		buf.memory = V4L2_MEMORY_MMAP;
		if (xioctl(cam->fd, VIDIOC_DQBUF, &buf) < 0) {
			if (errno == EAGAIN)
				break;
			cam_note_disconnect(cam, strerror(errno));
			return;
		}
		if (buf.index >= cam->nbufs) {
			xioctl(cam->fd, VIDIOC_QBUF, &buf);
			continue;
		}
		if (have_latest) {
			if (xioctl(cam->fd, VIDIOC_QBUF, &latest) < 0) {
				cam_note_disconnect(cam, strerror(errno));
				return;
			}
		}
		latest = buf;
		have_latest = true;
	}

	if (!have_latest)
		return;

	{
		const uint8_t *p = cam->bufs[latest.index].start;
		size_t len = latest.bytesused;
		bool ok = false;

		if (cam->fmt == CAM_FMT_MJPEG)
			ok = decode_mjpeg(cam, p, len);
		else if (cam->fmt == CAM_FMT_YUYV)
			ok = decode_yuyv(cam, p, len);
		if (ok) {
			cam->decode_fails = 0;
			track_on_frame(tr, cam);
			snprintf(cam->status, sizeof(cam->status), "%s %ux%u %s",
				 cam->device, cam->width, cam->height,
				 cam->fmt == CAM_FMT_MJPEG ? "MJPEG" : "YUYV");
		} else {
			cam->decode_fails++;
			if (cam->decode_fails >= DECODE_FAIL_REOPEN) {
				cam_note_disconnect(cam, "decode stall");
				return;
			}
		}
	}

	if (xioctl(cam->fd, VIDIOC_QBUF, &latest) < 0)
		cam_note_disconnect(cam, strerror(errno));
}

/* ---- draw --------------------------------------------------------------- */

struct letterbox {
	int x0, y0, vw, vh;
};

static void letterbox_geom(unsigned sw, unsigned sh, int dw, int dh, int top_pad,
			   struct letterbox *lb)
{
	int view_h = dh - top_pad;

	lb->x0 = lb->y0 = 0;
	lb->vw = lb->vh = 0;
	if (view_h < 1 || sw < 1 || sh < 1)
		return;

	if ((int64_t)sw * view_h > (int64_t)sh * dw) {
		lb->vw = dw;
		lb->vh = (int)((int64_t)sh * dw / sw);
	} else {
		lb->vh = view_h;
		lb->vw = (int)((int64_t)sw * view_h / sh);
	}
	if (lb->vw < 1)
		lb->vw = 1;
	if (lb->vh < 1)
		lb->vh = 1;
	lb->x0 = (dw - lb->vw) / 2;
	lb->y0 = top_pad + (view_h - lb->vh) / 2;
}

static void blit_rgb_letterbox(const uint8_t *rgb, unsigned sw, unsigned sh,
			       uint32_t *dst, int dw, int dh, int top_pad,
			       struct letterbox *out_lb)
{
	struct letterbox lb;
	int y, x;

	letterbox_geom(sw, sh, dw, dh, top_pad, &lb);
	if (out_lb)
		*out_lb = lb;
	if (lb.vw < 1 || lb.vh < 1)
		return;

	for (y = 0; y < lb.vh; y++) {
		unsigned sy = (unsigned)((int64_t)y * sh / lb.vh);
		const uint8_t *row = rgb + (size_t)sy * sw * 3u;
		uint32_t *out = dst + (size_t)(lb.y0 + y) * (size_t)dw + (size_t)lb.x0;

		for (x = 0; x < lb.vw; x++) {
			unsigned sx = (unsigned)((int64_t)x * sw / lb.vw);
			const uint8_t *p = row + (size_t)sx * 3u;

			out[x] = 0xff000000u |
				 ((uint32_t)p[0] << 16) |
				 ((uint32_t)p[1] << 8) |
				 (uint32_t)p[2];
		}
	}
}

static void draw_panel(struct app *app, struct shm_buffer *b)
{
	cairo_surface_t *cs = cairo_image_surface_create_for_data(
		b->data, CAIRO_FORMAT_ARGB32, b->width, b->height, b->width * 4);
	cairo_t *cr = cairo_create(cs);
	const double w = b->width;
	const double h = b->height;
	char line[192];
	struct letterbox lb = { 0 };

	cairo_set_source_rgb(cr, 0.02, 0.02, 0.04);
	cairo_paint(cr);

	if (app->cam.have_frame && app->cam.rgb)
		blit_rgb_letterbox(app->cam.rgb, app->cam.rgb_w, app->cam.rgb_h,
				   (uint32_t *)b->data, b->width, b->height, STATUS_H,
				   &lb);

	/* Track bbox only with a real target (LOCK / short COAST). */
	if (app->track.have_target && lb.vw > 0 && lb.vh > 0 &&
	    app->cam.rgb_w > 0 && app->cam.rgb_h > 0 &&
	    (app->track.state == TRACK_LOCK || app->track.state == TRACK_COAST ||
	     app->track.state == TRACK_ACQUIRE)) {
		double sx = (double)lb.vw / (double)app->cam.rgb_w;
		double sy = (double)lb.vh / (double)app->cam.rgb_h;
		float hw = app->track.half_w > 4.f ? app->track.half_w : 4.f;
		float hh = app->track.half_h > 4.f ? app->track.half_h : 4.f;
		double rx = lb.x0 + (app->track.x - hw) * sx;
		double ry = lb.y0 + (app->track.y - hh) * sy;
		double rw = (2.0 * hw) * sx;
		double rh = (2.0 * hh) * sy;

		if (app->track.state == TRACK_LOCK)
			cairo_set_source_rgb(cr, 1.0, 0.92, 0.1);
		else if (app->track.state == TRACK_ACQUIRE)
			cairo_set_source_rgb(cr, 0.85, 0.85, 0.90);
		else
			cairo_set_source_rgb(cr, 0.70, 0.65, 0.20);
		cairo_set_line_width(cr, 3.0);
		cairo_rectangle(cr, rx, ry, rw, rh);
		cairo_stroke(cr);
	}

	cairo_set_source_rgba(cr, 0.04, 0.07, 0.12, 0.92);
	cairo_rectangle(cr, 0, 0, w, STATUS_H);
	cairo_fill(cr);

	cairo_set_source_rgb(cr, 0.20, 0.75, 0.45);
	cairo_rectangle(cr, 0, 0, w, 3);
	cairo_fill(cr);

	cairo_select_font_face(cr, "Liberation Sans", CAIRO_FONT_SLANT_NORMAL,
			       CAIRO_FONT_WEIGHT_BOLD);
	cairo_set_font_size(cr, 16);
	cairo_set_source_rgb(cr, 0.85, 0.90, 0.95);
	snprintf(line, sizeof(line), "Track  ·  %s  ·  %s%s",
		 app->cam.status,
		 track_state_name(app->track.state),
		 app->servo.ready ? "  ·  servo" : "");
	cairo_move_to(cr, 14, 24);
	cairo_show_text(cr, line);

	if (!app->cam.have_frame) {
		cairo_set_font_size(cr, 28);
		cairo_set_source_rgb(cr, 0.55, 0.60, 0.70);
		cairo_text_extents_t ext;
		const char *msg = "Waiting for camera…";

		cairo_text_extents(cr, msg, &ext);
		cairo_move_to(cr, (w - ext.width) / 2.0, h * 0.5);
		cairo_show_text(cr, msg);
	}

	cairo_destroy(cr);
	cairo_surface_destroy(cs);
}

static struct shm_buffer *pick_buffer(struct app *app)
{
	for (int i = 0; i < 2; i++) {
		struct shm_buffer *b = &app->buffers[app->buffer_idx];

		app->buffer_idx = (app->buffer_idx + 1) % 2;
		if (!b->busy)
			return b;
	}
	return NULL;
}

static bool render(struct app *app)
{
	int width = app->output_width > 0 ? app->output_width : 1280;
	int height = app->output_height > 0 ? app->output_height : 720;

	for (int i = 0; i < 2; i++) {
		if (app->buffers[i].wl_buffer &&
		    (app->buffers[i].width != width || app->buffers[i].height != height))
			shm_buffer_destroy(&app->buffers[i]);
		if (!app->buffers[i].wl_buffer) {
			if (shm_buffer_init(app, &app->buffers[i], width, height) < 0) {
				fprintf(stderr, "shm buffer init failed\n");
				app->running = false;
				return false;
			}
		}
	}

	struct shm_buffer *b = pick_buffer(app);
	if (!b)
		return false;

	draw_panel(app, b);
	b->busy = true;
	wl_surface_set_buffer_scale(app->surface, app->scale > 0 ? app->scale : 1);
	wl_surface_attach(app->surface, b->wl_buffer, 0, 0);
	wl_surface_damage_buffer(app->surface, 0, 0, width, height);
	wl_surface_commit(app->surface);
	app->last_committed = (int)(b - app->buffers);
	app->have_committed = true;
	return true;
}

/* ---- Wayland ------------------------------------------------------------ */

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm, uint32_t serial)
{
	(void)data;
	xdg_wm_base_pong(wm, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
	.ping = xdg_wm_base_ping,
};

static void xdg_surface_configure(void *data, struct xdg_surface *xdg_surface, uint32_t serial)
{
	struct app *app = data;

	xdg_surface_ack_configure(xdg_surface, serial);
	app->configured = true;
	render(app);
}

static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *toplevel,
				   int32_t width, int32_t height, struct wl_array *states)
{
	struct app *app = data;

	(void)toplevel;
	(void)states;
	if (width > 0)
		app->output_width = width;
	if (height > 0)
		app->output_height = height;
}

static void xdg_toplevel_close(void *data, struct xdg_toplevel *toplevel)
{
	struct app *app = data;

	(void)toplevel;
	app->running = false;
}

static const struct xdg_toplevel_listener xdg_toplevel_listener = {
	.configure = xdg_toplevel_configure,
	.close = xdg_toplevel_close,
};

static void output_geometry(void *data, struct wl_output *output,
			    int32_t x, int32_t y, int32_t pw, int32_t ph,
			    int32_t subpixel, const char *make, const char *model,
			    int32_t transform)
{
	(void)data;
	(void)output;
	(void)x;
	(void)y;
	(void)pw;
	(void)ph;
	(void)subpixel;
	(void)make;
	(void)model;
	(void)transform;
}

static void output_mode(void *data, struct wl_output *output, uint32_t flags,
			int32_t width, int32_t height, int32_t refresh)
{
	struct app *app = data;

	(void)output;
	(void)refresh;
	if (flags & WL_OUTPUT_MODE_CURRENT) {
		app->output_width = width;
		app->output_height = height;
	}
}

static void output_done(void *data, struct wl_output *output)
{
	(void)data;
	(void)output;
}

static void output_scale(void *data, struct wl_output *output, int32_t factor)
{
	struct app *app = data;

	(void)output;
	app->scale = factor;
}

static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
};

static void registry_global(void *data, struct wl_registry *registry,
			    uint32_t name, const char *interface, uint32_t version)
{
	struct app *app = data;

	(void)version;
	if (strcmp(interface, "wl_compositor") == 0) {
		app->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
	} else if (strcmp(interface, "wl_shm") == 0) {
		app->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, "xdg_wm_base") == 0) {
		app->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
		xdg_wm_base_add_listener(app->wm_base, &wm_base_listener, app);
	} else if (strcmp(interface, "wl_output") == 0 && !app->output) {
		app->output = wl_registry_bind(registry, name, &wl_output_interface, 2);
		wl_output_add_listener(app->output, &output_listener, app);
	}
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

int main(int argc, char **argv)
{
	struct app app = { 0 };
	struct pollfd pfds[2];
	uint64_t last_frame_ms = 0;
	struct sigaction sa;

	(void)argc;
	(void)argv;

	app.running = true;
	app.scale = 1;
	app.output_width = 1280;
	app.output_height = 720;
	app.cam.fd = -1;
	app.cam.retry_ms = CAM_RETRY_MS;
	track_reset(&app.track);
	snprintf(app.cam.status, sizeof(app.cam.status), "starting");

	app.display = wl_display_connect(NULL);
	if (!app.display) {
		fprintf(stderr, "failed to connect to Wayland display\n");
		return 1;
	}

	app.registry = wl_display_get_registry(app.display);
	wl_registry_add_listener(app.registry, &registry_listener, &app);
	wl_display_roundtrip(app.display);
	wl_display_roundtrip(app.display);

	if (!app.compositor || !app.shm || !app.wm_base) {
		fprintf(stderr, "missing compositor/shm/xdg_wm_base\n");
		return 1;
	}

	app.surface = wl_compositor_create_surface(app.compositor);
	app.xdg_surface = xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
	xdg_surface_add_listener(app.xdg_surface, &xdg_surface_listener, &app);
	app.xdg_toplevel = xdg_surface_get_toplevel(app.xdg_surface);
	xdg_toplevel_add_listener(app.xdg_toplevel, &xdg_toplevel_listener, &app);
	xdg_toplevel_set_title(app.xdg_toplevel, "Track Panel");
	xdg_toplevel_set_app_id(app.xdg_toplevel, "info-panel-track");
	xdg_toplevel_set_fullscreen(app.xdg_toplevel, app.output);
	wl_surface_commit(app.surface);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_sigusr1;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGUSR1, &sa, NULL);

	cam_find_and_open(&app.cam);
	app.cam.next_retry_ms = monotonic_ms() + CAM_RETRY_MS;
	servo_init(&app.servo);

	while (app.running) {
		uint64_t now_ms;
		int npoll = 0;
		int timeout;
		int ret;
		bool had_frame;
		bool grab_due;

		while (wl_display_prepare_read(app.display) != 0)
			wl_display_dispatch_pending(app.display);
		wl_display_flush(app.display);

		now_ms = monotonic_ms();
		pfds[npoll].fd = wl_display_get_fd(app.display);
		pfds[npoll].events = POLLIN;
		npoll++;
		if (app.cam.fd >= 0) {
			pfds[npoll].fd = app.cam.fd;
			pfds[npoll].events = POLLIN;
			npoll++;
		}

		if (!app.configured)
			timeout = 20;
		else if (now_ms >= last_frame_ms + FRAME_MS)
			timeout = POLL_MIN_MS;
		else
			timeout = (int)(last_frame_ms + FRAME_MS - now_ms);

		if (timeout < POLL_MIN_MS)
			timeout = POLL_MIN_MS;

		ret = poll(pfds, (nfds_t)npoll, timeout);
		if (ret < 0 && errno != EINTR) {
			wl_display_cancel_read(app.display);
			break;
		}
		if (ret > 0 && (pfds[0].revents & POLLIN))
			wl_display_read_events(app.display);
		else
			wl_display_cancel_read(app.display);

		wl_display_dispatch_pending(app.display);

		had_frame = app.cam.have_frame;
		now_ms = monotonic_ms();
		grab_due = app.configured && (now_ms - last_frame_ms) >= FRAME_MS;

		if (app.cam.fd >= 0 && grab_due) {
			cam_grab(&app.cam, &app.track);
			servo_follow_track(&app.servo, &app.cam, &app.track);
		} else if (app.cam.fd < 0 && now_ms >= app.cam.next_retry_ms) {
			bool ok = cam_find_and_open(&app.cam);

			app.cam.next_retry_ms = monotonic_ms() +
				(ok ? CAM_RETRY_MS : (app.cam.retry_ms ? app.cam.retry_ms : CAM_RETRY_MS));
			if (!ok && app.cam.retry_ms < CAM_RETRY_MAX_MS) {
				app.cam.retry_ms = app.cam.retry_ms ? app.cam.retry_ms * 2 : CAM_RETRY_MS;
				if (app.cam.retry_ms > CAM_RETRY_MAX_MS)
					app.cam.retry_ms = CAM_RETRY_MAX_MS;
			}
			app.frame_dirty = true;
		}

		if (app.cam.have_frame && !had_frame)
			app.frame_dirty = true;
		if (app.cam.have_frame && app.cam.fd >= 0 && grab_due)
			app.frame_dirty = true;
		else if (app.cam.fd < 0)
			app.frame_dirty = true;

		now_ms = monotonic_ms();
		if (app.configured &&
		    (app.frame_dirty || now_ms - last_frame_ms >= 1000) &&
		    now_ms - last_frame_ms >= FRAME_MS) {
			if (render(&app)) {
				last_frame_ms = now_ms;
				app.frame_dirty = false;
			}
		}

		if (screenshot_requested)
			dump_screenshot(&app);

		{
			struct timespec slp = {
				.tv_sec = 0,
				.tv_nsec = (long)POLL_MIN_MS * 1000000L,
			};

			nanosleep(&slp, NULL);
		}
	}

	servo_close(&app.servo);
	cam_close(&app.cam);
	for (int i = 0; i < 2; i++)
		shm_buffer_destroy(&app.buffers[i]);
	if (app.xdg_toplevel)
		xdg_toplevel_destroy(app.xdg_toplevel);
	if (app.xdg_surface)
		xdg_surface_destroy(app.xdg_surface);
	if (app.surface)
		wl_surface_destroy(app.surface);
	if (app.output)
		wl_output_destroy(app.output);
	if (app.wm_base)
		xdg_wm_base_destroy(app.wm_base);
	if (app.shm)
		wl_shm_destroy(app.shm);
	if (app.compositor)
		wl_compositor_destroy(app.compositor);
	if (app.registry)
		wl_registry_destroy(app.registry);
	wl_display_disconnect(app.display);
	return 0;
}
