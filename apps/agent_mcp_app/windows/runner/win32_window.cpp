#include "win32_window.h"

#include <algorithm>
using std::max;
using std::min;

#include <dwmapi.h>
#include <flutter_windows.h>
#include <gdiplus.h>
#include <wchar.h>

#include "resource.h"

namespace {

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif

#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif

constexpr int kDwmCornerDoNotRound = 1;
constexpr int kDwmCornerRound = 2;
constexpr int kDwmBackdropNone = 1;        // DWMSBT_NONE
constexpr int kDwmBackdropMica = 2;        // DWMSBT_MAINWINDOW
constexpr int kDwmBackdropTransient = 3;   // DWMSBT_TRANSIENTWINDOW

constexpr UINT kWmTrayCallback = WM_USER + 20;
constexpr UINT_PTR kTrayIdOpen = 1001;
constexpr UINT_PTR kTrayIdStart = 1002;
constexpr UINT_PTR kTrayIdStop = 1003;
constexpr UINT_PTR kTrayIdQuit = 1004;

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kTrayFlyoutClassName[] = L"AGENT_MCP_TRAY_FLYOUT";

constexpr int kFlyoutLogicalW = 248;
constexpr int kFlyoutLogicalH = 266;
constexpr int kFlyoutItemCount = 5;

void EnsureGdiPlusInitialized() {
  static ULONG_PTR token = 0;
  if (token == 0) {
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&token, &input, nullptr);
  }
}

void AddRoundedRectPath(Gdiplus::GraphicsPath& path,
                        const Gdiplus::RectF& r,
                        float radius) {
  const float d = min(radius * 2.0f, min(r.Width, r.Height));
  if (d <= 0.5f) {
    path.AddRectangle(r);
    return;
  }
  path.AddArc(r.X, r.Y, d, d, 180.0f, 90.0f);
  path.AddArc(r.GetRight() - d, r.Y, d, d, 270.0f, 90.0f);
  path.AddArc(r.GetRight() - d, r.GetBottom() - d, d, d, 0.0f, 90.0f);
  path.AddArc(r.X, r.GetBottom() - d, d, d, 90.0f, 90.0f);
  path.CloseFigure();
}

Gdiplus::RectF FlyoutItemRect(int index, float s) {
  // Items 0..3 sit at y = 74 + index * 35; Item 4 (Quit) sits below bottom divider at y = 224.
  const float y = (index < 4) ? (74.0f + index * 35.0f) : 224.0f;
  return Gdiplus::RectF(8.0f * s, y * s, (kFlyoutLogicalW - 16.0f) * s,
                        33.0f * s);
}

constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

static int g_active_window_count = 0;

using EnableNonClientDpiScalingFn = BOOL(WINAPI*)(HWND hwnd);
using AdjustWindowRectExForDpiFn = BOOL(WINAPI*)(LPRECT lpRect,
                                                 DWORD dwStyle,
                                                 BOOL bMenu,
                                                 DWORD dwExStyle,
                                                 UINT dpi);
using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);

int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

DWORD GetWindowsBuildNumber() {
  static DWORD cached_build = 0;
  if (cached_build != 0) {
    return cached_build;
  }
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll != nullptr) {
    auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(
        GetProcAddress(ntdll, "RtlGetVersion"));
    if (rtl_get_version != nullptr) {
      OSVERSIONINFOW info{};
      info.dwOSVersionInfoSize = sizeof(info);
      if (rtl_get_version(&info) == 0) {
        cached_build = info.dwBuildNumber;
        return cached_build;
      }
    }
  }
  cached_build = 19041;
  return cached_build;
}

bool IsWindows11OrGreater() {
  return GetWindowsBuildNumber() >= 22000;
}

bool IsWindows11BackdropAvailable() {
  return GetWindowsBuildNumber() >= 22621;
}

RECT ComputeFrameInsets(HWND hwnd, DWORD style, DWORD ex_style) {
  RECT frame{0, 0, 0, 0};
  static AdjustWindowRectExForDpiFn adjust_for_dpi = []() {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 == nullptr) {
      return static_cast<AdjustWindowRectExForDpiFn>(nullptr);
    }
    return reinterpret_cast<AdjustWindowRectExForDpiFn>(
        GetProcAddress(user32, "AdjustWindowRectExForDpi"));
  }();

  if (adjust_for_dpi != nullptr && hwnd != nullptr) {
    UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
    adjust_for_dpi(&frame, style, FALSE, ex_style, dpi);
  } else {
    AdjustWindowRectEx(&frame, style, FALSE, ex_style);
  }
  return frame;
}

void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScalingFn>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

bool QuerySystemDarkMode() {
  DWORD light_mode = 1;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValueW(
      HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
      kGetPreferredBrightnessRegValue, RRF_RT_REG_DWORD, nullptr, &light_mode,
      &light_mode_size);
  return (result == ERROR_SUCCESS && light_mode == 0);
}

}  // namespace

