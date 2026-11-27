import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// Ed25519 插件验签（P0-1）。
///
/// 口径（与安全整改方案 §P0-1 一致）：
/// - 内置作者公钥钉死在本文件，无法被 manifest/订阅篡改；
/// - `integrity.signature = {alg: 'ed25519', value: base64(签名)}`；
/// - 被签内容 = 去掉 `integrity.signature` 后的 canonical JSON
///   （键排序、无空白、UTF-8 字节，与 tools/sign_plugin_manifest.py 对齐）；
/// - 验签失败不算致命：无签名块走「警告 + 确认」路径，
///   签名块存在但验不过按未签名处理并带原因（不硬拒，保住第三方生态）。

/// 内置插件作者公钥（base64 raw 32 字节）。
/// ⚠️ 演示密钥：正式发布前必须换成发布方线下保管的密钥对，
///    私钥不进仓库，公钥从这里改。
const String kIdjBuiltInAuthorPubKey =
    '5mVjcOAUQqsZ8SM+wXl0cthRInR408+vjymRHIGGDoc=';

enum IdjSignatureStatus {
  /// manifest 没有 integrity.signature 块。
  unsigned,

  /// 有签名块且验签通过（公钥 = 内置作者公钥）。
  valid,

  /// 有签名块但验不过/格式错。原因见 [IdjSignatureResult.reason]。
  invalid,
}

class IdjSignatureResult {
  const IdjSignatureResult(this.status, {this.reason});
  final IdjSignatureStatus status;
  final String? reason;

  bool get isValid => status == IdjSignatureStatus.valid;
  bool get isUnsigned => status == IdjSignatureStatus.unsigned;
}

/// canonical JSON：递归键排序、紧凑分隔符（与 Python
/// `json.dumps(obj, sort_keys=True, separators=(',', ':'),
/// ensure_ascii=False)` 的 UTF-8 字节完全一致）。
String idjCanonicalJson(Object? value) {
  final buf = StringBuffer();
  _writeCanonical(value, buf);
  return buf.toString();
}

void _writeCanonical(Object? value, StringBuffer buf) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    buf.write('{');
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      _writeJsonString(k, buf);
      buf.write(':');
      _writeCanonical(value[k], buf);
      if (i != keys.length - 1) buf.write(',');
    }
    buf.write('}');
    return;
  }
  if (value is List) {
    buf.write('[');
    for (var i = 0; i < value.length; i++) {
      _writeCanonical(value[i], buf);
      if (i != value.length - 1) buf.write(',');
    }
    buf.write(']');
    return;
  }
  if (value is bool) {
    buf.write(value ? 'true' : 'false');
    return;
  }
  if (value is num) {
    if (value is double &&
        value == value.truncateToDouble() &&
        !value.isInfinite &&
        value.abs() < 1e15) {
      buf.write(value.truncate().toString());
    } else {
      buf.write(value.toString());
    }
    return;
  }
  if (value == null) {
    buf.write('null');
    return;
  }
  _writeJsonString(value.toString(), buf);
}

void _writeJsonString(String s, StringBuffer buf) {
  buf.write('"');
  for (final code in s.codeUnits) {
    switch (code) {
      case 0x22:
        buf.write(r'\"');
        break;
      case 0x5C:
        buf.write(r'\\');
        break;
      case 0x08:
        buf.write(r'\b');
        break;
      case 0x0C:
        buf.write(r'\f');
        break;
      case 0x0A:
        buf.write(r'\n');
        break;
      case 0x0D:
        buf.write(r'\r');
        break;
      case 0x09:
        buf.write(r'\t');
        break;
      default:
        if (code < 0x20) {
          buf.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
        } else if (code <= 0x7E) {
          buf.writeCharCode(code);
        } else {
          buf.writeCharCode(code);
        }
    }
  }
  buf.write('"');
}

