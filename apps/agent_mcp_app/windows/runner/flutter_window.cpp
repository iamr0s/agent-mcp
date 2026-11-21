#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstring>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  if (!start_hidden_) {
    flutter_controller_->engine()->SetNextFrameCallback([this]() {
      this->Show();
    });
  }

  flutter_controller_->ForceRedraw();

  return true;
}

flutter::EncodableMap FlutterWindow::BuildStateMap() const {
  return flutter::EncodableMap{
      {flutter::EncodableValue("isMaximized"),
       flutter::EncodableValue(IsMaximized())},
      {flutter::EncodableValue("isPinned"),
       flutter::EncodableValue(IsAlwaysOnTop())},
      {flutter::EncodableValue("isBackdropSupported"),
       flutter::EncodableValue(IsBackdropSupported())},
      {flutter::EncodableValue("windowEffect"),
       flutter::EncodableValue(IsBackdropEffectEnabled())},
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
          result->Success();
          return;
        }
        if (method == "showAndFocus") {
          this->ShowAndFocus();
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
            this->SetTrayState(sname, running, port, dark);
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
      if (wparam == TRUE && flutter_controller_) {
        flutter_controller_->ForceRedraw();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