class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  const wchar_t* GetWindowClass();
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;
  static WindowClassRegistrar* instance_;
  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = nullptr;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
  solid_dark_brush_ = CreateSolidBrush(RGB(0x14, 0x14, 0x13));
  solid_light_brush_ = CreateSolidBrush(RGB(0xF5, 0xF4, 0xED));
  taskbar_created_msg_ = RegisterWindowMessageW(L"TaskbarCreated");
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
  if (solid_dark_brush_ != nullptr) {
    DeleteObject(solid_dark_brush_);
    solid_dark_brush_ = nullptr;
  }
  if (solid_light_brush_ != nullptr) {
    DeleteObject(solid_light_brush_);
    solid_light_brush_ = nullptr;
  }
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  is_dark_mode_ = QuerySystemDarkMode();

  HWND window = CreateWindow(
      window_class, title.c_str(),
      WS_OVERLAPPEDWINDOW | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX |
          WS_MAXIMIZEBOX,
      Scale(static_cast<int>(origin.x), scale_factor),
      Scale(static_cast<int>(origin.y), scale_factor),
      Scale(static_cast<int>(size.width), scale_factor),
      Scale(static_cast<int>(size.height), scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  ApplyFramelessStyle();
  SetDarkTheme(is_dark_mode_);
  InitTrayIcon(title);

  return OnCreate();
}

void Win32Window::InitTrayIcon(const std::wstring& tooltip) {
  if (!window_handle_ || tray_added_) return;

  ZeroMemory(&tray_nid_, sizeof(tray_nid_));
  tray_nid_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_nid_.hWnd = window_handle_;
  tray_nid_.uID = 1;
  tray_nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_nid_.uCallbackMessage = kWmTrayCallback;

  HINSTANCE hInst = GetModuleHandleW(nullptr);
  HICON hIcon = static_cast<HICON>(LoadImageW(
      hInst, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_SHARED));
  if (hIcon == nullptr) {
    hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(IDI_APP_ICON));
  }
  if (hIcon == nullptr) {
    hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  }
  tray_nid_.hIcon = hIcon;

  wcsncpy_s(tray_nid_.szTip, tooltip.c_str(), _TRUNCATE);
  tray_added_ = (Shell_NotifyIconW(NIM_ADD, &tray_nid_) != FALSE);
}

void Win32Window::SetTrayTooltip(const std::wstring& tooltip) {
  if (!window_handle_) return;
  if (!tray_added_) {
    InitTrayIcon(tooltip);
    return;
  }
  wcsncpy_s(tray_nid_.szTip, tooltip.c_str(), _TRUNCATE);
  tray_nid_.uFlags = NIF_TIP;
  Shell_NotifyIconW(NIM_MODIFY, &tray_nid_);
  tray_nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
}

void Win32Window::RemoveTrayIcon() {
  DestroyTrayFlyout();
  if (tray_added_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_nid_);
    tray_added_ = false;
  }
}

void Win32Window::SetTrayState(const std::wstring& server_name,
                               bool is_running,
                               int port,
                               bool is_dark) {
  if (!server_name.empty()) {
    tray_server_name_ = server_name;
  }
  tray_service_running_ = is_running;
  if (port > 0) {
    tray_port_ = port;
  }
  is_dark_mode_ = is_dark;
  if (tray_flyout_hwnd_ && IsWindow(tray_flyout_hwnd_)) {
    BOOL enable_dark = is_dark_mode_ ? TRUE : FALSE;
    DwmSetWindowAttribute(tray_flyout_hwnd_, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark, sizeof(enable_dark));
    if (IsWindows11OrGreater()) {
      COLORREF border_col =
          is_dark_mode_ ? RGB(0x36, 0x34, 0x2F) : RGB(0xDC, 0xD8, 0xCE);
      DwmSetWindowAttribute(tray_flyout_hwnd_, DWMWA_BORDER_COLOR, &border_col,
                            sizeof(border_col));
    }
    InvalidateRect(tray_flyout_hwnd_, nullptr, FALSE);
  }
}

void Win32Window::DestroyTrayFlyout() {
  tray_hover_index_ = -1;
  tray_tracking_mouse_ = false;
  if (tray_flyout_hwnd_ != nullptr) {
    HWND hwnd = tray_flyout_hwnd_;
    tray_flyout_hwnd_ = nullptr;
    if (IsWindow(hwnd)) {
      DestroyWindow(hwnd);
    }
  }
}

int Win32Window::HitTestTrayFlyout(HWND hwnd, int x, int y) const {
  const UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
  const float s = (dpi > 0) ? (dpi / 96.0f) : 1.0f;
  const Gdiplus::PointF pt(static_cast<float>(x), static_cast<float>(y));
  for (int i = 0; i < kFlyoutItemCount; ++i) {
    if (FlyoutItemRect(i, s).Contains(pt)) {
      return i;
    }
  }
  return -1;
}

void Win32Window::TriggerTrayFlyoutItem(int index) {
  DestroyTrayFlyout();
  switch (index) {
    case 0:
      ShowAndFocus();
      OnTrayAction("open");
      break;
    case 1:
      OnTrayAction("open_web");
      break;
    case 2:
      OnTrayAction(tray_service_running_ ? "stop" : "start");
      break;
    case 3:
      OnTrayAction("restart");
      break;
    case 4:
      OnTrayAction("quit");
      break;
    default:
      break;
  }
}

