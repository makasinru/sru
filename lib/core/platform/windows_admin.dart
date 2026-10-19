import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Права администратора — нужны режиму TUN на Windows (драйвер wintun и
/// системные маршруты). Без них работает только системный прокси.
class WindowsAdmin {
  static bool get isAdmin {
    if (!Platform.isWindows) return false;
    final isUserAnAdmin = DynamicLibrary.open('shell32.dll')
        .lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
    return isUserAnAdmin() != 0;
  }

  /// Перезапуск с запросом UAC. Возвращает false, если пользователь отказался.
  static bool relaunchElevated(List<String> args) {
    final shellExecute = DynamicLibrary.open('shell32.dll')
        .lookupFunction<
          IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Int32),
          int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int)
        >('ShellExecuteW');
    return using((arena) {
      final r = shellExecute(
        0,
        'runas'.toNativeUtf16(allocator: arena),
        Platform.resolvedExecutable.toNativeUtf16(allocator: arena),
        args.map((a) => '"$a"').join(' ').toNativeUtf16(allocator: arena),
        nullptr,
        1, // SW_SHOWNORMAL
      );
      return r > 32; // ShellExecute: >32 — успех
    });
  }
}
