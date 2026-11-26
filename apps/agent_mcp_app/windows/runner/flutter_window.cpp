#include "flutter_window.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <wtsapi32.h>

#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr UINT_PTR kFlutterViewA11yGuardSubclassId = 0xA6E17;

bool IsForceAccessibilityEnabledByEnv() {
  static int cached = -1;
  if (cached >= 0) {
    return cached == 1;
  }
  wchar_t buf[16] = {0};
  DWORD len = ::GetEnvironmentVariableW(L"AGENT_MCP_ENABLE_A11Y", buf, 16);
  cached = (len > 0 && len < 16 &&
            (::_wcsicmp(buf, L"1") == 0 || ::_wcsicmp(buf, L"true") == 0))
               ? 1
               : 0;
  return cached == 1;
}

bool ShouldAllowUiAutomationBridge() {
  if (IsForceAccessibilityEnabledByEnv()) {
    return true;
  }
  BOOL screen_reader = FALSE;
  if (::SystemParametersInfoW(SPI_GETSCREENREADER, 0, &screen_reader, 0) &&
      screen_reader == TRUE) {
    return true;
  }
  return false;
}

// Guards FLUTTERVIEW against unsolicited WM_GETOBJECT probes from remote-control
// virtual display / input hooks (UU GameViewer, Oray Sunlogin, ToDesk) and IMEs,
// which otherwise permanently activate Flutter 3.47's broken Windows AccessibilityBridge
// (causing per-frame UI-thread AXTree stalls and 0xc0000005 access violations).
LRESULT CALLBACK FlutterViewA11yGuardSubclassProc(
    HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam, UINT_PTR uIdSubclass,
    DWORD_PTR /*dwRefData*/) noexcept {
  if (msg == WM_GETOBJECT && !ShouldAllowUiAutomationBridge()) {
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
  if (msg == WM_NCDESTROY) {
    ::RemoveWindowSubclass(hwnd, FlutterViewA11yGuardSubclassProc, uIdSubclass);
  }
  return ::DefSubclassProc(hwnd, msg, wparam, lparam);
}

std::wstring Utf8ToWide(const std::string& str) {
  if (str.empty()) return L"";
  int needed = ::MultiByteToWideChar(CP_UTF8, 0, str.data(),
                                     static_cast<int>(str.size()), nullptr, 0);
  if (needed <= 0) return L"";
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, str.data(), static_cast<int>(str.size()),
                        &out[0], needed);
  return out;
}

std::string WideToUtf8(const std::wstring& wstr) {
  if (wstr.empty()) return "";
  int needed = ::WideCharToMultiByte(CP_UTF8, 0, wstr.data(),
                                     static_cast<int>(wstr.size()), nullptr, 0,
                                     nullptr, nullptr);
  if (needed <= 0) return "";
  std::string out(static_cast<size_t>(needed), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wstr.data(), static_cast<int>(wstr.size()),
                        &out[0], needed, nullptr, nullptr);
  return out;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::SetStartHidden(bool start_hidden) {
  start_hidden_ = start_hidden;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetupWindowChannel();
  child_flutter_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  if (child_flutter_hwnd_ != nullptr) {
    ::SetWindowSubclass(child_flutter_hwnd_, FlutterViewA11yGuardSubclassProc,
                        kFlutterViewA11yGuardSubclassId, 0);
  }
  SetChildContent(child_flutter_hwnd_);

  // Enable native Win32 drag-and-drop for 1-step file/folder external sharing
  if (GetHandle() != nullptr) {
    ::DragAcceptFiles(GetHandle(), TRUE);
    wts_registered_ =
        ::WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION) !=
        FALSE;
  }

  if (!start_hidden_) {
    flutter_controller_->engine()->SetNextFrameCallback([this]() {
      this->Show();
    });
  }

  flutter_controller_->ForceRedraw();

  return true;
}

