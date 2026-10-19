import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// QR-код для передачи сервера на другое устройство: сканируется камерой в
/// SruNaZapret, а одиночный ключ — и в Happ, v2rayNG, Hiddify.
Future<void> showShareQr(BuildContext context, {required String title, required String data}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: data, size: 256, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 12),
            const Text(
              'Отсканируйте в приложении: «Добавить сервер» → «Сканировать QR-код».',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: data));
            Navigator.pop(ctx);
          },
          child: const Text('Скопировать'),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
      ],
    ),
  );
}
