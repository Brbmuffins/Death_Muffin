// The combat core's crash note: crash_note.h. Everything that runs while the game is crashing uses static buffers and plain OS calls only.
#include "crash_note.h"

#include <cstring>

namespace dm::crash {

namespace {

struct Out {
	char *p;
	size_t cap;
	size_t n;
};

void put(Out &o, const char *s) {
	while (s && *s && o.n + 1 < o.cap) {
		o.p[o.n++] = *s++;
	}
	o.p[o.n] = 0;
}

void put_hex(Out &o, uint64_t v) {
	char t[17];
	int i = 16;
	t[16] = 0;
	do {
		t[--i] = "0123456789abcdef"[v & 15u];
		v >>= 4;
	} while (v && i > 0);
	put(o, "0x");
	put(o, t + i);
}

void put_dec(Out &o, int v) {
	char t[12];
	int i = 11;
	t[11] = 0;
	if (v <= 0) {
		t[--i] = '0';
	}
	while (v > 0 && i > 0) {
		t[--i] = char('0' + v % 10);
		v /= 10;
	}
	put(o, t + i);
}

void copy(char *dst, size_t cap, const char *src) {
	size_t i = 0;
	for (; src && src[i] && i + 1 < cap; i++) {
		dst[i] = src[i];
	}
	dst[i] = 0;
}

}  // namespace

size_t format_note(char *out, size_t cap, const char *build, const char *what, const Frame *frames, int count) {
	if (!out || cap == 0) {
		return 0;
	}
	Out o{out, cap, 0};
	out[0] = 0;
	put(o, "DMCORE CRASH NOTE\nbuild ");
	put(o, build && *build ? build : "unknown");
	put(o, "\nwhat ");
	put(o, what && *what ? what : "unknown");
	put(o, "\n");
	for (int i = 0; i < count; i++) {
		put(o, "#");
		put_dec(o, i);
		put(o, " ");
		put(o, frames[i].module && *frames[i].module ? frames[i].module : "?");
		put(o, "+");
		put_hex(o, frames[i].offset);
		put(o, "\n");
	}
	return o.n;
}

void crash_now() {
	volatile int *bad = reinterpret_cast<volatile int *>(uintptr_t(8));
	*bad = 1;
}

}  // namespace dm::crash

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

namespace dm::crash {
namespace {

constexpr int MAX_FRAMES = 32;
wchar_t g_path[1024];
char g_build[96];
LPTOP_LEVEL_EXCEPTION_FILTER g_prev = nullptr;
bool g_armed = false;
volatile LONG g_once = 0;
alignas(16) CONTEXT g_ctx;  // static: a crash after a stack overflow leaves little stack to work with
Frame g_frames[MAX_FRAMES];
char g_names[MAX_FRAMES][64];
char g_what[64];
char g_note[8192];

void name_frame(DWORD64 pc, int i) {
	Frame &f = g_frames[i];
	char *name = g_names[i];
	name[0] = '?';
	name[1] = 0;
	f.module = name;
	f.offset = pc;
	HMODULE mod = nullptr;
	if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
				reinterpret_cast<LPCWSTR>(pc), &mod) &&
			mod) {
		f.offset = pc - reinterpret_cast<DWORD64>(mod);
		wchar_t full[MAX_PATH];
		DWORD n = GetModuleFileNameW(mod, full, MAX_PATH);
		const wchar_t *base = full;
		for (DWORD k = 0; k < n; k++) {
			if (full[k] == L'\\' || full[k] == L'/') {
				base = full + k + 1;
			}
		}
		if (n > 0) {
			WideCharToMultiByte(CP_UTF8, 0, base, -1, name, int(sizeof(g_names[i])), nullptr, nullptr);
		}
	}
}

void describe(DWORD code) {
	const char *s = nullptr;
	switch (code) {
		case EXCEPTION_ACCESS_VIOLATION: s = "access violation"; break;
		case EXCEPTION_STACK_OVERFLOW: s = "stack overflow"; break;
		case EXCEPTION_ILLEGAL_INSTRUCTION: s = "illegal instruction"; break;
		case EXCEPTION_INT_DIVIDE_BY_ZERO: s = "integer divide by zero"; break;
		case EXCEPTION_ARRAY_BOUNDS_EXCEEDED: s = "array bounds exceeded"; break;
		case EXCEPTION_IN_PAGE_ERROR: s = "in-page error"; break;
		case EXCEPTION_PRIV_INSTRUCTION: s = "privileged instruction"; break;
		default: s = "exception"; break;
	}
	Out o{g_what, sizeof(g_what), 0};
	put(o, s);
	put(o, " (");
	put_hex(o, code);
	put(o, ")");
}

// The frames from the crashing context: x64 unwind data (every 64-bit Windows module has it) walks from one frame to its caller. A frame
// without unwind data is a leaf function: allowed for the crashing frame only, whose return address is on top of the stack.
int walk(const CONTEXT &start) {
	g_ctx = start;
	int n = 0;
	while (n < MAX_FRAMES) {
		const DWORD64 pc = g_ctx.Rip;
		const DWORD64 sp = g_ctx.Rsp;
		if (!pc) {
			break;
		}
		name_frame(pc, n++);
		DWORD64 image_base = 0;
		PRUNTIME_FUNCTION fn = RtlLookupFunctionEntry(pc, &image_base, nullptr);
		if (fn) {
			PVOID handler_data = nullptr;
			DWORD64 establisher = 0;
			RtlVirtualUnwind(UNW_FLAG_NHANDLER, image_base, pc, fn, &g_ctx, &handler_data, &establisher, nullptr);
		} else if (n == 1 && sp) {
			g_ctx.Rip = *reinterpret_cast<const DWORD64 *>(sp);
			g_ctx.Rsp = sp + 8;
		} else {
			break;
		}
		if (g_ctx.Rsp <= sp && g_ctx.Rip == pc) {
			break;  // no progress: stop rather than loop
		}
	}
	return n;
}

