/*
 * nkwin2 - Win32 window inspection and input helper, for diagnosing what a
 * Windows application is doing inside a Wine prefix.
 *
 * Two things make this necessary rather than just using a screenshot:
 *
 *   * Window text is emitted with every non-ASCII character escaped as
 *     \uXXXX, so CJK and control characters survive a pipe intact.  A
 *     standard MessageBox is unreadable under Wine without this: the font
 *     fallback renders CJK as boxes, so the dialog that said "failed to
 *     load the driver" was invisible until the text was read directly.
 *   * Synthetic input has to come from inside the prefix.  Driving a Wine
 *     window from macOS needs the Accessibility permission that AppleScript
 *     and CGEvent both require, so `autoclick` injects with SendInput
 *     instead.
 *
 * Commands:
 *   list                      enumerate top-level and child windows
 *   dumpall                   same as list
 *   autoclick <x> <y> <secs>  click screen (x,y), then poll for a #32770
 *                             dialog and dump its text and children
 *   clickabs <x> <y>          click screen (x,y) with SendInput
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void esc_print(const wchar_t *s)
{
    for (; *s; s++) {
        unsigned c = (unsigned)*s;
        if (c >= 0x20 && c < 0x7f) putchar((int)c);
        else printf("\\u%04x", c);
    }
}

static void print_w(HWND h, int depth)
{
    wchar_t text[4096] = {0};
    wchar_t cls[256] = {0};
    RECT r = {0,0,0,0};

    GetClassNameW(h, cls, 250);
    GetWindowTextW(h, text, 4000);
    GetWindowRect(h, &r);

    printf("%*s[%p] class=", depth * 2, "", (void *)h);
    esc_print(cls);
    printf(" vis=%d en=%d rect=(%ld,%ld)-(%ld,%ld)\n",
           IsWindowVisible(h), IsWindowEnabled(h), r.left, r.top, r.right, r.bottom);
    printf("%*s  title=\"", depth * 2, "");
    esc_print(text);
    printf("\"\n");
    fflush(stdout);
}

static BOOL CALLBACK child_proc(HWND h, LPARAM lp)
{
    int depth = (int)(INT_PTR)lp;
    print_w(h, depth);
    EnumChildWindows(h, child_proc, (LPARAM)(depth + 1));
    return TRUE;
}

static BOOL CALLBACK top_proc(HWND h, LPARAM lp)
{
    (void)lp;
    print_w(h, 0);
    EnumChildWindows(h, child_proc, (LPARAM)1);
    return TRUE;
}

/* find a top-level dialog (class #32770) that is visible and has a Button child */
static BOOL CALLBACK find_dlg(HWND h, LPARAM lp)
{
    wchar_t cls[64] = {0};
    HWND *out = (HWND *)lp;
    GetClassNameW(h, cls, 60);
    if (wcscmp(cls, L"#32770")) return TRUE;
    if (!IsWindowVisible(h)) return TRUE;
    if (!FindWindowExW(h, NULL, L"Button", NULL)) return TRUE;
    *out = h;
    return FALSE;
}

static HWND find_ace_dialog(void)
{
    HWND d = NULL;
    EnumWindows(find_dlg, (LPARAM)&d);
    return d;
}

static void click_at(int x, int y)
{
    int sw = GetSystemMetrics(SM_CXVIRTUALSCREEN), sh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    int ox = GetSystemMetrics(SM_XVIRTUALSCREEN), oy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    INPUT in[3];
    memset(in, 0, sizeof(in));
    SetCursorPos(x, y);
    Sleep(150);
    in[0].type = INPUT_MOUSE; in[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
    in[0].mi.dx = ((x - ox) * 65535) / (sw > 1 ? sw - 1 : 1);
    in[0].mi.dy = ((y - oy) * 65535) / (sh > 1 ? sh - 1 : 1);
    in[1].type = INPUT_MOUSE; in[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    in[2].type = INPUT_MOUSE; in[2].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(1, &in[0], sizeof(INPUT));
    Sleep(120);
    SendInput(2, &in[1], sizeof(INPUT));
}

int wmain(int argc, wchar_t **argv)
{
    if (argc < 2) {
        printf("usage: nkwin2 list | dumpall | autoclick <x> <y> <secs> |"
               " clickabs <x> <y>\n");
        return 1;
    }

    if (!wcscmp(argv[1], L"list")) {
        EnumWindows(top_proc, 0);
        return 0;
    }

    if (!wcscmp(argv[1], L"dumpall")) {
        EnumWindows(top_proc, 0);
        return 0;
    }

    if (!wcscmp(argv[1], L"clickabs") && argc >= 4) {
        int x = _wtoi(argv[2]), y = _wtoi(argv[3]);

        click_at(x, y);
        printf("clicked (%d,%d)\n", x, y);
        return 0;
    }

    if (!wcscmp(argv[1], L"autoclick") && argc >= 5) {
        int x = _wtoi(argv[2]), y = _wtoi(argv[3]);
        int secs = _wtoi(argv[4]);
        int i;
        HWND d;

        printf("=== clicking (%d,%d) ===\n", x, y);
        fflush(stdout);
        click_at(x, y);

        for (i = 0; i < secs * 5; i++) {
            Sleep(200);
            if ((d = find_ace_dialog())) {
                printf("=== DIALOG FOUND after %d ms ===\n", i * 200);
                print_w(d, 0);
                EnumChildWindows(d, child_proc, (LPARAM)1);
                fflush(stdout);
                return 0;
            }
        }
        printf("=== no dialog found in %d s; dumping all ===\n", secs);
        EnumWindows(top_proc, 0);
        return 3;
    }

    printf("unknown command\n");
    return 1;
}