void Win32Window::PaintTrayFlyout(HWND hwnd, HDC hdc) {
  EnsureGdiPlusInitialized();
  RECT rc{};
  GetClientRect(hwnd, &rc);
  const int w = rc.right - rc.left;
  const int h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) return;

  const UINT dpi = FlutterDesktopGetDpiForHWND(hwnd);
  const float s = (dpi > 0) ? (dpi / 96.0f) : 1.0f;
  const bool dark = is_dark_mode_;

  Gdiplus::Bitmap backbuf(w, h, PixelFormat32bppARGB);
  Gdiplus::Graphics g(&backbuf);
  g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
  g.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

  // Anthropic Warm Editorial Palette (Warm Paper #FAF9F5 / Deep Slate #1E1D1B)
  const Gdiplus::Color bgCol =
      dark ? Gdiplus::Color(255, 0x1E, 0x1D, 0x1B)
           : Gdiplus::Color(255, 0xFA, 0xF9, 0xF5);
  const Gdiplus::Color inkCol =
      dark ? Gdiplus::Color(255, 0xF3, 0xF1, 0xEA)
           : Gdiplus::Color(255, 0x19, 0x18, 0x16);
  const Gdiplus::Color iconCol =
      dark ? Gdiplus::Color(255, 0xB8, 0xB3, 0xA6)
           : Gdiplus::Color(255, 0x66, 0x62, 0x59);
  const Gdiplus::Color hairlineCol =
      dark ? Gdiplus::Color(255, 0x31, 0x2F, 0x2B)
           : Gdiplus::Color(255, 0xE5, 0xE1, 0xD7);
  const Gdiplus::Color hoverFill =
      dark ? Gdiplus::Color(255, 0x2B, 0x29, 0x25)
           : Gdiplus::Color(255, 0xEF, 0xEC, 0xE3);
  const Gdiplus::Color clayCol(255, 0xD9, 0x77, 0x57);
  const Gdiplus::Color sageCol =
      dark ? Gdiplus::Color(255, 0x5E, 0xB8, 0x8A)
           : Gdiplus::Color(255, 0x2E, 0x7D, 0x5B);
  const Gdiplus::Color dangerTextCol =
      dark ? Gdiplus::Color(255, 0xF0, 0x74, 0x74)
           : Gdiplus::Color(255, 0xC6, 0x42, 0x42);
  const Gdiplus::Color dangerHoverFill =
      dark ? Gdiplus::Color(255, 0x3A, 0x20, 0x20)
           : Gdiplus::Color(255, 0xFC, 0xE9, 0xE9);

  g.Clear(bgCol);

  // Subtle 1px inner border on Windows 10 where DWMWA_BORDER_COLOR isn't present
  if (!IsWindows11OrGreater()) {
    Gdiplus::GraphicsPath borderPath;
    AddRoundedRectPath(
        borderPath,
        Gdiplus::RectF(0.5f, 0.5f, w - 1.0f, h - 1.0f),
        10.0f * s);
    Gdiplus::Pen borderPen(hairlineCol, 1.0f);
    g.DrawPath(&borderPen, &borderPath);
  }

  // Font resolution: Segoe UI Variable / Microsoft YaHei UI
  Gdiplus::FontFamily fontFamily(L"Microsoft YaHei UI");
  const Gdiplus::FontFamily* fam =
      fontFamily.IsAvailable() ? &fontFamily : Gdiplus::FontFamily::GenericSansSerif();
  Gdiplus::Font titleFont(fam, 13.0f * s, Gdiplus::FontStyleBold,
                          Gdiplus::UnitPixel);
  Gdiplus::Font itemFont(fam, 12.8f * s, Gdiplus::FontStyleRegular,
                         Gdiplus::UnitPixel);
  Gdiplus::Font itemActiveFont(fam, 12.8f * s, Gdiplus::FontStyleBold,
                               Gdiplus::UnitPixel);
  Gdiplus::Font pillFont(fam, 11.2f * s, Gdiplus::FontStyleBold,
                         Gdiplus::UnitPixel);

  Gdiplus::StringFormat leftFmt;
  leftFmt.SetAlignment(Gdiplus::StringAlignmentNear);
  leftFmt.SetLineAlignment(Gdiplus::StringAlignmentCenter);
  leftFmt.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  leftFmt.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);

  // 1. Header Card: Sparkle Badge + Server Name + Live Status Pill
  {
    Gdiplus::RectF badgeRect(14.0f * s, 14.0f * s, 36.0f * s, 36.0f * s);
    Gdiplus::GraphicsPath badgePath;
    AddRoundedRectPath(badgePath, badgeRect, 10.0f * s);
    Gdiplus::SolidBrush badgeFill(
        Gdiplus::Color(dark ? 42 : 30, 0xD9, 0x77, 0x57));
    g.FillPath(&badgeFill, &badgePath);

    // 4-point Anthropic Terracotta Sparkle vector
    const float cx = badgeRect.X + badgeRect.Width * 0.5f;
    const float cy = badgeRect.Y + badgeRect.Height * 0.5f;
    const float rOut = 8.5f * s;
    const float rIn = 2.6f * s;
    Gdiplus::PointF star[8] = {
        {cx, cy - rOut}, {cx + rIn, cy - rIn},
        {cx + rOut, cy}, {cx + rIn, cy + rIn},
        {cx, cy + rOut}, {cx - rIn, cy + rIn},
        {cx - rOut, cy}, {cx - rIn, cy - rIn},
    };
    Gdiplus::SolidBrush clayBrush(clayCol);
    g.FillPolygon(&clayBrush, star, 8);

    // Server Name
    Gdiplus::SolidBrush inkBrush(inkCol);
    Gdiplus::RectF titleRect(58.0f * s, 13.0f * s,
                             (kFlyoutLogicalW - 70.0f) * s, 19.0f * s);
    g.DrawString(tray_server_name_.c_str(), -1, &titleFont, titleRect, &leftFmt,
                 &inkBrush);

    // Status Subtitle Pill
    std::wstring statusText;
    if (tray_service_running_) {
      wchar_t buf[64]{};
      swprintf_s(buf, L"\u8fd0\u884c\u4e2d \u00b7 :%d", tray_port_);
      statusText = buf;
    } else {
      statusText = L"\u670d\u52a1\u5df2\u505c\u6b62";
    }

    Gdiplus::RectF measured;
    g.MeasureString(statusText.c_str(), -1, &pillFont,
                    Gdiplus::PointF(0.0f, 0.0f), &measured);
    const float pillW = min((kFlyoutLogicalW - 72.0f) * s,
                            measured.Width + 22.0f * s);
    Gdiplus::RectF pillRect(58.0f * s, 34.0f * s, pillW, 19.0f * s);
    Gdiplus::GraphicsPath pillPath;
    AddRoundedRectPath(pillPath, pillRect, 9.5f * s);
    Gdiplus::SolidBrush pillBg(
        tray_service_running_
            ? (dark ? Gdiplus::Color(40, 0x5E, 0xB8, 0x8A)
                    : Gdiplus::Color(28, 0x2E, 0x7D, 0x5B))
            : (dark ? Gdiplus::Color(255, 0x2B, 0x29, 0x25)
                    : Gdiplus::Color(255, 0xED, 0xEA, 0xE0)));
    g.FillPath(&pillBg, &pillPath);

    // Dot inside pill
    const Gdiplus::Color dotCol = tray_service_running_ ? sageCol : iconCol;
    Gdiplus::SolidBrush dotBrush(dotCol);
    g.FillEllipse(&dotBrush, pillRect.X + 7.0f * s,
                  pillRect.Y + (pillRect.Height - 6.0f * s) * 0.5f,
                  6.0f * s, 6.0f * s);

    Gdiplus::RectF pillTextRect(pillRect.X + 16.5f * s, pillRect.Y,
                                pillRect.Width - 19.0f * s, pillRect.Height);
    g.DrawString(statusText.c_str(), -1, &pillFont, pillTextRect, &leftFmt,
                 &dotBrush);
  }

  // 2. Top Divider
  Gdiplus::Pen divPen(hairlineCol, 1.0f);
  g.DrawLine(&divPen, 12.0f * s, 66.0f * s, (kFlyoutLogicalW - 12.0f) * s,
             66.0f * s);

  // 3. Menu Items (0..4)
  const wchar_t* labels[kFlyoutItemCount] = {
      L"\u6253\u5f00\u4e3b\u63a7\u5236\u53f0",
      L"\u6d4f\u89c8\u5668\u6253\u5f00\u9762\u677f",
      tray_service_running_ ? L"\u505c\u6b62 MCP \u670d\u52a1"
                            : L"\u542f\u52a8 MCP \u670d\u52a1",
      L"\u91cd\u542f MCP \u670d\u52a1",
      L"\u5b8c\u5168\u9000\u51fa\u5e94\u7528",
  };

  for (int i = 0; i < kFlyoutItemCount; ++i) {
    const Gdiplus::RectF row = FlyoutItemRect(i, s);
    const bool hovered = (tray_hover_index_ == i);
    const bool isDanger = (i == 4);
    const bool isStartAccent = (i == 2 && !tray_service_running_);

    if (hovered) {
      Gdiplus::GraphicsPath hoverPath;
      AddRoundedRectPath(hoverPath, row, 8.5f * s);
      Gdiplus::SolidBrush hBrush(isDanger ? dangerHoverFill : hoverFill);
      g.FillPath(&hBrush, &hoverPath);
    }

    const Gdiplus::Color curTextCol =
        isDanger ? (hovered ? dangerTextCol : inkCol)
                 : (isStartAccent ? clayCol : inkCol);
    const Gdiplus::Color curIconCol =
        isDanger ? dangerTextCol
                 : (isStartAccent ? clayCol : (hovered ? inkCol : iconCol));

    // Crisp Vector Icon (15x15 box centered vertically at x = row.X + 11*s)
    const float ix = row.X + 11.0f * s;
    const float iy = row.Y + (row.Height - 15.0f * s) * 0.5f;
    const float iw = 15.0f * s;
    Gdiplus::Pen iconPen(curIconCol, 1.55f * s);
    iconPen.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound,
                       Gdiplus::DashCapRound);
    iconPen.SetLineJoin(Gdiplus::LineJoinRound);

    if (i == 0) {
      // Console window layout icon
      Gdiplus::GraphicsPath wp;
      AddRoundedRectPath(
          wp, Gdiplus::RectF(ix + 0.5f * s, iy + 1.5f * s, iw - 1.0f * s,
                             iw - 3.0f * s),
          3.0f * s);
      g.DrawPath(&iconPen, &wp);
      g.DrawLine(&iconPen, ix + 5.2f * s, iy + 1.8f * s, ix + 5.2f * s,
                 iy + iw - 1.8f * s);
    } else if (i == 1) {
      // Browser globe icon
      g.DrawEllipse(&iconPen, ix + 1.0f * s, iy + 1.0f * s, iw - 2.0f * s,
                    iw - 2.0f * s);
      g.DrawEllipse(&iconPen, ix + 4.3f * s, iy + 1.0f * s, iw - 8.6f * s,
                    iw - 2.0f * s);
      g.DrawLine(&iconPen, ix + 1.4f * s, iy + iw * 0.5f, ix + iw - 1.4f * s,
                 iy + iw * 0.5f);
    } else if (i == 2) {
      if (tray_service_running_) {
        // Stop rounded square
        Gdiplus::GraphicsPath sp;
        AddRoundedRectPath(
            sp, Gdiplus::RectF(ix + 2.5f * s, iy + 2.5f * s, iw - 5.0f * s,
                               iw - 5.0f * s),
            2.6f * s);
        g.DrawPath(&iconPen, &sp);
      } else {
        // Play triangle
        Gdiplus::PointF tri[3] = {
            {ix + 3.2f * s, iy + 2.0f * s},
            {ix + iw - 2.0f * s, iy + iw * 0.5f},
            {ix + 3.2f * s, iy + iw - 2.0f * s},
        };
        Gdiplus::SolidBrush playBrush(clayCol);
        g.FillPolygon(&playBrush, tri, 3);
      }
    } else if (i == 3) {
      // Circular restart arc + arrow tip
      g.DrawArc(&iconPen, ix + 1.5f * s, iy + 1.5f * s, iw - 3.0f * s,
                iw - 3.0f * s, 35.0f, 285.0f);
      g.DrawLine(&iconPen, ix + iw - 1.8f * s, iy + 2.0f * s,
                 ix + iw - 1.8f * s, iy + 5.8f * s);
      g.DrawLine(&iconPen, ix + iw - 5.6f * s, iy + 5.8f * s,
                 ix + iw - 1.8f * s, iy + 5.8f * s);
    } else if (i == 4) {
      // Power button icon
      g.DrawArc(&iconPen, ix + 1.8f * s, iy + 2.5f * s, iw - 3.6f * s,
                iw - 3.6f * s, 300.0f, 300.0f);
      g.DrawLine(&iconPen, ix + iw * 0.5f, iy + 1.2f * s, ix + iw * 0.5f,
                 iy + 7.5f * s);
    }

    Gdiplus::SolidBrush textBrush(curTextCol);
    Gdiplus::RectF textRect(row.X + 35.0f * s, row.Y, row.Width - 44.0f * s,
                            row.Height);
    g.DrawString(labels[i], -1, (i == 0) ? &itemActiveFont : &itemFont,
                 textRect, &leftFmt, &textBrush);
  }

  // 4. Bottom Divider above Quit
  g.DrawLine(&divPen, 12.0f * s, 217.0f * s, (kFlyoutLogicalW - 12.0f) * s,
             217.0f * s);

  // Blit offscreen buffer in one atomic pass
  Gdiplus::Graphics screen(hdc);
  screen.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
  screen.DrawImage(&backbuf, 0, 0, w, h);
}

