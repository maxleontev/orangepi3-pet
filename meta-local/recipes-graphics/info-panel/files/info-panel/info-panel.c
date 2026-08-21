/*
 * Fullscreen Wayland info panel: CPU temp/usage, memory, uptime, STA IP/SSID,
 * setup-AP SSID/IP when hostapd mode is active, and a live mic spectrum.
 * Composited by Weston on DRM/KMS; GPU path is Mesa Lima (Mali).
 *
 * ---------------------------------------------------------------------------
 * Microphone capture + spectrum (Orange Pi 3 / AC200)
 * ---------------------------------------------------------------------------
 *
 * Hardware path
 *   Onboard analog MIC1 -> X-Powers AC200 codec -> H6 I2S3 -> ALSA card
 *   "ac200audio". Mixer routing is NOT done here: package ac200-audio
 *   (recipes-multimedia/ac200-audio) runs ac200-mic-setup.service at boot.
 *
 * This process
 *   1. Opens hw:CARD=ac200audio,DEV=0 as non-blocking capture (S16_LE,
 *      stereo, 48 kHz, period 128). Override with INFO_PANEL_ALSA_DEVICE.
 *   2. Polls Wayland + ALSA together with a real timeout (next 5 Hz frame
 *      or 1 Hz stats, at least 10 ms) and drains every available PCM period.
 *   3. Takes the first interleaved channel into a rolling Hann window of
 *      2048 samples (hop 128). FFT runs only when a display frame is due,
 *      then bins are mapped onto log 40 Hz..10 kHz X and 20*log10(raw
 *      |X[k]|) on Y (−48..+24 dB). Bin width ≈ 23.4 Hz so 40–100 Hz is
 *      no longer a single shared bin (512 was ≈ 93.8 Hz).
 *   4. Redraws only the bottom ~44% of the SHM buffer for spectrum frames
 *      at ~5 Hz; full-frame stats redraw once per second. Never attach a
 *      wl_shm buffer the compositor has not released.
 *
 * Problems found on this board and how they are handled
 *
 *   Mixer defaults were wrong (quiet or rail-clipped capture)
 *     ADC Volume reset to ~3/7; `amixer sset ADC 100%` touched playback, not
 *     capture gain; `sset "I2S ADC"` was ambiguous. MIC1 Playback Switch had
 *     to be off; capture is MIC1 Capture + I2S ADC Capture. Master 85% +
 *     MIC1 Boost 4 clipped at ±32768. Fix: boot script uses cset with full
 *     names, ADC Volume=7, Master cap 62%, Boost 4.
 *
 *   weston could not open /dev/snd
 *     PCM nodes are root:audio. info-panel.service adds SupplementaryGroups=
 *     audio so the weston user can capture.
 *
 *   Spectrum looked like a waterfall (time on X)
 *     First UI was a scrolling spectrogram. Requirement is a live analyser:
 *     X = frequency (log 40..10000 Hz), Y = dB, both axes labelled.
 *
 *   "dB" overlapped the tick numbers
 *     Rotated Y-axis title sat on top of −72/−60/…. Fix: wider left margin,
 *     ticks right-aligned before the plot, "dB" in the top-left of the plot.
 *
 *   Trace did not move / felt seconds late
 *     (1) Both wl_shm buffers stayed busy; render() skipped the frame but
 *         still cleared spectro.dirty, so the display froze.
 *     (2) 33 ms cap + exponential smoothing hid transients.
 *     (3) poll() waited on Wayland only, so ALSA data sat until the next
 *         timeout; each frame also redrew the whole stats pane.
 *     Fix: never drop dirty until a successful commit; poll ALSA fds;
 *     hop 128; drain the PCM; damage only the spectrum region; no smoothing.
 *     Do not force-attach a busy buffer or poll with timeout 0 (see below).
 *
 *   Voice pinned the trace to the ceiling, then a "correct" FFT scale
 *   made only the axes visible
 *     Raw |X[k]| of ~0.5 already hit SPEC_MAX_DB=-6, so speech filled the
 *     plot. Dividing by N*Hann gain put the same speech below −72 dB, so the
 *     line sat on the X axis. Fix: plot 20*log10(raw bin mag) on −48..+24 dB
 *     (voice in the middle, no full-scale peg, not glued to the floor).
 *     Fill/stroke use opaque SOURCE (Wayland SHM is premultiplied; 0.22 alpha
 *     fills were effectively invisible).
 *
 *   Stats pane updated about once a minute
 *     Spectrum frames used force=true; the 1 Hz stats path used force=false
 *     and lost every attempt while both buffers were busy. Metrics changed
 *     in memory but the top of the screen did not. With spectrum capped at
 *     5 Hz the compositor releases a buffer in time, so 1 Hz stats can
 *     wait instead of stealing a busy buffer.
 *
 *   Board hard-reset every ~4–5 minutes after the live spectrum landed
 *     poll(..., 0) plus force-pick of busy wl_shm buffers committed Cairo
 *     frames hundreds of times per second. HDMI showed one core at 99%,
 *     weston stayed Runnable, temperature was only ~52 °C, memory was
 *     fine, and dmesg had no oops (panic=10 would have logged one). The
 *     SoC then reset (unclean FAT on /boot). Fix: 5 Hz cap, poll never
 *     shorter than 10 ms, ignore ALSA POLLOUT (it kept poll() from sleeping),
 *     FFT only on display ticks, vertical bar analyzer (no continuous curve), axes
 *     only on the 1 Hz full frame, never attach a buffer still held by Weston.
 */

#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <cairo/cairo.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <math.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define MAX_CPU_CORES 8
/* Match AC200 I2S3 simple-audio-card; period 128 keeps capture latency low. */
#define MIC_RATE 48000
#define MIC_CHANNELS 2
#define MIC_PERIOD 128
#define MIC_RETRY_MS 2000
#define INFO_SPLIT 0.56