flutter::EncodableMap FlutterWindow::BuildStateMap() const {
  HWND hwnd = const_cast<FlutterWindow*>(this)->GetHandle();
  const bool visible = hwnd != nullptr && ::IsWindowVisible(hwnd) != FALSE &&
                       ::IsIconic(hwnd) == FALSE;
  return flutter::EncodableMap{
      {flutter::EncodableValue("isMaximized"),
       flutter::EncodableValue(IsMaximized())},
      {flutter::EncodableValue("isPinned"),
       flutter::EncodableValue(IsAlwaysOnTop())},
      {flutter::EncodableValue("isBackdropSupported"),
       flutter::EncodableValue(IsBackdropSupported())},
      {flutter::EncodableValue("windowEffect"),
       flutter::EncodableValue(IsBackdropEffectEnabled())},
      {flutter::EncodableValue("isVisible"),
       flutter::EncodableValue(visible)},
  };
}

void FlutterWindow::SetupWindowChannel() {
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "agent_mcp/window",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "startDragging") {
          this->StartDragging();
          result->Success();
          return;
        }
        if (method == "minimize") {
          this->Minimize();
          this->OnWindowStateChanged();
          result->Success();
          return;
        }
        if (method == "toggleMaximize") {
          this->ToggleMaximize();
          result->Success(flutter::EncodableValue(this->IsMaximized()));
          return;
        }
        if (method == "togglePin") {
          const bool next = !this->IsAlwaysOnTop();
          this->SetAlwaysOnTop(next);
          result->Success(flutter::EncodableValue(next));
          return;
        }
        if (method == "hideToTray") {
          this->HideToTray();
          this->OnWindowStateChanged();
          result->Success();
          return;
        }
        if (method == "showAndFocus") {
          this->ShowAndFocus();
          this->OnWindowStateChanged();
          if (flutter_controller_) {
            flutter_controller_->ForceRedraw();
          }
          result->Success();
          return;
        }
        if (method == "forceClose") {
          this->ForceClose();
          result->Success();
          return;
        }
        if (method == "setDarkTheme") {
          bool dark = false;
          if (const auto* b = std::get_if<bool>(call.arguments())) {
            dark = *b;
          } else if (const auto* m =
                         std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = m->find(flutter::EncodableValue("dark"));
            if (it != m->end()) {
              if (const auto* vb = std::get_if<bool>(&it->second)) {
                dark = *vb;
              }
            }
          }
          this->SetDarkTheme(dark);
          result->Success();
          return;
        }
        if (method == "setWindowEffect") {
          bool enabled = false;
          if (const auto* b = std::get_if<bool>(call.arguments())) {
            enabled = *b;
          }
          this->SetBackdropEffect(enabled);
          result->Success(
              flutter::EncodableValue(this->IsBackdropEffectEnabled()));
          return;
        }
        if (method == "setTrayTooltip") {
          if (const auto* s = std::get_if<std::string>(call.arguments())) {
            this->SetTrayTooltip(Utf8ToWide(*s));
          }
          result->Success();
          return;
        }
        if (method == "setTrayState") {
          if (const auto* m =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            std::wstring sname;
            bool running = true;
            int port = 8000;
            bool dark = false;

            auto itName = m->find(flutter::EncodableValue("serverName"));
            if (itName != m->end()) {
              if (const auto* vs = std::get_if<std::string>(&itName->second)) {
                sname = Utf8ToWide(*vs);
              }
            }
            auto itRun = m->find(flutter::EncodableValue("running"));
            if (itRun != m->end()) {
              if (const auto* vb = std::get_if<bool>(&itRun->second)) {
                running = *vb;
              }
            }
            auto itPort = m->find(flutter::EncodableValue("port"));
            if (itPort != m->end()) {
              if (const auto* vi = std::get_if<int32_t>(&itPort->second)) {
                port = *vi;
              } else if (const auto* vi64 =
                             std::get_if<int64_t>(&itPort->second)) {
                port = static_cast<int>(*vi64);
              }
            }
            auto itDark = m->find(flutter::EncodableValue("dark"));
            if (itDark != m->end()) {
              if (const auto* vd = std::get_if<bool>(&itDark->second)) {
                dark = *vd;
              }
            }
            int accent_rgb = dark ? 0x818CF8 : 0x4F46E5;
            auto itAccent = m->find(flutter::EncodableValue("accentRgb"));
            if (itAccent != m->end()) {
              if (const auto* va = std::get_if<int32_t>(&itAccent->second)) {
                accent_rgb = *va;
              } else if (const auto* va64 =
                             std::get_if<int64_t>(&itAccent->second)) {
                accent_rgb = static_cast<int>(*va64);
              }
            }
            this->SetTrayState(sname, running, port, dark, accent_rgb);
          }
          result->Success();
          return;
        }
        if (method == "getState") {
          result->Success(flutter::EncodableValue(this->BuildStateMap()));
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::OnWindowStateChanged() {
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "onStateChanged",
        std::make_unique<flutter::EncodableValue>(BuildStateMap()));
  }
}

