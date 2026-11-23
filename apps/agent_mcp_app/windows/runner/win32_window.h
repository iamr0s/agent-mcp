#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>
#include <shellapi.h>

#include <functional>
#include <memory>
#include <string>

// High-DPI frameless Win32 Window modeled after modern Windows 11 desktop apps:
// - Keeps native Aero Snap, Win+Arrows, shadow, and resize borders while
//   stripping the white non-client titlebar via WM_NCCALCSIZE.
// - Hosts the Windows System Tray icon natively on the main STA UI thread
//   (eliminating cross-thread Dart FFI WNDPROC callbacks).
// - Supports Windows 11 DWM Mica backdrop (DWMWA_SYSTEMBACKDROP_TYPE = 38).
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  bool Create(const std::wstring& title, const Point& origin, const Size& size);
  bool Show();
  void Destroy();
  void SetChildContent(HWND content);
  HWND GetHandle();
  void SetQuitOnClose(bool quit_on_close);
  void SetHideOnClose(bool hide_on_close);
  RECT GetClientArea();

  // Custom frameless window controls & Win11 Mica backdrop
  bool IsMaximized() const;
  bool IsAlwaysOnTop() const;
  bool IsBackdropSupported() const;
  bool IsBackdropEffectEnabled() const;
  void StartDragging();
  void Minimize();
  void ToggleMaximize();
  void SetAlwaysOnTop(bool topmost);
  void HideToTray();
  void ShowAndFocus();
  void ForceClose();
  void SetDarkTheme(bool is_dark);
  void SetBackdropEffect(bool enabled);
  void SetTrayTooltip(const std::wstring& tooltip);
  void SetTrayState(const std::wstring& server_name,
                    bool is_running,
                    int port,
                    bool is_dark,
                    int accent_rgb = 0x4F46E5);

 protected:
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  virtual bool OnCreate();
  virtual void OnDestroy();
  virtual void OnWindowStateChanged();
  virtual void OnTrayAction(const char* action);

 private:
  friend class WindowClassRegistrar;

  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  void ApplyFramelessStyle();
  void UpdateCornerPreference();
  int TopBorderHeight() const;
  void PlaceChildContent();

  void InitTrayIcon(const std::wstring& tooltip);
  void RemoveTrayIcon();
  void ShowTrayContextMenu();
  void DestroyTrayFlyout();
  void PaintTrayFlyout(HWND hwnd, HDC hdc);
  int HitTestTrayFlyout(HWND hwnd, int x, int y) const;
  void TriggerTrayFlyoutItem(int index);

  static LRESULT CALLBACK TrayFlyoutWndProc(HWND const window,
                                            UINT const message,
                                            WPARAM const wparam,
                                            LPARAM const lparam) noexcept;

  bool quit_on_close_ = false;
  bool hide_on_close_ = true;
  bool force_closing_ = false;
  bool is_dark_mode_ = false;
  bool was_maximized_ = false;
  bool backdrop_enabled_ = false;
  bool tray_added_ = false;

  HWND tray_flyout_hwnd_ = nullptr;
  int tray_hover_index_ = -1;
  bool tray_tracking_mouse_ = false;
  bool tray_service_running_ = true;
  int tray_port_ = 8000;
  int tray_accent_rgb_ = 0x4F46E5;
  std::wstring tray_server_name_ = L"Agent MCP";

  UINT taskbar_created_msg_ = 0;
  NOTIFYICONDATAW tray_nid_{};
  HBRUSH solid_dark_brush_ = nullptr;
  HBRUSH solid_light_brush_ = nullptr;

  HWND window_handle_ = nullptr;
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