/* 2048 @ 48 kHz → ≈23.4 Hz/bin (512 was ≈93.8 Hz and collapsed all <100 Hz). */
#define FFT_N 2048
/* Hop 128 (~2.7 ms) is one ALSA period; FFT itself runs at SPEC_FRAME_MS. */
#define FFT_HOP 128
#define FFT_BINS (FFT_N / 2)
#define SPEC_POINTS 256
/* Vertical bar analyzer: fewer bars than FFT samples so gaps stay visible. */
#define SPEC_BARS 56
#define SPEC_MIN_HZ 40.0f
#define SPEC_MAX_HZ 10000.0f
/* See file header: −6 dB ceiling pegged speech; /N hid the trace on the axis. */
#define SPEC_MIN_DB -48.0f
#define SPEC_MAX_DB 24.0f
/* Display cap. Timeout 0 + per-hop commits reset the H6 every few minutes. */
#define SPEC_FRAME_MS 200
#define POLL_MIN_MS 10
#define MAX_POLL_FDS 8

struct panel_metrics {
	double cpu_c;
	bool cpu_ok;
	int ncpus;
	double core_pct[MAX_CPU_CORES];
	bool cores_ok;
	unsigned long mem_total_kb;
	unsigned long mem_avail_kb;
	char uptime[32];
	char ip[INET_ADDRSTRLEN];
	char iface[32];
	char wifi_ssid[33]; /* IEEE 802.11 SSID max 32 octets */
	char ap_ssid[33];
	char ap_ip[INET_ADDRSTRLEN];
	char hostname[64];
};

struct shm_buffer {
	struct wl_buffer *wl_buffer;
	void *data;
	size_t size;
	int width;
	int height;
	bool busy;
	/* Partial spectrum redraws must not wipe a buffer that never had stats. */
	bool stats_valid;
};

struct mic_state {
	snd_pcm_t *pcm;
	unsigned channels;
	bool ok;
	char status[64];
	uint64_t next_retry_ms;
};

struct spectro_state {
	int16_t hop[FFT_N];
	int16_t latest[FFT_N];
	unsigned hop_fill;
	float window[FFT_N];
	float fft_re[FFT_N];
	float fft_im[FFT_N];
	float db[SPEC_POINTS];
	float peak_db;
	bool have_spectrum;
	bool window_ready;
	bool dirty;
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
	struct panel_metrics metrics;
	struct mic_state mic;
	struct spectro_state spectro;
};

static int create_shm_file(size_t size)
{
	char template[] = "/tmp/info-panel-XXXXXX";
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

static double read_temp_milli_file(const char *path)
{
	FILE *f = fopen(path, "r");
	long milli = 0;

	if (!f)
		return -1.0;
	if (fscanf(f, "%ld", &milli) != 1) {
		fclose(f);
		return -1.0;
	}
	fclose(f);
	/* Sysfs thermal/hwmon use millidegrees C. */
	if (milli > 1000)
		return milli / 1000.0;
	return (double)milli;
}

static double read_cpu_temp_c(void)
{
	char path[256];
	char type[128];
	FILE *f;
	int best = -1;
	double t;
	DIR *d;
	struct dirent *de;

	/* Prefer a CPU-named thermal zone; else first readable zone. */
	for (int i = 0; i < 16; i++) {
		snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/type", i);
		f = fopen(path, "r");
		if (!f)
			break;
		if (!fgets(type, sizeof(type), f)) {
			fclose(f);
			continue;
		}
		fclose(f);
		if (strcasestr(type, "cpu") || strcasestr(type, "soc") ||
		    strcasestr(type, "ths") || best < 0)
			best = i;
		if (strcasestr(type, "cpu"))
			break;
	}

	if (best >= 0) {
		snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", best);
		t = read_temp_milli_file(path);
		if (t >= 0.0)
			return t;
	}

	/* Fallback: any thermal_zoneN/temp */
	for (int i = 0; i < 16; i++) {
		snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", i);
		t = read_temp_milli_file(path);
		if (t >= 0.0)
			return t;
	}

	/* Fallback: hwmon temp*_input (after THS binds it often appears there too). */
	d = opendir("/sys/class/hwmon");
	if (!d)
		return -1.0;
	while ((de = readdir(d)) != NULL) {
		if (strncmp(de->d_name, "hwmon", 5) != 0)
			continue;
		for (int i = 1; i <= 8; i++) {
			snprintf(path, sizeof(path), "/sys/class/hwmon/%s/temp%d_input",
				 de->d_name, i);
			t = read_temp_milli_file(path);
			if (t >= 0.0) {
				closedir(d);
				return t;
			}
		}
	}
	closedir(d);
	return -1.0;
}

/* Per-core busy % from /proc/stat deltas (needs two samples). */
static void read_cpu_core_usage(struct panel_metrics *m)
{
	static unsigned long long prev_idle[MAX_CPU_CORES];
	static unsigned long long prev_total[MAX_CPU_CORES];
	static int prev_n;
	static bool have_prev;
	FILE *f;
	char line[256];
	int n = 0;

	m->ncpus = 0;
	m->cores_ok = false;

	f = fopen("/proc/stat", "r");
	if (!f)
		return;

	while (fgets(line, sizeof(line), f) && n < MAX_CPU_CORES) {
		unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;
		unsigned long long idle_all, total, didle, dtotal;
		int idx;

		if (sscanf(line, "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu",
			   &idx, &user, &nice, &system, &idle, &iowait, &irq, &softirq, &steal) < 9)
			continue;
		if (idx != n)
			continue;

		idle_all = idle + iowait;
		total = user + nice + system + idle_all + irq + softirq + steal;
		m->core_pct[n] = 0.0;

		if (have_prev && n < prev_n && total > prev_total[n]) {
			didle = idle_all - prev_idle[n];
			dtotal = total - prev_total[n];
			if (dtotal > 0) {
				double busy = 100.0 * (1.0 - (double)didle / (double)dtotal);
				if (busy < 0.0)
					busy = 0.0;
				if (busy > 100.0)
					busy = 100.0;
				m->core_pct[n] = busy;
			}
		}

		prev_idle[n] = idle_all;
		prev_total[n] = total;
		n++;
	}
	fclose(f);

	if (n > 0) {
		m->ncpus = n;
		prev_n = n;
		m->cores_ok = have_prev;
		have_prev = true;
	}
}

static void read_meminfo(unsigned long *total_kb, unsigned long *avail_kb)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char key[64];
	unsigned long val;
	char unit[32];

	*total_kb = 0;
	*avail_kb = 0;
	if (!f)
		return;

	while (fscanf(f, "%63s %lu %31s", key, &val, unit) == 3) {
		if (strcmp(key, "MemTotal:") == 0)
			*total_kb = val;
		else if (strcmp(key, "MemAvailable:") == 0)
			*avail_kb = val;
	}
	fclose(f);
}

