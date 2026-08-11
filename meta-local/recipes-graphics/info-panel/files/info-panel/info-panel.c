/*
 * Fullscreen Wayland info panel: CPU temp/usage, memory, uptime, STA IP/SSID,
 * and setup-AP SSID/IP when hostapd mode is active.
 * Composited by Weston on DRM/KMS; GPU path is Mesa Lima (Mali).
 */

#define _GNU_SOURCE
#include <cairo/cairo.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
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

static void draw_panel(struct app *app, struct shm_buffer *b)
{
	cairo_surface_t *cs = cairo_image_surface_create_for_data(
		b->data, CAIRO_FORMAT_ARGB32, b->width, b->height, b->width * 4);
	cairo_t *cr = cairo_create(cs);
	const struct panel_metrics *m = &app->metrics;
	const double w = b->width;
	const double h = b->height;
	char line[128];
	time_t now = time(NULL);
	struct tm tm_now;
	localtime_r(&now, &tm_now);
	char timestr[64];
	strftime(timestr, sizeof(timestr), "%Y-%m-%d  %H:%M:%S", &tm_now);

	/* Background */
	cairo_set_source_rgb(cr, 0.04, 0.07, 0.12);
	cairo_paint(cr);

	/* Accent bar */
	cairo_set_source_rgb(cr, 0.20, 0.55, 0.85);
	cairo_rectangle(cr, 0, 0, w, h * 0.01);
	cairo_fill(cr);

	double title_size = h * 0.07;
	double body_size = h * 0.048;
	double small_size = h * 0.032;
	double x = w * 0.08;
	double y = h * 0.15;
	double row = body_size * 1.28;

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

	/* Memory bar */
	y += body_size * 0.5;
	double bar_w = w * 0.70;
	double bar_h = h * 0.016;
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

	y += body_size * 1.35;
	cairo_set_font_size(cr, small_size);
	cairo_set_source_rgb(cr, 0.40, 0.50, 0.60);
	cairo_move_to(cr, x, y);
	cairo_show_text(cr, "Wayland / Weston  ·  GPU Mali (Lima)");

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

static void render(struct app *app)
{
	int width = app->output_width > 0 ? app->output_width : 1280;
	int height = app->output_height > 0 ? app->output_height : 720;

	for (int i = 0; i < 2; i++) {
		if (app->buffers[i].wl_buffer &&
		    (app->buffers[i].width != width || app->buffers[i].height != height)) {
			shm_buffer_destroy(&app->buffers[i]);
		}
		if (!app->buffers[i].wl_buffer) {
			if (shm_buffer_init(app, &app->buffers[i], width, height) < 0) {
				fprintf(stderr, "shm buffer init failed\n");
				app->running = false;
				return;
			}
		}
	}

	struct shm_buffer *b = pick_buffer(app);
	if (!b)
		return;

	metrics_refresh(&app->metrics);
	draw_panel(app, b);
	b->busy = true;

	wl_surface_set_buffer_scale(app->surface, app->scale > 0 ? app->scale : 1);
	wl_surface_attach(app->surface, b->wl_buffer, 0, 0);
	wl_surface_damage_buffer(app->surface, 0, 0, width, height);
	wl_surface_commit(app->surface);
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

	struct pollfd fds[1];
	fds[0].fd = wl_display_get_fd(app.display);
	fds[0].events = POLLIN;

	uint64_t last_ms = 0;
	while (app.running) {
		while (wl_display_prepare_read(app.display) != 0)
			wl_display_dispatch_pending(app.display);
		wl_display_flush(app.display);

		int ret = poll(fds, 1, 50);
		if (ret < 0 && errno != EINTR) {
			wl_display_cancel_read(app.display);
			break;
		}
		if (ret > 0)
			wl_display_read_events(app.display);
		else
			wl_display_cancel_read(app.display);

		wl_display_dispatch_pending(app.display);

		struct timespec ts;
		clock_gettime(CLOCK_MONOTONIC, &ts);
		uint64_t now_ms = (uint64_t)ts.tv_sec * 1000ULL +
				  (uint64_t)ts.tv_nsec / 1000000ULL;
		/* ~1 Hz panel refresh. */
		if (app.configured && (now_ms - last_ms) >= 1000) {
			last_ms = now_ms;
			render(&app);
		}
	}

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