/// 从 manifest 原始 JSON 中提取签名块（`integrity.signature`）。
Map<String, dynamic>? idjExtractSignatureBlock(Map<String, dynamic> raw) {
  final integrity = raw['integrity'];
  if (integrity is Map) {
    final sig = Map<String, dynamic>.from(integrity)['signature'];
    if (sig is Map) return Map<String, dynamic>.from(sig);
  }
  return null;
}

/// 构造被签的 canonical 字节：manifest 原样解码 → 删 `integrity.signature`
/// → canonical JSON → UTF-8。与签发脚本完全对齐。
Uint8List idjSigningPayload(Map<String, dynamic> rawManifest) {
  final copy = jsonDecode(jsonEncode(rawManifest)) as Map<String, dynamic>;
  final integrity = copy['integrity'];
  if (integrity is Map) {
    final m = Map<String, dynamic>.from(integrity);
    m.remove('signature');
    copy['integrity'] = m.isEmpty ? null : m;
    if (m.isEmpty) copy.remove('integrity');
  }
  return Uint8List.fromList(utf8.encode(idjCanonicalJson(copy)));
}

/// 验签入口。rawManifest 是整个 bundle 的 `manifest` 对象。
IdjSignatureResult idjVerifyPluginSignature(Map<String, dynamic> rawManifest) {
  final sig = idjExtractSignatureBlock(rawManifest);
  if (sig == null || sig.isEmpty) {
    return const IdjSignatureResult(IdjSignatureStatus.unsigned);
  }
  final alg = sig['alg']?.toString() ?? '';
  final value = sig['value']?.toString() ?? '';
  if (alg != 'ed25519' || value.isEmpty) {
    return IdjSignatureResult(
      IdjSignatureStatus.invalid,
      reason: alg.isEmpty ? '签名块缺少 alg' : '签名算法不支持：$alg',
    );
  }
  Uint8List signature;
  try {
    signature = Uint8List.fromList(base64Decode(value));
  } catch (_) {
    return const IdjSignatureResult(
      IdjSignatureStatus.invalid,
      reason: '签名值不是合法 base64',
    );
  }
  if (signature.length != 64) {
    return IdjSignatureResult(
      IdjSignatureStatus.invalid,
      reason: '签名长度异常（${signature.length} 字节，应为 64）',
    );
  }
  Uint8List pub;
  try {
    pub = Uint8List.fromList(base64Decode(kIdjBuiltInAuthorPubKey));
  } catch (_) {
    return const IdjSignatureResult(
      IdjSignatureStatus.invalid,
      reason: '内置公钥配置异常',
    );
  }
  if (pub.length != 32) {
    return IdjSignatureResult(
      IdjSignatureStatus.invalid,
      reason: '内置公钥长度异常（${pub.length} 字节，应为 32）',
    );
  }
  final payload = idjSigningPayload(rawManifest);
  try {
    final ok = ed.verify(ed.PublicKey(pub), payload, signature);
    if (!ok) {
      return const IdjSignatureResult(
        IdjSignatureStatus.invalid,
        reason: '签名与内容不匹配',
      );
    }
    return const IdjSignatureResult(IdjSignatureStatus.valid);
  } catch (error) {
    return IdjSignatureResult(
      IdjSignatureStatus.invalid,
      reason: '验签异常：$error',
    );
  }
}

/// 给测试用的便利：本地 digest（与 IdjPluginBundle.hashScript 保持一致口径）。
String idjSha256HexOf(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();

/// 测试/签发辅助：用私钥给 manifest 签名。
/// 私钥 base64（raw 32 字节 seed），返回 base64 签名。
String idjSignManifestForTest(String privB64, Map<String, dynamic> rawManifest) {
  final priv = Uint8List.fromList(base64Decode(privB64));
  final signer = ed.PrivateKey(priv);
  final sig = ed.sign(signer, idjSigningPayload(rawManifest));
  return base64Encode(Uint8List.fromList(sig));
}