static void read_primary_ipv4(char *ip, size_t iplen, char *iface, size_t iflen)
{
	struct ifaddrs *ifaddr = NULL, *ifa;
	const char *prefer[] = { "wlan0", "eth0", "end0", "enp1s0", NULL };

	snprintf(ip, iplen, "-");
	snprintf(iface, iflen, "-");

	if (getifaddrs(&ifaddr) != 0)
		return;

	for (int p = 0; prefer[p]; p++) {
		for (ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
			if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
				continue;
			if (strcmp(ifa->ifa_name, prefer[p]) != 0)
				continue;
			struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
			inet_ntop(AF_INET, &sin->sin_addr, ip, iplen);
			snprintf(iface, iflen, "%s", ifa->ifa_name);
			freeifaddrs(ifaddr);
			return;
		}
	}

	for (ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
		if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
			continue;
		if (strncmp(ifa->ifa_name, "lo", 2) == 0)
			continue;
		struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
		inet_ntop(AF_INET, &sin->sin_addr, ip, iplen);
		snprintf(iface, iflen, "%s", ifa->ifa_name);
		break;
	}
	freeifaddrs(ifaddr);
}

/* Prefer iw (works as weston user); wpa_cli ctrl iface is often root-only.
 * Use absolute path — weston's systemd PATH may omit /usr/sbin.
 */
static void read_wifi_ssid(char *ssid, size_t len)
{
	static const char *const cmds[] = {
		"/usr/sbin/iw dev wlan0 link 2>/dev/null",
		"/sbin/iw dev wlan0 link 2>/dev/null",
		"iw dev wlan0 link 2>/dev/null",
		NULL,
	};
	FILE *f = NULL;
	char line[256];
	int i;

	snprintf(ssid, len, "-");
	for (i = 0; cmds[i]; i++) {
		f = popen(cmds[i], "r");
		if (f)
			break;
	}
	if (!f)
		return;

	while (fgets(line, sizeof(line), f)) {
		char *p = line;
		while (*p == ' ' || *p == '\t')
			p++;
		if (strncmp(p, "SSID:", 5) != 0)
			continue;
		p += 5;
		while (*p == ' ' || *p == '\t')
			p++;
		size_t n = strcspn(p, "\r\n");
		if (n == 0)
			break;
		if (n >= len)
			n = len - 1;
		memcpy(ssid, p, n);
		ssid[n] = '\0';
		break;
	}
	pclose(f);
}

static void read_uptime(char *buf, size_t len)
{
	double up = 0.0;
	unsigned long sec, days, hours, mins, rem;
	FILE *f;

	snprintf(buf, len, "-");
	f = fopen("/proc/uptime", "r");
	if (!f)
		return;
	if (fscanf(f, "%lf", &up) != 1) {
		fclose(f);
		return;
	}
	fclose(f);

	sec = (unsigned long)up;
	days = sec / 86400UL;
	rem = sec % 86400UL;
	hours = rem / 3600UL;
	rem %= 3600UL;
	mins = rem / 60UL;
	rem %= 60UL;

	if (days > 0)
		snprintf(buf, len, "%lud %02lu:%02lu:%02lu", days, hours, mins, rem);
	else
		snprintf(buf, len, "%02lu:%02lu:%02lu", hours, mins, rem);
}

/* Setup AP (hostapd): /run/wifi-mode=ap. Prefer runtime files; iw only as fallback. */
static void read_ap_info(char *ssid, size_t ssid_len, char *ip, size_t iplen)
{
	static const char *const cmds[] = {
		"/usr/sbin/iw dev wlan0 info 2>/dev/null",
		"/sbin/iw dev wlan0 info 2>/dev/null",
		"iw dev wlan0 info 2>/dev/null",
		NULL,
	};
	char mode[16];
	char line[256];
	FILE *f;
	int i;
	size_t mi;
	bool is_ap = false;
	bool have_ssid = false;

	snprintf(ssid, ssid_len, "-");
	snprintf(ip, iplen, "-");

	f = fopen("/run/wifi-mode", "r");
	if (!f)
		return;
	if (!fgets(mode, sizeof(mode), f)) {
		fclose(f);
		return;
	}
	fclose(f);
	for (mi = 0; mode[mi]; mi++) {
		if (mode[mi] == '\r' || mode[mi] == '\n') {
			mode[mi] = '\0';
			break;
		}
	}
	if (strcmp(mode, "ap") != 0)
		return;

	/* Fast path: files written by wifi-ap-start (no iw). */
	f = fopen("/run/wifi-setup-ap-ssid", "r");
	if (f) {
		if (fgets(line, sizeof(line), f)) {
			size_t n = strcspn(line, "\r\n");
			if (n > 0) {
				if (n >= ssid_len)
					n = ssid_len - 1;
				memcpy(ssid, line, n);
				ssid[n] = '\0';
				have_ssid = true;
			}
		}
		fclose(f);
	}
	f = fopen("/run/wifi-setup-ap-ip", "r");
	if (f) {
		if (fgets(line, sizeof(line), f)) {
			size_t n = strcspn(line, "\r\n");
			if (n > 0 && n < iplen) {
				memcpy(ip, line, n);
				ip[n] = '\0';
			}
		}
		fclose(f);
	}
	if (have_ssid && strcmp(ip, "-") != 0)
		return;

	for (i = 0; cmds[i]; i++) {
		f = popen(cmds[i], "r");
		if (f)
			break;
	}
	if (f) {
		while (fgets(line, sizeof(line), f)) {
			char *p = line;
			while (*p == ' ' || *p == '\t')
				p++;
			if (strncmp(p, "type AP", 7) == 0)
				is_ap = true;
			if (!have_ssid && strncmp(p, "ssid ", 5) == 0) {
				p += 5;
				while (*p == ' ' || *p == '\t')
					p++;
				size_t n = strcspn(p, "\r\n");
				if (n > 0) {
					if (n >= ssid_len)
						n = ssid_len - 1;
					memcpy(ssid, p, n);
					ssid[n] = '\0';
					have_ssid = true;
				}
			}
		}
		pclose(f);
	}

	if (!is_ap && !have_ssid) {
		snprintf(ssid, ssid_len, "-");
		snprintf(ip, iplen, "-");
		return;
	}

	if (strcmp(ip, "-") == 0) {
		char iface[32];
		read_primary_ipv4(ip, iplen, iface, sizeof(iface));
		if (strcmp(iface, "wlan0") != 0)
			snprintf(ip, iplen, "-");
	}
}

