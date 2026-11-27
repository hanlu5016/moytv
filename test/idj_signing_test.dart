import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:moyi/idj_signing.dart';

/// P0-1 验签测试。
/// 测试密钥对（仅测试用，与 lib/idj_signing.dart 的演示公钥成对）：
/// PUB: 5mVjcOAUQqsZ8SM+wXl0cthRInR408+vjymRHIGGDoc=
/// PRIV: kltKOEiG/1hHVXvL7oubnYISPx8PwAJHbj1giMKWklc=
const testPrivB64 = 'kltKOEiG/1hHVXvL7oubnYISPx8PwAJHbj1giMKWklc=';

Map<String, dynamic> _manifest() => {
  'id': 'com.idj.ext.demo',
  'name': '演示插件',
  'version': '1.0.0',
  'type': 'video',
  'entry': 'main.js',
  'capabilities': ['detail', 'play'],
  'permissions': {
    'http': ['demo.example.com'],
    'storage': false,
  },
};

void main() {
  group('idjCanonicalJson', () {
    test('键排序 + 紧凑分隔符 + 中文原样（与 Python sort_keys 口径一致）', () {
      expect(
        idjCanonicalJson({'b': 1, 'a': true, 'c': null, '名字': '值'}),
        '{"a":true,"b":1,"c":null,"名字":"值"}',
      );
    });

    test('嵌套结构递归排序', () {
      expect(
        idjCanonicalJson({
          'z': {'y': 2, 'x': [3, 1]},
          'a': 's',
        }),
        '{"a":"s","z":{"x":[3,1],"y":2}}',
      );
    });

    test('特殊字符转义', () {
      expect(
        idjCanonicalJson({'k': 'a"b\\c\nd'}),
        '{"k":"a\\"b\\\\c\\nd"}',
      );
    });

    test('整数 double 输出无小数点', () {
      expect(idjCanonicalJson({'n': 2.0}), '{"n":2}');
    });
  });

  group('idjVerifyPluginSignature', () {
    test('无签名块 → unsigned', () {
      final r = idjVerifyPluginSignature(_manifest());
      expect(r.status, IdjSignatureStatus.unsigned);
      expect(r.isUnsigned, isTrue);
    });

    test('正确签名 → valid', () {
      final m = _manifest();
      final sig = idjSignManifestForTest(testPrivB64, m);
      m['integrity'] = {
        'files': {'main.js': 'sha256-x'},
        'signature': {'alg': 'ed25519', 'value': sig},
      };
      final r = idjVerifyPluginSignature(m);
      expect(r.status, IdjSignatureStatus.valid, reason: r.reason);
    });

    test('内容被篡改 → invalid', () {
      final m = _manifest();
      final sig = idjSignManifestForTest(testPrivB64, m);
      m['permissions']['http'] = ['evil.example.com'];
      m['integrity'] = {
        'signature': {'alg': 'ed25519', 'value': sig},
      };
      final r = idjVerifyPluginSignature(m);
      expect(r.status, IdjSignatureStatus.invalid);
      expect(r.reason, '签名与内容不匹配');
    });

    test('错误签名值 → invalid', () {
      final m = _manifest();
      m['integrity'] = {
        'signature': {
          'alg': 'ed25519',
          'value': base64Encode(List.filled(64, 0)),
        },
      };
      expect(idjVerifyPluginSignature(m).status, IdjSignatureStatus.invalid);
    });

    test('未知算法 → invalid', () {
      final m = _manifest();
      m['integrity'] = {
        'signature': {'alg': 'rsa2048', 'value': 'AAAA'},
      };
      final r = idjVerifyPluginSignature(m);
      expect(r.status, IdjSignatureStatus.invalid);
      expect(r.reason, contains('签名算法不支持'));
    });

    test('签名长度异常 → invalid', () {
      final m = _manifest();
      m['integrity'] = {
        'signature': {
          'alg': 'ed25519',
          'value': base64Encode(List.filled(32, 1)),
        },
      };
      final r = idjVerifyPluginSignature(m);
      expect(r.status, IdjSignatureStatus.invalid);
      expect(r.reason, contains('签名长度异常'));
    });

    test('signature 不改变被签 payload（去 signature 后 canonical 一致）', () {
      final m = _manifest();
      final sig = idjSignManifestForTest(testPrivB64, m);
      m['integrity'] = {
        'files': {'main.js': 'sha256-x'},
        'signature': {'alg': 'ed25519', 'value': sig},
      };
      // 重新验签仍通过（signature 自身不进 payload）。
      expect(
        idjVerifyPluginSignature(m).status,
        IdjSignatureStatus.valid,
      );
    });
  });

  group('idjSigningPayload', () {
    test('integrity 为扁平字符串时 payload 含它（去 signature 无操作）', () {
      final m = _manifest();
      m['integrity'] = 'sha256-x';
      final payload = utf8.decode(idjSigningPayload(m));
      expect(payload, contains('"integrity":"sha256-x"'));
    });

    test('integrity 对象含 signature 时 payload 排除 signature', () {
      final m = _manifest();
      m['integrity'] = {
        'files': {'main.js': 'sha256-x'},
        'signature': {'alg': 'ed25519', 'value': 'QUFB'},
      };
      final payload = utf8.decode(idjSigningPayload(m));
      expect(payload, contains('"files"'));
      expect(payload, isNot(contains('signature')));
    });
  });
}