LRESULT CALLBACK Win32Window::TrayFlyoutWndProc(HWND const window,
                                                UINT const message,
                                                WPARAM const wparam,
                                                LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    EnableFullDpiSupportIfAvailable(window);
    return TRUE;
  }

  auto* self = reinterpret_cast<Win32Window*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (!self) {
    return DefWindowProcW(window, message, wparam, lparam);
  }

  switch (message) {
    case WM_ERASEBKGND:
      return 1;

    case WM_PAINT: {
      PAINTSTRUCT ps{};
      HDC hdc = BeginPaint(window, &ps);
      self->PaintTrayFlyout(window, hdc);
      EndPaint(window, &ps);
      return 0;
    }

    case WM_MOUSEMOVE: {
      if (!self->tray_tracking_mouse_) {
        TRACKMOUSEEVENT tme{};
        tme.cbSize = sizeof(TRACKMOUSEEVENT);
        tme.dwFlags = TME_LEAVE;
        tme.hwndTrack = window;
        TrackMouseEvent(&tme);
        self->tray_tracking_mouse_ = true;
      }
      const int hit = self->HitTestTrayFlyout(
          window, static_cast<int>(static_cast<short>(LOWORD(lparam))),
          static_cast<int>(static_cast<short>(HIWORD(lparam))));
      if (hit != self->tray_hover_index_) {
        self->tray_hover_index_ = hit;
        InvalidateRect(window, nullptr, FALSE);
      }
      SetCursor(LoadCursorW(nullptr, hit >= 0 ? IDC_HAND : IDC_ARROW));
      return 0;
    }

    case WM_MOUSELEAVE: {
      self->tray_tracking_mouse_ = false;
      if (self->tray_hover_index_ != -1) {
        self->tray_hover_index_ = -1;
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    }

    case WM_SETCURSOR: {
      if (LOWORD(lparam) == HTCLIENT) {
        SetCursor(LoadCursorW(
            nullptr, self->tray_hover_index_ >= 0 ? IDC_HAND : IDC_ARROW));
        return TRUE;
      }
      break;
    }

    case WM_LBUTTONUP: {
      const int hit = self->HitTestTrayFlyout(
          window, static_cast<int>(static_cast<short>(LOWORD(lparam))),
          static_cast<int>(static_cast<short>(HIWORD(lparam))));
      if (hit >= 0) {
        self->TriggerTrayFlyoutItem(hit);
      }
      return 0;
    }

    case WM_KEYDOWN: {
      if (wparam == VK_ESCAPE) {
        self->DestroyTrayFlyout();
        return 0;
      }
      if (wparam == VK_DOWN) {
        self->tray_hover_index_ =
            (self->tray_hover_index_ + 1) % kFlyoutItemCount;
        InvalidateRect(window, nullptr, FALSE);
        return 0;
      }
      if (wparam == VK_UP) {
        self->tray_hover_index_ =
            (self->tray_hover_index_ <= 0) ? (kFlyoutItemCount - 1)
                                           : (self->tray_hover_index_ - 1);
        InvalidateRect(window, nullptr, FALSE);
        return 0;
      }
      if ((wparam == VK_RETURN || wparam == VK_SPACE) &&
          self->tray_hover_index_ >= 0) {
        self->TriggerTrayFlyoutItem(self->tray_hover_index_);
        return 0;
      }
      break;
    }

    case WM_ACTIVATE: {
      if (LOWORD(wparam) == WA_INACTIVE) {
        self->DestroyTrayFlyout();
        return 0;
      }
      break;
    }

    case WM_KILLFOCUS: {
      self->DestroyTrayFlyout();
      return 0;
    }

    case WM_DESTROY: {
      if (self->tray_flyout_hwnd_ == window) {
        self->tray_flyout_hwnd_ = nullptr;
      }
      return 0;
    }
  }

  return DefWindowProcW(window, message, wparam, lparam);
}

