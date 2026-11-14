#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

#ifndef _DEBUG
  // A second copy would overwrite the first's preferences and start its own recordings and sync
  ::CreateMutexW(nullptr, TRUE, L"Local\\CapyTV.SingleInstance");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Capy TV")) {
      ::ShowWindow(running, SW_RESTORE);
      ::SetForegroundWindow(running);
    }
    return EXIT_SUCCESS;
  }
#endif

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Centred on the main screen and within what the taskbar leaves of it: 1280x720 at 150 % on a
  // 1080p laptop would otherwise go under the taskbar and past the right edge
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  HMONITOR monitor = ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{sizeof(info)};
  if (::GetMonitorInfo(monitor, &info)) {
    const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
    const RECT& work = info.rcWork;
    const double width = (work.right - work.left) / scale, height = (work.bottom - work.top) / scale;
    size.width = std::min(1280u, static_cast<unsigned int>(width * 0.92));
    size.height = std::min(720u, static_cast<unsigned int>(height * 0.92));
    origin.x = static_cast<unsigned int>(work.left / scale + (width - size.width) / 2);
    origin.y = static_cast<unsigned int>(work.top / scale + (height - size.height) / 2);
  }
  if (!window.Create(L"Capy TV", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  window.SetShowCommand(show_command);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
