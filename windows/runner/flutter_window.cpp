#include "flutter_window.h"

#include <optional>
#include <dwmapi.h>
#include <windowsx.h>
#pragma comment(lib, "dwmapi.lib")

#include "flutter/generated_plugin_registrant.h"

static const int kDragBarHeight = 52;

// ── Child HWND subclass ───────────────────────────────────────────────────────
// Flutter's view HWND sits over the entire client area and consumes all mouse
// messages before they reach the parent's WM_NCHITTEST.  We subclass it so
// that when the cursor is in the drag zone or on a resize edge, we return the
// appropriate non-client hit value — which tells Windows to forward the message
// to the parent frame for drag / resize handling.
static WNDPROC g_origChildProc = nullptr;

static LRESULT CALLBACK ChildSubclassProc(HWND hwnd, UINT msg,
        WPARAM wp, LPARAM lp) noexcept {
if (msg == WM_NCHITTEST) {
HWND parent = GetParent(hwnd);

// First let DWM handle caption-button zones on the parent
LRESULT hit = 0;
if (SUCCEEDED(DwmDefWindowProc(parent, msg, wp, lp, &hit))
&& hit != HTNOWHERE) {
return hit;
}

POINT pt = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
ScreenToClient(hwnd, &pt);

RECT rc;
GetClientRect(hwnd, &rc);

WINDOWPLACEMENT wpn{};
wpn.length = sizeof(wpn);
GetWindowPlacement(parent, &wpn);
bool maximised = (wpn.showCmd == SW_SHOWMAXIMIZED);

int border = GetSystemMetrics(SM_CYFRAME)
             + GetSystemMetrics(SM_CXPADDEDBORDER);

if (!maximised) {
// Resize edges — report to parent
if (pt.x <  border && pt.y <  border)                          return HTTOPLEFT;
if (pt.x >= rc.right-border && pt.y < border)                  return HTTOPRIGHT;
if (pt.x <  border && pt.y >= rc.bottom-border)                return HTBOTTOMLEFT;
if (pt.x >= rc.right-border && pt.y >= rc.bottom-border)       return HTBOTTOMRIGHT;
if (pt.y <  border)                                             return HTTOP;
if (pt.x <  border)                                             return HTLEFT;
if (pt.x >= rc.right-border)                                    return HTRIGHT;
if (pt.y >= rc.bottom-border)                                   return HTBOTTOM;
}

// Drag zone
if (pt.y < kDragBarHeight) return HTCAPTION;

return HTCLIENT;
}

return CallWindowProc(g_origChildProc, hwnd, msg, wp, lp);
}

// ─────────────────────────────────────────────────────────────────────────────

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
        : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
    if (!Win32Window::OnCreate()) {
        return false;
    }

    HWND hwnd = GetHandle();

    // Extend DWM frame so caption buttons render correctly
    MARGINS m = {0, 0, 1, 0};
    DwmExtendFrameIntoClientArea(hwnd, &m);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER);

    RECT frame = GetClientArea();

    flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
            frame.right - frame.left, frame.bottom - frame.top, project_);
    if (!flutter_controller_->engine() || !flutter_controller_->view()) {
        return false;
    }
    RegisterPlugins(flutter_controller_->engine());

    HWND child = flutter_controller_->view()->GetNativeWindow();
    SetChildContent(child);

    // Subclass the Flutter child HWND so it forwards drag-zone and resize-edge
    // hit-tests to the parent frame instead of swallowing them.
    if (child && !g_origChildProc) {
        g_origChildProc = reinterpret_cast<WNDPROC>(
                SetWindowLongPtr(child, GWLP_WNDPROC,
                                 reinterpret_cast<LONG_PTR>(ChildSubclassProc)));
    }

    flutter_controller_->engine()->SetNextFrameCallback([&]() {
        this->Show();
    });

    flutter_controller_->ForceRedraw();
    return true;
}

void FlutterWindow::OnDestroy() {
    if (flutter_controller_) {
        flutter_controller_ = nullptr;
    }
    Win32Window::OnDestroy();
}

LRESULT
        FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
        WPARAM const wparam,
LPARAM const lparam) noexcept {
if (flutter_controller_) {
std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
if (result) {
return *result;
}
}

switch (message) {
case WM_FONTCHANGE:
flutter_controller_->engine()->ReloadSystemFonts();
break;

case WM_NCCALCSIZE: {
if (wparam == FALSE) break;
auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
RECT winRect = params->rgrc[0];
LRESULT res = DefWindowProc(hwnd, WM_NCCALCSIZE, wparam, lparam);
WINDOWPLACEMENT wp{};
wp.length = sizeof(wp);
GetWindowPlacement(hwnd, &wp);
if (wp.showCmd != SW_SHOWMAXIMIZED) {
params->rgrc[0].top = winRect.top;
}
if (flutter_controller_) {
HWND child = flutter_controller_->view()->GetNativeWindow();
if (child) {
RECT& r = params->rgrc[0];
SetWindowPos(child, nullptr, 0, 0,
r.right - r.left, r.bottom - r.top,
SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}
}
return res;
}

case WM_NCHITTEST: {
LRESULT hit = 0;
if (SUCCEEDED(DwmDefWindowProc(hwnd, message, wparam, lparam, &hit))
&& hit != HTNOWHERE) {
return hit;
}
POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
ScreenToClient(hwnd, &pt);
RECT rc;
GetClientRect(hwnd, &rc);
WINDOWPLACEMENT wp{};
wp.length = sizeof(wp);
GetWindowPlacement(hwnd, &wp);
bool maximised = (wp.showCmd == SW_SHOWMAXIMIZED);
int border = GetSystemMetrics(SM_CYFRAME)
             + GetSystemMetrics(SM_CXPADDEDBORDER);
if (!maximised) {
if (pt.x <  border && pt.y <  border)                        return HTTOPLEFT;
if (pt.x >= rc.right-border && pt.y < border)                return HTTOPRIGHT;
if (pt.x <  border && pt.y >= rc.bottom-border)              return HTBOTTOMLEFT;
if (pt.x >= rc.right-border && pt.y >= rc.bottom-border)     return HTBOTTOMRIGHT;
if (pt.y <  border)                                           return HTTOP;
if (pt.x <  border)                                           return HTLEFT;
if (pt.x >= rc.right-border)                                  return HTRIGHT;
if (pt.y >= rc.bottom-border)                                 return HTBOTTOM;
}
if (pt.y < kDragBarHeight) return HTCAPTION;
return HTCLIENT;
}
}

return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}