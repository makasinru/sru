import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Читает QR-код из картинки (PNG, JPEG, WebP…) — для Windows, где нет камеры:
/// скриншот QR из Telegram или с сайта.
class QrImage {
  static String? decode(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    final pixels = image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List();
    final source = RGBLuminanceSource(image.width, image.height, pixels);
    for (final binarizer in [HybridBinarizer(source), GlobalHistogramBinarizer(source)]) {
      try {
        return QRCodeReader().decode(BinaryBitmap(binarizer), hints: DecodeHints()..put(DecodeHintType.tryHarder)).text;
      } on ReaderException {
        continue;
      }
    }
    return null;
  }
}