static void metrics_refresh(struct panel_metrics *m)
{
	m->cpu_c = read_cpu_temp_c();
	m->cpu_ok = m->cpu_c >= 0.0;
	read_cpu_core_usage(m);
	read_meminfo(&m->mem_total_kb, &m->mem_avail_kb);
	read_uptime(m->uptime, sizeof(m->uptime));
	read_primary_ipv4(m->ip, sizeof(m->ip), m->iface, sizeof(m->iface));
	read_wifi_ssid(m->wifi_ssid, sizeof(m->wifi_ssid));
	read_ap_info(m->ap_ssid, sizeof(m->ap_ssid), m->ap_ip, sizeof(m->ap_ip));
	if (gethostname(m->hostname, sizeof(m->hostname)) != 0)
		snprintf(m->hostname, sizeof(m->hostname), "orangepi3");
	m->hostname[sizeof(m->hostname) - 1] = '\0';
}

static uint64_t monotonic_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void spectro_init(struct spectro_state *sp)
{
	for (int i = 0; i < FFT_N; i++)
		sp->window[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * (float)i / (float)(FFT_N - 1)));
}

static void fft_inplace(float *re, float *im, int n)
{
	int i, j, k, m;
	float t_re, t_im, ang;

	for (j = 1, i = 1; i < n; i++) {
		if (i < j) {
			t_re = re[i];
			t_im = im[i];
			re[i] = re[j];
			im[i] = im[j];
			re[j] = t_re;
			im[j] = t_im;
		}
		m = n >> 1;
		while (m >= 1 && j > m) {
			j -= m;
			m >>= 1;
		}
		j += m;
	}

	for (m = 2; m <= n; m <<= 1) {
		ang = -2.0f * (float)M_PI / (float)m;
		for (j = 0; j < m / 2; j++) {
			float w_re = cosf(ang * (float)j);
			float w_im = sinf(ang * (float)j);
			for (i = j; i < n; i += m) {
				k = i + m / 2;
				t_re = re[k] * w_re - im[k] * w_im;
				t_im = re[k] * w_im + im[k] * w_re;
				re[k] = re[i] - t_re;
				im[k] = im[i] - t_im;
				re[i] += t_re;
				im[i] += t_im;
			}
		}
	}
}

static float mag_to_db(float mag)
{
	float db;

	if (mag <= 1e-9f)
		return SPEC_MIN_DB;
	db = 20.0f * log10f(mag);
	if (db < SPEC_MIN_DB)
		db = SPEC_MIN_DB;
	if (db > SPEC_MAX_DB)
		db = SPEC_MAX_DB;
	return db;
}

static float freq_at_point(int p)
{
	double lo = log10((double)SPEC_MIN_HZ);
	double hi = log10((double)SPEC_MAX_HZ);
	double t = (double)p / (double)(SPEC_POINTS - 1);

	return (float)pow(10.0, lo + t * (hi - lo));
}

static void spectro_update(struct spectro_state *sp, const int16_t *samples)
{
	float peak = SPEC_MIN_DB;

	for (int i = 0; i < FFT_N; i++) {
		sp->fft_re[i] = (float)samples[i] * sp->window[i] / 32768.0f;
		sp->fft_im[i] = 0.0f;
	}
	fft_inplace(sp->fft_re, sp->fft_im, FFT_N);

	/*
	 * Log-frequency sampling of raw |X[k]| (no /N). Dividing by
	 * FFT_N * Hann coherent gain mapped speech below SPEC_MIN_DB so the
	 * stroke sat on the X axis and only the grid remained visible.
	 */
	for (int p = 0; p < SPEC_POINTS; p++) {
		float freq = freq_at_point(p);
		float bin_f = freq * (float)FFT_N / (float)MIC_RATE;
		int b0;
		float frac;
		float mag, db_new;

		/* Skip DC (bin 0). Do not invent a negative frac below bin 1. */
		if (bin_f < 1.0f) {
			b0 = 1;
			frac = 0.0f;
		} else {
			b0 = (int)bin_f;
			if (b0 >= FFT_BINS - 1)
				b0 = FFT_BINS - 2;
			frac = bin_f - (float)b0;
		}
		{
			float mag0 = hypotf(sp->fft_re[b0], sp->fft_im[b0]);
			float mag1 = hypotf(sp->fft_re[b0 + 1], sp->fft_im[b0 + 1]);
			mag = mag0 + frac * (mag1 - mag0);
		}
		db_new = mag_to_db(mag);
		sp->db[p] = db_new;
		if (db_new > peak)
			peak = db_new;
	}
	sp->peak_db = peak;
	sp->have_spectrum = true;
	sp->dirty = true;
}

static void spectro_push_sample(struct spectro_state *sp, int16_t sample)
{
	sp->hop[sp->hop_fill++] = sample;
	if (sp->hop_fill < FFT_N)
		return;

	/* Keep the newest window; FFT waits for the 20 Hz display tick. */
	memcpy(sp->latest, sp->hop, sizeof(sp->latest));
	memmove(sp->hop, sp->hop + FFT_HOP, sizeof(int16_t) * (FFT_N - FFT_HOP));
	sp->hop_fill = FFT_N - FFT_HOP;
	sp->window_ready = true;
}

static void spectro_refresh_if_ready(struct spectro_state *sp)
{
	if (!sp->window_ready)
		return;
	spectro_update(sp, sp->latest);
	sp->window_ready = false;
}

static void mic_close(struct mic_state *mic)
{
	if (mic->pcm) {
		snd_pcm_close(mic->pcm);
		mic->pcm = NULL;
	}
	mic->ok = false;
}