void FlutterWindow::OnTrayAction(const char* action) {
  if (action == nullptr) return;
  if (std::strcmp(action, "open") == 0) {
    OnWindowStateChanged();
    if (flutter_controller_) {
      flutter_controller_->ForceRedraw();
    }
    return;
  }
  if (window_channel_) {
    window_channel_->InvokeMethod(
        "onTrayAction",
        std::make_unique<flutter::EncodableValue>(std::string(action)));
  } else if (std::strcmp(action, "quit") == 0) {
    ForceClose();
  }
}

void FlutterWindow::OnDestroy() {
  if (wts_registered_ && GetHandle() != nullptr) {
    ::WTSUnRegisterSessionNotification(GetHandle());
    wts_registered_ = false;
  }
  if (child_flutter_hwnd_ != nullptr && ::IsWindow(child_flutter_hwnd_)) {
    ::RemoveWindowSubclass(child_flutter_hwnd_,
                           FlutterViewA11yGuardSubclassProc,
                           kFlutterViewA11yGuardSubclassId);
    child_flutter_hwnd_ = nullptr;
  }
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_DROPFILES) {
    HDROP hdrop = reinterpret_cast<HDROP>(wparam);
    UINT count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
    flutter::EncodableList paths;
    for (UINT i = 0; i < count; ++i) {
      UINT len = ::DragQueryFileW(hdrop, i, nullptr, 0);
      if (len > 0) {
        std::wstring buf(static_cast<size_t>(len) + 1, L'\0');
        ::DragQueryFileW(hdrop, i, &buf[0], len + 1);
        buf.resize(len);
        paths.emplace_back(WideToUtf8(buf));
      }
    }
    ::DragFinish(hdrop);
    if (!paths.empty() && window_channel_) {
      window_channel_->InvokeMethod(
          "onFilesDropped",
          std::make_unique<flutter::EncodableValue>(paths));
    }
    return 0;
  }

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
    case WM_SHOWWINDOW:
      OnWindowStateChanged();
      if (wparam == TRUE && flutter_controller_) {
        flutter_controller_->ForceRedraw();
      }
      break;
    case WM_DISPLAYCHANGE:
      if (child_flutter_hwnd_ != nullptr && ::IsWindow(child_flutter_hwnd_)) {
        RECT frame = GetClientArea();
        ::MoveWindow(child_flutter_hwnd_, frame.left, frame.top,
                     frame.right - frame.left, frame.bottom - frame.top, TRUE);
      }
      if (flutter_controller_) {
        flutter_controller_->ForceRedraw();
      }
      break;
    case WM_WTSSESSION_CHANGE:
      if ((wparam == WTS_SESSION_UNLOCK || wparam == WTS_REMOTE_CONNECT ||
           wparam == WTS_REMOTE_DISCONNECT || wparam == WTS_CONSOLE_CONNECT) &&
          flutter_controller_) {
        if (child_flutter_hwnd_ != nullptr && ::IsWindow(child_flutter_hwnd_)) {
          RECT frame = GetClientArea();
          ::MoveWindow(child_flutter_hwnd_, frame.left, frame.top,
                       frame.right - frame.left, frame.bottom - frame.top,
                       TRUE);
        }
        flutter_controller_->ForceRedraw();
      }
      break;
    case WM_SIZE:
      OnWindowStateChanged();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