void Win32Window::ShowTrayContextMenu() {
  if (!window_handle_) return;
  EnsureGdiPlusInitialized();
  DestroyTrayFlyout();

  static bool flyout_class_registered = false;
  HINSTANCE hInst = GetModuleHandleW(nullptr);
  if (!flyout_class_registered) {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
    wc.lpfnWndProc = Win32Window::TrayFlyoutWndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    wc.lpszClassName = kTrayFlyoutClassName;
    if (RegisterClassExW(&wc) != 0 ||
        GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
      flyout_class_registered = true;
    }
  }

  POINT pt{};
  GetCursorPos(&pt);
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(mon);
  if (dpi == 0) dpi = 96;
  const double scale = dpi / 96.0;

  const int flyW = Scale(kFlyoutLogicalW, scale);
  const int flyH = Scale(kFlyoutLogicalH, scale);
  const int margin = Scale(8, scale);

  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfoW(mon, &mi);
  const RECT& work = mi.rcWork;

  // Position cleanly near cursor while respecting taskbar & work area edges
  int x = pt.x - flyW / 2;
  int y = pt.y - flyH - margin;
  if (y < work.top + margin) {
    y = pt.y + margin;
  }
  if (x + flyW > work.right - margin) {
    x = work.right - margin - flyW;
  }
  if (x < work.left + margin) {
    x = work.left + margin;
  }
  if (y + flyH > work.bottom - margin) {
    y = work.bottom - margin - flyH;
  }

  HWND flyout = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kTrayFlyoutClassName, L"", WS_POPUP, x,
      y, flyW, flyH, nullptr, nullptr, hInst, this);
  if (!flyout) return;

  tray_flyout_hwnd_ = flyout;
  tray_hover_index_ = -1;

  BOOL enable_dark = is_dark_mode_ ? TRUE : FALSE;
  DwmSetWindowAttribute(flyout, DWMWA_USE_IMMERSIVE_DARK_MODE, &enable_dark,
                        sizeof(enable_dark));
  if (IsWindows11OrGreater()) {
    const int round_pref = kDwmCornerRound;
    DwmSetWindowAttribute(flyout, DWMWA_WINDOW_CORNER_PREFERENCE, &round_pref,
                          sizeof(round_pref));
    COLORREF border_col =
        is_dark_mode_ ? RGB(0x36, 0x34, 0x2F) : RGB(0xDC, 0xD8, 0xCE);
    DwmSetWindowAttribute(flyout, DWMWA_BORDER_COLOR, &border_col,
                          sizeof(border_col));
    if (IsWindows11BackdropAvailable()) {
      const int transient_backdrop = kDwmBackdropTransient;
      DwmSetWindowAttribute(flyout, DWMWA_SYSTEMBACKDROP_TYPE,
                            &transient_backdrop, sizeof(transient_backdrop));
    }
  } else {
    const int rgnRadius = Scale(16, scale);
    HRGN rgn = CreateRoundRectRgn(0, 0, flyW + 1, flyH + 1, rgnRadius, rgnRadius);
    SetWindowRgn(flyout, rgn, FALSE);
  }

  ShowWindow(flyout, SW_SHOW);
  SetForegroundWindow(flyout);
  SetFocus(flyout);
  UpdateWindow(flyout);
}