static int mic_configure_pcm(snd_pcm_t *pcm, unsigned *channels)
{
	snd_pcm_hw_params_t *hw;
	unsigned int rate = MIC_RATE;
	unsigned int ch = MIC_CHANNELS;
	int err;

	snd_pcm_hw_params_alloca(&hw);
	err = snd_pcm_hw_params_any(pcm, hw);
	if (err < 0)
		return err;
	err = snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
	if (err < 0)
		return err;
	err = snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE);
	if (err < 0)
		return err;
	err = snd_pcm_hw_params_set_channels(pcm, hw, ch);
	if (err < 0)
		return err;
	err = snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, NULL);
	if (err < 0)
		return err;
	{
		snd_pcm_uframes_t period = MIC_PERIOD;
		err = snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, NULL);
	}
	if (err < 0)
		return err;
	err = snd_pcm_hw_params(pcm, hw);
	if (err < 0)
		return err;
	err = snd_pcm_prepare(pcm);
	if (err < 0)
		return err;
	*channels = ch;
	return 0;
}

static void mic_open(struct app *app)
{
	struct mic_state *mic = &app->mic;
	const char *dev = getenv("INFO_PANEL_ALSA_DEVICE");
	int err;

	/* simple-audio-card name from the AC200 DTS; mixer is set at boot. */
	if (!dev || !dev[0])
		dev = "hw:CARD=ac200audio,DEV=0";

	if (mic->pcm)
		return;
	if (monotonic_ms() < mic->next_retry_ms)
		return;

	err = snd_pcm_open(&mic->pcm, dev, SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
	if (err < 0) {
		snprintf(mic->status, sizeof(mic->status), "mic: %s", snd_strerror(err));
		mic->next_retry_ms = monotonic_ms() + MIC_RETRY_MS;
		return;
	}

	err = mic_configure_pcm(mic->pcm, &mic->channels);
	if (err < 0) {
		snprintf(mic->status, sizeof(mic->status), "mic cfg: %s", snd_strerror(err));
		mic_close(mic);
		mic->next_retry_ms = monotonic_ms() + MIC_RETRY_MS;
		return;
	}

	mic->ok = true;
	snprintf(mic->status, sizeof(mic->status), "mic live");
}

static bool mic_poll(struct app *app)
{
	struct mic_state *mic = &app->mic;
	int16_t buf[MIC_PERIOD * MIC_CHANNELS];
	snd_pcm_sframes_t n;
	bool got = false;

	if (!mic->ok) {
		mic_open(app);
		return false;
	}

	for (;;) {
		n = snd_pcm_readi(mic->pcm, buf, MIC_PERIOD);
		if (n == -EAGAIN)
			break;
		if (n == -EPIPE) {
			snd_pcm_prepare(mic->pcm);
			continue;
		}
		if (n < 0) {
			snprintf(mic->status, sizeof(mic->status), "read: %s", snd_strerror((int)n));
			mic_close(mic);
			mic->next_retry_ms = monotonic_ms() + MIC_RETRY_MS;
			break;
		}
		got = true;
		/* Left channel only; AC200 capture is stereo-interleaved S16. */
		for (snd_pcm_sframes_t i = 0; i < n; i++)
			spectro_push_sample(&app->spectro, buf[i * mic->channels]);
	}
	return got;
}

static void mic_drain(struct app *app)
{
	while (mic_poll(app))
		;
}

static double spec_freq_to_x(double freq, double plot_x, double plot_w)
{
	double lo = log10((double)SPEC_MIN_HZ);
	double hi = log10((double)SPEC_MAX_HZ);
	double t = (log10(freq) - lo) / (hi - lo);

	if (t < 0.0)
		t = 0.0;
	if (t > 1.0)
		t = 1.0;
	return plot_x + t * plot_w;
}

static double spec_db_to_y(double db, double plot_y, double plot_h)
{
	double t = (db - (double)SPEC_MIN_DB) / ((double)SPEC_MAX_DB - (double)SPEC_MIN_DB);

	if (t < 0.0)
		t = 0.0;
	if (t > 1.0)
		t = 1.0;
	return plot_y + (1.0 - t) * plot_h;
}

static void draw_spectrogram(struct app *app, cairo_t *cr, struct shm_buffer *b,
			     bool axes)
{
	const struct spectro_state *sp = &app->spectro;
	const struct mic_state *mic = &app->mic;
	const double w = b->width;
	const double h = b->height;
	const double info_h = h * INFO_SPLIT;
	const double label_size = h * 0.020;
	const double tick_size = h * 0.016;
	const double edge = label_size * 1.6;
	const double db_w = label_size * 1.55;
	const double num_col_w = tick_size * 3.5;
	const double margin_l = edge + db_w + 4.0 + num_col_w + 6.0;
	const double margin_r = edge + tick_size * 2.0;
	const double margin_t = tick_size + 18.0;
	const double margin_b = tick_size + 4.0 + 6.0 + label_size + edge;
	const double y0 = info_h + margin_t;
	/* Integer pixels: a 1.5px stroke on a fractional y shimmered with the 24 dB grid. */
	const double plot_x = (double)(int)(margin_l + 0.5);
	const double plot_y = (double)(int)(y0 + 0.5);
	const double plot_w = (double)(int)(w - plot_x - margin_r + 0.5);
	const double plot_h = (double)(int)(h - plot_y - margin_b + 0.5);
	static const float freq_ticks[] = { 40, 100, 200, 500, 1000, 2000, 5000 };
	static const float db_ticks[] = { -48, -36, -24, -12, 0, 12, 24 };
	char label[32];
	double tick_baseline;
	double freq_baseline;
	int i;

	(void)axes;

	cairo_set_source_rgb(cr, 0.04, 0.07, 0.12);
	cairo_rectangle(cr, 0.0, info_h + 4.0, plot_x, h - (info_h + 4.0));
	cairo_fill(cr);
	cairo_rectangle(cr, 0.0, plot_y + plot_h, w, h - (plot_y + plot_h));
	cairo_fill(cr);
	/* Top strip above the frame — stop 1px short so the 1px stroke is not erased. */
	if (plot_y - 1.0 > info_h + 4.0)
		cairo_rectangle(cr, plot_x, info_h + 4.0, plot_w, plot_y - 1.0 - (info_h + 4.0));
	cairo_fill(cr);

	cairo_set_source_rgb(cr, 0.02, 0.04, 0.08);
	cairo_rectangle(cr, plot_x, plot_y, plot_w, plot_h);
	cairo_fill(cr);

	/* Grid every frame: the fill above erases it on 5 Hz updates. */
	cairo_set_source_rgb(cr, 0.14, 0.20, 0.28);
	cairo_set_line_width(cr, 1.0);
	for (i = 0; i < (int)(sizeof(freq_ticks) / sizeof(freq_ticks[0])); i++) {
		double x = spec_freq_to_x(freq_ticks[i], plot_x, plot_w);
		cairo_move_to(cr, x, plot_y + 1.0);
		cairo_line_to(cr, x, plot_y + plot_h - 1.0);
		cairo_stroke(cr);
	}
	for (i = 0; i < (int)(sizeof(db_ticks) / sizeof(db_ticks[0])); i++) {
		double y = spec_db_to_y(db_ticks[i], plot_y, plot_h);

		/* 24 / −48 sit on the frame; a second stroke there made the top edge flicker. */
		if (db_ticks[i] >= 24.0f || db_ticks[i] <= -48.0f)
			continue;
		cairo_move_to(cr, plot_x, y);
		cairo_line_to(cr, plot_x + plot_w, y);
		cairo_stroke(cr);
	}

	cairo_set_source_rgb(cr, 0.55, 0.65, 0.75);
	cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
	tick_baseline = plot_y + plot_h + tick_size + 4.0;
	freq_baseline = h - edge;
	cairo_set_font_size(cr, tick_size);
	for (i = 0; i < (int)(sizeof(freq_ticks) / sizeof(freq_ticks[0])); i++) {
		double x = spec_freq_to_x(freq_ticks[i], plot_x, plot_w);
		double tw;
		double tx;

		/* Skip 40 Hz: it collides with -48 dB at the origin. */
		if (freq_ticks[i] <= 40.0f)
			continue;
		if (freq_ticks[i] >= 1000.0f)
			snprintf(label, sizeof(label), "%.0fk", freq_ticks[i] / 1000.0f);
		else
			snprintf(label, sizeof(label), "%.0f", freq_ticks[i]);
		tw = tick_size * (double)strlen(label) * 0.70;
		tx = x - tw * 0.5;
		if (tx < edge)
			tx = edge;
		if (tx + tw > w - edge)
			tx = w - edge - tw;
		cairo_move_to(cr, tx, tick_baseline);
		cairo_show_text(cr, label);
	}
	for (i = 0; i < (int)(sizeof(db_ticks) / sizeof(db_ticks[0])); i++) {
		double y = spec_db_to_y(db_ticks[i], plot_y, plot_h);
		double baseline = y + tick_size * 0.35;
		double tw = 0.0;
		size_t c;

		/* "24" would otherwise straddle the top stroke (same flicker as "dB"). */
		if (db_ticks[i] >= 24.0f)
			baseline = plot_y + tick_size;
		snprintf(label, sizeof(label), "%.0f", db_ticks[i]);
		/* cairo_text_extents is unusable on this image; size per glyph. */
		for (c = 0; label[c]; c++)
			tw += (label[c] == '-') ? tick_size * 0.40 : tick_size * 0.58;
		cairo_move_to(cr, plot_x - 3.0 - tw, baseline);
		cairo_show_text(cr, label);
	}

	cairo_set_font_size(cr, label_size);
	{
		const char *freq_title = "Frequency (Hz)";
		double title_w = label_size * (double)strlen(freq_title) * 0.55;

		cairo_move_to(cr, plot_x + (plot_w - title_w) * 0.5, freq_baseline);
		cairo_show_text(cr, freq_title);
	}
	/*
	 * Toy-font ascent can exceed font_size. Keep the cap ≥6px below the
	 * 1px top stroke so "dB" does not share AA pixels with the frame.
	 */
	cairo_move_to(cr, edge, plot_y + 6.0 + label_size * 1.15);
	cairo_show_text(cr, "dB");

	if (sp->have_spectrum) {
		const double y_floor = plot_y + plot_h - 1.0;
		const double bar_slot = plot_w / (double)SPEC_BARS;
		const double bar_gap = bar_slot > 3.0 ? 1.0 : 0.0;
		const double bar_w = bar_slot - 2.0 * bar_gap;
		int b;

		cairo_save(cr);
		/* Inset so bars at +24 dB cannot chew the top stroke. */
		cairo_rectangle(cr, plot_x + 1.0, plot_y + 2.0, plot_w - 2.0, plot_h - 3.0);
		cairo_clip(cr);
		cairo_set_antialias(cr, CAIRO_ANTIALIAS_NONE);
		cairo_set_source_rgb(cr, 0.45, 0.88, 1.0);
		for (b = 0; b < SPEC_BARS; b++) {
			int p0 = (b * SPEC_POINTS) / SPEC_BARS;
			int p1 = ((b + 1) * SPEC_POINTS) / SPEC_BARS;
			float db = SPEC_MIN_DB;
			double x0;
			double y;
			int p;

			if (p1 <= p0)
				p1 = p0 + 1;
			for (p = p0; p < p1 && p < SPEC_POINTS; p++) {
				if (sp->db[p] > db)
					db = sp->db[p];
			}
			y = spec_db_to_y(db, plot_y, plot_h);
			if (y > y_floor)
				continue;
			x0 = plot_x + (double)b * bar_slot + bar_gap;
			if (bar_w >= 1.5) {
				cairo_rectangle(cr, x0, y, bar_w, y_floor - y);
				cairo_fill(cr);
			} else {
				cairo_set_line_width(cr, 1.0);
				cairo_move_to(cr, x0 + 0.5, y_floor);
				cairo_line_to(cr, x0 + 0.5, y);
				cairo_stroke(cr);
			}
		}
		cairo_restore(cr);
	}

	cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
	cairo_set_font_size(cr, tick_size);
	{
		/* "peak" and "dB" stay put; only the digits move inside a fixed slot. */
		const double ch = tick_size * 0.58;
		const double peak_word_w = tick_size * 4.0 * 0.62;
		const double num_slot_w = ch * 5.0;
		const double db_word_w = tick_size * 2.0 * 0.62;
		const double gap = tick_size * 0.40;
		double px = plot_x + plot_w - 10.0 -
			    (peak_word_w + gap + num_slot_w + gap + db_word_w);
		double py = plot_y - 8.0;

		if (px < plot_x + 8.0)
			px = plot_x + 8.0;
		if (py < info_h + tick_size)
			py = info_h + tick_size;
		cairo_set_source_rgb(cr, 0.70, 0.80, 0.88);
		if (mic->ok && sp->have_spectrum) {
			char num[16];
			double tw = 0.0;
			size_t c;

			cairo_move_to(cr, px, py);
			cairo_show_text(cr, "peak");
			snprintf(num, sizeof(num), "%.0f", sp->peak_db);
			for (c = 0; num[c]; c++)
				tw += (num[c] == '-') ? tick_size * 0.40 : ch;
			cairo_move_to(cr, px + peak_word_w + gap + num_slot_w - tw, py);
			cairo_show_text(cr, num);
			cairo_move_to(cr, px + peak_word_w + gap + num_slot_w + gap, py);
			cairo_show_text(cr, "dB");
		} else {
			cairo_move_to(cr, px, py);
			cairo_show_text(cr, mic->status[0] ? mic->status : "mic: waiting...");
		}
	}

	cairo_set_source_rgb(cr, 0.28, 0.38, 0.48);
	cairo_set_line_width(cr, 1.0);
	cairo_rectangle(cr, plot_x + 0.5, plot_y + 0.5, plot_w - 1.0, plot_h - 1.0);
	cairo_stroke(cr);
}

static void draw_stats(struct app *app, cairo_t *cr, double w, double h)
{
	const struct panel_metrics *m = &app->metrics;
	const double info_h = h * INFO_SPLIT;
	char line[128];
	time_t now = time(NULL);
	struct tm tm_now;
	localtime_r(&now, &tm_now);
	char timestr[64];
	strftime(timestr, sizeof(timestr), "%Y-%m-%d  %H:%M:%S", &tm_now);

	double title_size = info_h * 0.09;
	double body_size = info_h * 0.062;
	double small_size = info_h * 0.042;
	double x = w * 0.08;
	double y = info_h * 0.14;
	double row = body_size * 1.22;

	cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
	cairo_set_font_size(cr, title_size);
	cairo_set_source_rgb(cr, 0.92, 0.95, 0.98);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, "Orange Pi 3");

	y += title_size * 0.85;
	cairo_set_font_size(cr, small_size);
	cairo_set_source_rgb(cr, 0.55, 0.65, 0.75);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, m->hostname);
	cairo_move_to(cr, x + w * 0.35, y);
	cairo_show_text(cr, timestr);

	y += body_size * 1.45;
	cairo_set_font_size(cr, body_size);
	cairo_set_source_rgb(cr, 0.75, 0.82, 0.90);
	cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);

	if (m->cpu_ok)
		snprintf(line, sizeof(line), "CPU temperature     %.1f C", m->cpu_c);
	else
		snprintf(line, sizeof(line), "CPU temperature     n/a");
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += row;
	if (m->cores_ok && m->ncpus > 0) {
		char *p = line;
		size_t left = sizeof(line);
		int n;

		n = snprintf(p, left, "CPU cores           ");
		if (n < 0 || (size_t)n >= left)
			n = 0;
		p += n;
		left -= (size_t)n;
		for (int i = 0; i < m->ncpus && left > 1; i++) {
			n = snprintf(p, left, "%s%.0f%%", i ? "  " : "", m->core_pct[i]);
			if (n < 0 || (size_t)n >= left)
				break;
			p += n;
			left -= (size_t)n;
		}
	} else {
		snprintf(line, sizeof(line), "CPU cores           sampling...");
	}
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += row;
	if (m->mem_total_kb > 0) {
		double used = (double)(m->mem_total_kb - m->mem_avail_kb) / 1024.0;
		double total = (double)m->mem_total_kb / 1024.0;
		double pct = 100.0 * (1.0 - (double)m->mem_avail_kb / (double)m->mem_total_kb);
		snprintf(line, sizeof(line), "Memory              %.0f / %.0f MiB  (%.0f%%)",
			 used, total, pct);
	} else {
		snprintf(line, sizeof(line), "Memory              n/a");
	}
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += body_size * 0.5;
	double bar_w = w * 0.70;
	double bar_h = info_h * 0.022;
	cairo_set_source_rgb(cr, 0.12, 0.18, 0.28);
	cairo_rectangle(cr, x, y, bar_w, bar_h);
	cairo_fill(cr);
	if (m->mem_total_kb > 0) {
		double frac = 1.0 - (double)m->mem_avail_kb / (double)m->mem_total_kb;
		if (frac < 0)
			frac = 0;
		if (frac > 1)
			frac = 1;
		cairo_set_source_rgb(cr, 0.25, 0.65, 0.90);
		cairo_rectangle(cr, x, y, bar_w * frac, bar_h);
		cairo_fill(cr);
	}

	y += body_size * 1.25;
	snprintf(line, sizeof(line), "Uptime              %s", m->uptime);
	cairo_set_source_rgb(cr, 0.75, 0.82, 0.90);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += row;
	snprintf(line, sizeof(line), "IP address          %s  (%s)", m->ip, m->iface);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += row;
	snprintf(line, sizeof(line), "WiFi                %s", m->wifi_ssid);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += row;
	snprintf(line, sizeof(line), "AP SSID             %s", m->ap_ssid);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += row;
	snprintf(line, sizeof(line), "AP IP address       %s", m->ap_ip);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, line);

	y += body_size * 1.15;
	if (y < info_h - small_size * 0.4) {
		cairo_set_font_size(cr, small_size);
		cairo_set_source_rgb(cr, 0.40, 0.50, 0.60);
		cairo_move_to(cr, x, y);
		cairo_show_text(cr, "Wayland / Weston  ·  GPU Mali (Lima)");
	}
}

