import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sru/core/links/deep_link.dart';
import 'package:sru/core/links/qr_image.dart';
import 'package:zxing2/qrcode.dart';

const key = 'vless://u@h:443?security=reality&pbk=k&sni=a.com#Мой сервер';

Uint8List qrPng(String text) {
  final qr = Encoder.encode(text, ErrorCorrectionLevel.m);
  final m = qr.matrix!;
  const scale = 6, quiet = 4;
  final size = (m.width + quiet * 2) * scale;
  final image = img.Image(width: size, height: size)..clear(img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < m.height; y++) {
    for (var x = 0; x < m.width; x++) {
      if (m.get(x, y) == 1) {
        img.fillRect(
          image,
          x1: (x + quiet) * scale,
          y1: (y + quiet) * scale,
          x2: (x + quiet + 1) * scale - 1,
          y2: (y + quiet + 1) * scale - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
    }
  }
  return img.encodePng(image);
}

void main() {
  group('Диплинки', () {
    test('ключ напрямую', () => expect(DeepLink.payload(key), key));

    test('sru://add/<encoded> не теряет ? и # во вложенной ссылке', () {
      expect(DeepLink.payload('sru://add/${Uri.encodeComponent(key)}'), key);
      expect(DeepLink.payload('sru://add/$key'), key);
    });

    test('sru://add?url=подписка', () {
      expect(
        DeepLink.payload('sru://add?url=${Uri.encodeComponent('https://sub.example/abc?x=1')}'),
        'https://sub.example/abc?x=1',
      );
    });

    test('sru://import — несколько ключей', () {
      final link = DeepLink.importLink([key, 'trojan://p@h:2053#t']);
      expect(DeepLink.payload(link), '$key\ntrojan://p@h:2053#t');
    });

    test('чужие схемы и пустые ссылки', () {
      expect(DeepLink.payload('https://example.com'), isNull);
      expect(DeepLink.payload('sru://add/'), isNull);
      expect(DeepLink.payload('sru://unknown/x'), isNull);
    });
  });

  test('QR из картинки', () {
    final link = DeepLink.importLink([key, 'trojan://p@h:2053#t']);
    expect(QrImage.decode(qrPng(link)), link);
    expect(QrImage.decode(img.encodePng(img.Image(width: 50, height: 50))), isNull);
  });
}