bool Win32Window::IsBackdropSupported() const {
  return IsWindows11BackdropAvailable();
}

bool Win32Window::IsBackdropEffectEnabled() const {
  return backdrop_enabled_ && IsWindows11BackdropAvailable();
}

void Win32Window::SetBackdropEffect(bool enabled) {
  const bool next = enabled && IsWindows11BackdropAvailable();
  if (backdrop_enabled_ == next && window_handle_ == nullptr) {
    return;
  }
  backdrop_enabled_ = next;
  if (window_handle_) {
    ApplyFramelessStyle();
    InvalidateRect(window_handle_, nullptr, TRUE);
    OnWindowStateChanged();
  }
}

void Win32Window::ApplyFramelessStyle() {
  if (!window_handle_) return;

  LONG_PTR style = GetWindowLongPtrW(window_handle_, GWL_STYLE);
  const bool use_mica = IsBackdropEffectEnabled();
  if (use_mica) {
    // Strip WS_SYSMENU while keeping WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
    // WS_MAXIMIZEBOX so DWM never paints duplicate native caption glyphs over Mica,
    // while Aero Snap & Win+Arrow shortcuts continue working natively.
    if ((style & WS_SYSMENU) != 0) {
      SetWindowLongPtrW(window_handle_, GWL_STYLE, style & ~WS_SYSMENU);
    }
  } else {
    if ((style & WS_SYSMENU) == 0) {
      SetWindowLongPtrW(window_handle_, GWL_STYLE, style | WS_SYSMENU);
    }
  }

  if (IsWindows11BackdropAvailable()) {
    const int backdrop_type = use_mica ? kDwmBackdropMica : kDwmBackdropNone;
    DwmSetWindowAttribute(window_handle_, DWMWA_SYSTEMBACKDROP_TYPE,
                          &backdrop_type, sizeof(backdrop_type));
  }

  MARGINS margins{0, 0, 0, 0};
  if (use_mica) {
    margins = {-1, -1, -1, -1};
  } else if (!IsWindows11OrGreater()) {
    const RECT frame =
        ComputeFrameInsets(window_handle_, WS_OVERLAPPEDWINDOW, 0);
    margins.cyTopHeight = -frame.top;
  }
  DwmExtendFrameIntoClientArea(window_handle_, &margins);
  UpdateCornerPreference();

  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_NOSIZE |
                   SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void Win32Window::UpdateCornerPreference() {
  if (!window_handle_ || !IsWindows11OrGreater()) return;
  const int pref = IsMaximized() ? kDwmCornerDoNotRound : kDwmCornerRound;
  DwmSetWindowAttribute(window_handle_, DWMWA_WINDOW_CORNER_PREFERENCE, &pref,
                        sizeof(pref));
}

int Win32Window::TopBorderHeight() const {
  if (!window_handle_ || IsWindows11OrGreater() || IsMaximized()) {
    return 0;
  }
  const LONG_PTR style = GetWindowLongPtr(window_handle_, GWL_STYLE);
  return (style & WS_THICKFRAME) != 0 ? 1 : 0;
}

void Win32Window::PlaceChildContent() {
  if (!window_handle_ || !child_content_ || IsIconic(window_handle_)) {
    return;
  }
  RECT client = GetClientArea();
  const int border = TopBorderHeight();
  const int width = client.right - client.left;
  const int height = (client.bottom - client.top - border) > 0
                         ? (client.bottom - client.top - border)
                         : 0;
  MoveWindow(child_content_, 0, border, width, height, TRUE);
}

void Win32Window::SetDarkTheme(bool is_dark) {
  is_dark_mode_ = is_dark;
  if (!window_handle_) return;

  BOOL enable_dark = is_dark ? TRUE : FALSE;
  DwmSetWindowAttribute(window_handle_, DWMWA_USE_IMMERSIVE_DARK_MODE,
                        &enable_dark, sizeof(enable_dark));

  if (IsWindows11OrGreater()) {
    COLORREF border_col =
        is_dark ? RGB(0x2E, 0x2D, 0x2A) : RGB(0xDA, 0xD7, 0xCC);
    DwmSetWindowAttribute(window_handle_, DWMWA_BORDER_COLOR, &border_col,
                          sizeof(border_col));
  }
  if (!IsBackdropEffectEnabled()) {
    InvalidateRect(window_handle_, nullptr, TRUE);
  }
}

bool Win32Window::IsMaximized() const {
  return window_handle_ != nullptr && IsZoomed(window_handle_) != FALSE;
}

bool Win32Window::IsAlwaysOnTop() const {
  if (window_handle_ == nullptr) return false;
  const LONG_PTR ex = GetWindowLongPtr(window_handle_, GWL_EXSTYLE);
  return (ex & WS_EX_TOPMOST) != 0;
}

void Win32Window::StartDragging() {
  if (!window_handle_) return;
  ReleaseCapture();
  SendMessageW(window_handle_, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
}

void Win32Window::Minimize() {
  if (!window_handle_) return;
  ShowWindow(window_handle_, SW_MINIMIZE);
}

void Win32Window::ToggleMaximize() {
  if (!window_handle_) return;
  ShowWindow(window_handle_, IsMaximized() ? SW_RESTORE : SW_MAXIMIZE);
}

void Win32Window::SetAlwaysOnTop(bool topmost) {
  if (!window_handle_) return;
  SetWindowPos(window_handle_, topmost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0,
               0, SWP_NOMOVE | SWP_NOSIZE);
  OnWindowStateChanged();
}

void Win32Window::HideToTray() {
  if (!window_handle_) return;
  ShowWindow(window_handle_, SW_HIDE);
}

void Win32Window::ShowAndFocus() {
  if (!window_handle_) return;
  if (IsIconic(window_handle_)) {
    ShowWindow(window_handle_, SW_RESTORE);
  } else if (!IsWindowVisible(window_handle_)) {
    ShowWindow(window_handle_, SW_SHOWNORMAL);
  } else {
    ShowWindow(window_handle_, SW_SHOW);
  }
  PlaceChildContent();
  if (!IsAlwaysOnTop()) {
    SetWindowPos(window_handle_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  }
  SetForegroundWindow(window_handle_);
  if (child_content_) {
    SetFocus(child_content_);
  }
}

void Win32Window::ForceClose() {
  if (!window_handle_) return;
  force_closing_ = true;
  RemoveTrayIcon();
  DestroyWindow(window_handle_);
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL) != FALSE;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_) {
    tray_added_ = false;
    Shell_NotifyIconW(NIM_ADD, &tray_nid_);
    tray_added_ = true;
    return 0;
  }

  if (message == kWmTrayCallback) {
    const UINT ev = LOWORD(lparam);
    if (ev == WM_LBUTTONUP || ev == WM_LBUTTONDBLCLK) {
      ShowAndFocus();
      OnTrayAction("open");
      return 0;
    }
    if (ev == WM_RBUTTONUP || ev == WM_CONTEXTMENU) {
      ShowTrayContextMenu();
      return 0;
    }
    return 0;
  }

  switch (message) {
    case WM_COMMAND: {
      const UINT_PTR cmd_id = LOWORD(wparam);
      if (cmd_id == kTrayIdOpen) {
        ShowAndFocus();
        OnTrayAction("open");
        return 0;
      }
      if (cmd_id == kTrayIdStart) {
        OnTrayAction("start");
        return 0;
      }
      if (cmd_id == kTrayIdStop) {
        OnTrayAction("stop");
        return 0;
      }
      if (cmd_id == kTrayIdQuit) {
        OnTrayAction("quit");
        return 0;
      }
      break;
    }

    case WM_ERASEBKGND: {
      HDC hdc = reinterpret_cast<HDC>(wparam);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      if (IsBackdropEffectEnabled()) {
        FillRect(hdc, &rc, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
      } else {
        HBRUSH brush =
            is_dark_mode_ ? solid_dark_brush_ : solid_light_brush_;
        if (brush != nullptr) {
          FillRect(hdc, &rc, brush);
        }
      }
      return 1;
    }

    case WM_NCCALCSIZE: {
      if (wparam != 0) {
        const LONG_PTR ex_style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        const RECT frame = ComputeFrameInsets(
            hwnd, WS_OVERLAPPEDWINDOW, static_cast<DWORD>(ex_style));
        auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
        RECT& rect = params->rgrc[0];
        rect.left -= frame.left;
        rect.right -= frame.right;
        rect.bottom -= frame.bottom;
        if (IsZoomed(hwnd)) {
          rect.top += frame.bottom;
        } else if (IsWindows11OrGreater() && !IsBackdropEffectEnabled()) {
          rect.top += 1;
        }
        return 0;
      }
      break;
    }

    case WM_NCACTIVATE:
      return 1;

    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
      info->ptMinTrackSize.x = Scale(380, scale);
      info->ptMinTrackSize.y = Scale(460, scale);
      return 0;
    }

    case WM_NCHITTEST: {
      const int border = TopBorderHeight();
      if (border > 0) {
        const LRESULT hit = DefWindowProc(hwnd, message, wparam, lparam);
        const POINT pt{static_cast<short>(LOWORD(lparam)),
                       static_cast<short>(HIWORD(lparam))};
        RECT win_rect{};
        GetWindowRect(hwnd, &win_rect);
        if (hit == HTCLIENT && pt.y < win_rect.top + border) {
          const int corner =
              -ComputeFrameInsets(hwnd, WS_OVERLAPPEDWINDOW, 0).left * 2;
          if (pt.x < win_rect.left + corner) return HTTOPLEFT;
          if (pt.x >= win_rect.right - corner) return HTTOPRIGHT;
          return HTTOP;
        }
        return hit;
      }
      break;
    }

    case WM_PAINT: {
      const int border = TopBorderHeight();
      if (border > 0) {
        PAINTSTRUCT ps{};
        HDC hdc = BeginPaint(hwnd, &ps);
        RECT strip = ps.rcPaint;
        if (strip.bottom > border) strip.bottom = border;
        if (strip.top < strip.bottom) {
          FillRect(hdc, &strip, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
        }
        EndPaint(hwnd, &ps);
        return 0;
      }
      break;
    }

    case WM_WINDOWPOSCHANGED: {
      auto* pos = reinterpret_cast<const WINDOWPOS*>(lparam);
      if ((pos->flags & SWP_FRAMECHANGED) != 0) {
        PlaceChildContent();
      }
      break;
    }

    case WM_CLOSE: {
      if (hide_on_close_ && !force_closing_) {
        HideToTray();
        return 0;
      }
      break;
    }

    case WM_DESTROY:
      RemoveTrayIcon();
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }

    case WM_SIZE: {
      if (wparam == SIZE_MINIMIZED) {
        return 0;
      }
      const bool now_max = IsMaximized();
      if (now_max != was_maximized_) {
        was_maximized_ = now_max;
        UpdateCornerPreference();
        OnWindowStateChanged();
      }
      PlaceChildContent();
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  RemoveTrayIcon();
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  PlaceChildContent();
  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame{};
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SetHideOnClose(bool hide_on_close) {
  hide_on_close_ = hide_on_close;
}

bool Win32Window::OnCreate() {
  return true;
}

void Win32Window::OnDestroy() {}

void Win32Window::OnWindowStateChanged() {}

void Win32Window::OnTrayAction(const char* /*action*/) {}