LONG WINAPI on_crash(EXCEPTION_POINTERS *ep) {
	if (InterlockedExchange(&g_once, 1) == 0 && ep && ep->ContextRecord && g_path[0]) {
		describe(ep->ExceptionRecord ? ep->ExceptionRecord->ExceptionCode : 0);
		const int n = walk(*ep->ContextRecord);
		const size_t len = format_note(g_note, sizeof(g_note), g_build, g_what, g_frames, n);
		HANDLE h = CreateFileW(g_path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
		if (h != INVALID_HANDLE_VALUE) {
			DWORD written = 0;
			WriteFile(h, g_note, DWORD(len), &written, nullptr);
			FlushFileBuffers(h);
			CloseHandle(h);
		}
	}
	return g_prev ? g_prev(ep) : EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

void arm(const char *path, const char *build) {
	if (path) {
		if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, g_path, int(sizeof(g_path) / sizeof(g_path[0])))) {
			g_path[0] = 0;
		}
	}
	copy(g_build, sizeof(g_build), build);
	if (!g_armed) {
		g_prev = SetUnhandledExceptionFilter(&on_crash);
		g_armed = true;
	}
}

}  // namespace dm::crash

#else

#include <csignal>
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <ucontext.h>
#include <unistd.h>

namespace dm::crash {
namespace {

constexpr int MAX_FRAMES = 32;
constexpr int SIGNALS[4] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL};
char g_path[1024];
char g_build[96];
bool g_armed = false;
volatile sig_atomic_t g_once = 0;
struct sigaction g_prev[4];
void *g_pcs[MAX_FRAMES];
void *g_list[MAX_FRAMES];
Frame g_frames[MAX_FRAMES];
char g_note[8192];

const char *signal_name(int s) {
	switch (s) {
		case SIGSEGV: return "SIGSEGV";
		case SIGBUS: return "SIGBUS";
		case SIGFPE: return "SIGFPE";
		case SIGILL: return "SIGILL";
		default: return "signal";
	}
}

void on_signal(int sig, siginfo_t *info, void *uctx) {
	if (!g_once && g_path[0]) {
		g_once = 1;
		// The note starts at the crashing instruction, as on Windows: backtrace() from here begins with this handler and the kernel's return
		// step, then the crashing frame, whose address the signal's context holds.
		const int got = backtrace(g_pcs, MAX_FRAMES);
		void *fault = nullptr;
#if defined(__x86_64__)
		if (uctx) {
			fault = reinterpret_cast<void *>(static_cast<ucontext_t *>(uctx)->uc_mcontext.gregs[REG_RIP]);
		}
#endif
		int n = 0;
		int from = -1;
		for (int i = 0; fault && i < got; i++) {
			if (g_pcs[i] == fault) {
				from = i;
				break;
			}
		}
		if (from < 0 && fault) {
			g_list[n++] = fault;
			from = got;  // the context's address only: the unwinder did not reach the crashing frame
		}
		for (int i = from < 0 ? 0 : from; i < got && n < MAX_FRAMES; i++) {
			g_list[n++] = g_pcs[i];
		}
		for (int i = 0; i < n; i++) {
			g_frames[i].module = "?";
			g_frames[i].offset = uint64_t(reinterpret_cast<uintptr_t>(g_list[i]));
			Dl_info di;
			if (dladdr(g_list[i], &di) && di.dli_fname && di.dli_fbase) {
				const char *base = di.dli_fname;
				for (const char *p = di.dli_fname; *p; p++) {
					if (*p == '/') {
						base = p + 1;
					}
				}
				g_frames[i].module = base;
				g_frames[i].offset = uint64_t(static_cast<const char *>(g_list[i]) - static_cast<const char *>(di.dli_fbase));
			}
		}
		const size_t len = format_note(g_note, sizeof(g_note), g_build, signal_name(sig), g_frames, n);
		const int fd = open(g_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd >= 0) {
			const ssize_t w = write(fd, g_note, len);
			(void)w;
			close(fd);
		}
	}
	for (int i = 0; i < 4; i++) {  // hand the signal on: the handler that was there (Godot's), else the default action
		if (SIGNALS[i] != sig) {
			continue;
		}
		const struct sigaction &p = g_prev[i];
		if ((p.sa_flags & SA_SIGINFO) && p.sa_sigaction) {
			p.sa_sigaction(sig, info, uctx);
			return;
		}
		if (!(p.sa_flags & SA_SIGINFO) && p.sa_handler != SIG_DFL && p.sa_handler != SIG_IGN) {
			p.sa_handler(sig);
			return;
		}
		signal(sig, SIG_DFL);
		raise(sig);
		return;
	}
}

}  // namespace

void arm(const char *path, const char *build) {
	copy(g_path, sizeof(g_path), path);
	copy(g_build, sizeof(g_build), build);
	if (!g_armed) {
		void *warm[1];
		backtrace(warm, 1);  // loads the unwinder now: the first call may allocate, which a signal handler must not
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_sigaction = on_signal;
		sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
		sigemptyset(&sa.sa_mask);
		for (int i = 0; i < 4; i++) {
			sigaction(SIGNALS[i], &sa, &g_prev[i]);
		}
		g_armed = true;
	}
}

}  // namespace dm::crash

#endif
