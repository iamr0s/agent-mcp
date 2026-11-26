#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::wstring GetExecutableDirectory() {
  wchar_t buffer[MAX_PATH] = {0};
  DWORD len = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return L"";
  }
  std::wstring full_path(buffer, len);
  size_t pos = full_path.find_last_of(L"\\/");
  return (pos == std::wstring::npos) ? L"" : full_path.substr(0, pos);
}

void NormalizeWorkingDirectoryIfSystemDir(const std::wstring& exe_dir) {
  if (exe_dir.empty()) return;
  wchar_t cwd_buf[MAX_PATH] = {0};
  DWORD cwd_len = ::GetCurrentDirectoryW(MAX_PATH, cwd_buf);
  wchar_t win_buf[MAX_PATH] = {0};
  UINT win_len = ::GetWindowsDirectoryW(win_buf, MAX_PATH);
  if (cwd_len > 0 && win_len > 0 && cwd_len >= win_len) {
    if (::_wcsnicmp(cwd_buf, win_buf, win_len) == 0) {
      ::SetCurrentDirectoryW(exe_dir.c_str());
    }
  }
}

bool ReadFileUtf8(const std::wstring& path, std::string* out) {
  HANDLE h = ::CreateFileW(path.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) {
    return false;
  }
  LARGE_INTEGER size{};
  if (!::GetFileSizeEx(h, &size) || size.QuadPart <= 0 ||
      size.QuadPart > 262144) {
    ::CloseHandle(h);
    return false;
  }
  out->resize(static_cast<size_t>(size.QuadPart));
  DWORD bytes_read = 0;
  BOOL ok = ::ReadFile(h, &(*out)[0], static_cast<DWORD>(size.QuadPart),
                       &bytes_read, nullptr);
  ::CloseHandle(h);
  if (!ok) {
    return false;
  }
  out->resize(bytes_read);
  return true;
}

std::optional<bool> ParseJsonOptionalBool(const std::string& json,
                                          const char* key) {
  std::string needle = "\"";
  needle += key;
  needle += "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return std::nullopt;
  pos += needle.size();
  while (pos < json.size() &&
         (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' ||
          json[pos] == '\n')) {
    ++pos;
  }
  if (pos >= json.size() || json[pos] != ':') return std::nullopt;
  ++pos;
  while (pos < json.size() &&
         (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' ||
          json[pos] == '\n')) {
    ++pos;
  }
  if (pos + 4 <= json.size() &&
      std::strncmp(json.c_str() + pos, "true", 4) == 0) {
    return true;
  }
  if (pos + 5 <= json.size() &&
      std::strncmp(json.c_str() + pos, "false", 5) == 0) {
    return false;
  }
  return std::nullopt;
}

struct StartupConfigFlags {
  bool silent_start = false;
  bool window_effect = true;
};

StartupConfigFlags ReadStartupConfigFlags(const std::wstring& exe_dir) {
  StartupConfigFlags flags;
  std::vector<std::wstring> candidates;
  wchar_t env_home[MAX_PATH] = {0};
  DWORD env_len =
      ::GetEnvironmentVariableW(L"AGENT_MCP_HOME", env_home, MAX_PATH);
  if (env_len > 0 && env_len < MAX_PATH) {
    candidates.push_back(std::wstring(env_home, env_len) +
                         L"\\config\\mcp_config.json");
  }
  if (!exe_dir.empty()) {
    candidates.push_back(exe_dir + L"\\config\\mcp_config.json");
  }
  candidates.push_back(L"config\\mcp_config.json");

  std::string content;
  for (const auto& path : candidates) {
    if (ReadFileUtf8(path, &content)) {
      if (auto s = ParseJsonOptionalBool(content, "silent_start")) {
        flags.silent_start = *s;
      }
      if (auto w = ParseJsonOptionalBool(content, "window_effect")) {
        flags.window_effect = *w;
      }
      break;
    }
  }
  return flags;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  const std::wstring exe_dir = GetExecutableDirectory();
  NormalizeWorkingDirectoryIfSystemDir(exe_dir);

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  bool cli_silent = false;
  bool cli_show = false;
  bool cli_installer = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--silent" || arg == "--background" || arg == "--tray" ||
        arg == "--minimized" || arg == "-s") {
      cli_silent = true;
    } else if (arg == "--show" || arg == "--open-window") {
      cli_show = true;
    } else if (arg == "--installer") {
      cli_installer = true;
    }
  }

  // Single-instance guard (bypassed when running in --installer wizard mode so
  // an active tray instance never swallows the interactive setup wizard):
  HANDLE mutex = nullptr;
  if (!cli_installer) {
    mutex =
        ::CreateMutexW(nullptr, TRUE, L"Local\\AgentMcpConsoleSingleInstance");
    if (mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
      if (!cli_silent) {
        HWND existing =
            ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Agent MCP Console");
        if (existing != nullptr) {
          if (::IsIconic(existing)) {
            ::ShowWindow(existing, SW_RESTORE);
          } else if (!::IsWindowVisible(existing)) {
            ::ShowWindow(existing, SW_SHOWNORMAL);
          } else {
            ::ShowWindow(existing, SW_SHOW);
          }
          ::SetForegroundWindow(existing);
        }
      }
      ::CloseHandle(mutex);
      return EXIT_SUCCESS;
    }
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const StartupConfigFlags cfg_flags = ReadStartupConfigFlags(exe_dir);
  const bool start_hidden =
      !cli_installer && !cli_show && (cli_silent || cfg_flags.silent_start);

  bool enable_impeller = false;
  wchar_t impeller_env[16] = {0};
  DWORD impeller_env_len =
      ::GetEnvironmentVariableW(L"AGENT_MCP_IMPELLER", impeller_env, 16);
  if (impeller_env_len > 0 && impeller_env_len < 16) {
    if (::_wcsicmp(impeller_env, L"1") == 0 ||
        ::_wcsicmp(impeller_env, L"true") == 0) {
      enable_impeller = true;
    }
  }
  for (const auto& arg : command_line_arguments) {
    if (arg == "--enable-impeller" || arg == "--enable-impeller=true") {
      enable_impeller = true;
    } else if (arg == "--enable-impeller=false") {
      enable_impeller = false;
    }
  }

  flutter::DartProject project(L"data");
  // Default to Skia on Windows unless AGENT_MCP_IMPELLER=1 is set: Flutter 3.47's
  // default Windows Impeller (OpenGLES/ANGLE) backend can deadlock on multi-GPU +
  // virtual display driver (UU Remote / Oray / IddCx) adapter resets.
  project.set_impeller_switch(enable_impeller
                                  ? flutter::ImpellerSwitch::Enabled
                                  : flutter::ImpellerSwitch::Disabled);
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetStartHidden(start_hidden);
  window.SetBackdropEffect(false);
  if (cli_installer) {
    window.SetTrayEnabled(false);
  }

  Win32Window::Point origin(80, 60);
  Win32Window::Size size = cli_installer
      ? Win32Window::Size(700, 568)
      : Win32Window::Size(1180, 780);
  const wchar_t* win_title =
      cli_installer ? L"Agent MCP Setup" : L"Agent MCP Console";
  if (!window.Create(win_title, origin, size)) {
    if (mutex != nullptr) {
      ::CloseHandle(mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  if (cli_installer) {
    window.CenterOnPrimaryMonitor();
  }
  window.SetHideOnClose(!cli_installer);
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (mutex != nullptr) {
    ::CloseHandle(mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