static void draw_panel(struct app *app, struct shm_buffer *b, bool full)
{
	cairo_surface_t *cs = cairo_image_surface_create_for_data(
		b->data, CAIRO_FORMAT_ARGB32, b->width, b->height, b->width * 4);
	cairo_t *cr = cairo_create(cs);
	const double w = b->width;
	const double h = b->height;
	const double info_h = h * INFO_SPLIT;

	if (full) {
		cairo_set_source_rgb(cr, 0.04, 0.07, 0.12);
		cairo_paint(cr);

		cairo_set_source_rgb(cr, 0.20, 0.55, 0.85);
		cairo_rectangle(cr, 0, 0, w, h * 0.01);
		cairo_fill(cr);

		draw_stats(app, cr, w, h);

		cairo_set_source_rgb(cr, 0.18, 0.28, 0.38);
		cairo_rectangle(cr, 0, info_h, w, h * 0.004);
		cairo_fill(cr);
	}

	draw_spectrogram(app, cr, b, full);

	cairo_destroy(cr);
	cairo_surface_destroy(cs);
}

/* Wait for wl_buffer.release. Attaching a busy buffer reset this H6. */
static struct shm_buffer *pick_buffer(struct app *app, bool force)
{
	struct shm_buffer *fallback = NULL;

	for (int i = 0; i < 2; i++) {
		struct shm_buffer *b = &app->buffers[app->buffer_idx];
		app->buffer_idx = (app->buffer_idx + 1) % 2;
		if (!b->busy)
			return b;
		fallback = b;
	}
	return force ? fallback : NULL;
}

