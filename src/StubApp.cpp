// Copyright (c) My Context Menu Tools contributors.
// Licensed under the MIT License.

#include <windows.h>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  MessageBoxW(nullptr,
              L"My Context Menu Tools is configured from %LOCALAPPDATA%\\MyContextMenuTools\\tools.jsonc.",
              L"My Context Menu Tools",
              MB_OK);
  return 0;
}