static bool render(struct app *app, bool force_buffer, bool full)
{
	int width = app->output_width > 0 ? app->output_width : 1280;
	int height = app->output_height > 0 ? app->output_height : 720;
	int32_t spec_y;

	for (int i = 0; i < 2; i++) {
		if (app->buffers[i].wl_buffer &&
		    (app->buffers[i].width != width || app->buffers[i].height != height)) {
			shm_buffer_destroy(&app->buffers[i]);
		}
		if (!app->buffers[i].wl_buffer) {
			if (shm_buffer_init(app, &app->buffers[i], width, height) < 0) {
				fprintf(stderr, "shm buffer init failed\n");
				app->running = false;
				return false;
			}
		}
	}

	struct shm_buffer *b = pick_buffer(app, force_buffer);
	if (!b)
		return false;

	if (!full && !b->stats_valid)
		full = true;

	draw_panel(app, b, full);
	b->busy = true;
	if (full)
		b->stats_valid = true;

	spec_y = (int32_t)(height * INFO_SPLIT);
	wl_surface_set_buffer_scale(app->surface, app->scale > 0 ? app->scale : 1);
	wl_surface_attach(app->surface, b->wl_buffer, 0, 0);
	if (full)
		wl_surface_damage_buffer(app->surface, 0, 0, width, height);
	else
		wl_surface_damage_buffer(app->surface, 0, spec_y, width, height - spec_y);
	wl_surface_commit(app->surface);
	return true;
}

static int loop_timeout_ms(bool configured, uint64_t now_ms,
			   uint64_t last_spec_ms, uint64_t last_metrics_ms)
{
	uint64_t next_spec;
	uint64_t next_metrics;
	uint64_t next;
	int wait;

	if (!configured)
		return 20;
	next_spec = last_spec_ms + SPEC_FRAME_MS;
	next_metrics = last_metrics_ms + 1000;
	next = next_spec < next_metrics ? next_spec : next_metrics;
	if (next <= now_ms)
		return POLL_MIN_MS;
	if (next - now_ms > 1000)
		return SPEC_FRAME_MS;
	wait = (int)(next - now_ms);
	return wait < POLL_MIN_MS ? POLL_MIN_MS : wait;
}

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
	metrics_refresh(&app->metrics);
	render(app, false, true);
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
	(void)data; (void)output; (void)x; (void)y; (void)pw; (void)ph;
	(void)subpixel; (void)make; (void)model; (void)transform;
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
	(void)argc;
	(void)argv;

	struct app app = { 0 };
	app.running = true;
	app.scale = 1;
	app.output_width = 1280;
	app.output_height = 720;
	snprintf(app.mic.status, sizeof(app.mic.status), "mic: starting");
	spectro_init(&app.spectro);
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
	xdg_toplevel_set_title(app.xdg_toplevel, "Info Panel");
	xdg_toplevel_set_app_id(app.xdg_toplevel, "info-panel");
	xdg_toplevel_set_fullscreen(app.xdg_toplevel, app.output);
	wl_surface_commit(app.surface);

	struct pollfd pfds[MAX_POLL_FDS];
	int npoll;

	uint64_t last_metrics_ms = 0;
	uint64_t last_spec_ms = 0;
	while (app.running) {
		uint64_t now_ms;

		while (wl_display_prepare_read(app.display) != 0)
			wl_display_dispatch_pending(app.display);
		wl_display_flush(app.display);

		now_ms = monotonic_ms();
		npoll = 0;
		pfds[npoll].fd = wl_display_get_fd(app.display);
		pfds[npoll].events = POLLIN;
		npoll++;
		/* Do not poll ALSA: capture fds stay POLLOUT/POLLIN and poll() never
		 * blocks, which pinned a core and reset the board. Drain below. */

		int ret = poll(pfds, (nfds_t)npoll,
			       loop_timeout_ms(app.configured, now_ms,
					       last_spec_ms, last_metrics_ms));
		if (ret < 0 && errno != EINTR) {
			wl_display_cancel_read(app.display);
			break;
		}
		if (ret > 0)
			wl_display_read_events(app.display);
		else
			wl_display_cancel_read(app.display);

		wl_display_dispatch_pending(app.display);

		if (app.configured)
			mic_drain(&app);

		now_ms = monotonic_ms();
		bool metrics_due = app.configured && (now_ms - last_metrics_ms) >= 1000;
		bool spec_due = app.configured &&
				(app.spectro.dirty || app.spectro.window_ready) &&
				(now_ms - last_spec_ms) >= SPEC_FRAME_MS;

		if (metrics_due) {
			metrics_refresh(&app.metrics);
			spectro_refresh_if_ready(&app.spectro);
			/* Wait for a free buffer; stealing a busy one reset the SoC. */
			if (render(&app, false, true)) {
				last_metrics_ms = now_ms;
				app.spectro.dirty = false;
				last_spec_ms = now_ms;
			}
		} else if (spec_due) {
			spectro_refresh_if_ready(&app.spectro);
			if (render(&app, false, false)) {
				app.spectro.dirty = false;
				last_spec_ms = now_ms;
			}
		}

		/* Hard cap: Wayland/ALSA can leave poll() instantly ready. */
		{
			struct timespec slp = { .tv_sec = 0, .tv_nsec = (long)POLL_MIN_MS * 1000000L };

			nanosleep(&slp, NULL);
		}
	}

	mic_close(&app.mic);
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
