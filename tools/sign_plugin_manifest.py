#!/usr/bin/env python3
"""魔蚁TV 插件包签发工具（P0-1 配套）。

对 .idjplugin 包里的 manifest 计算 canonical JSON 并用 Ed25519 私钥签名，
把 `integrity.signature = {alg: 'ed25519', value: base64(...)}` 写回包。

用法：
    python3 tools/sign_plugin_manifest.py --key PRIV_B64 --in plugin.idjplugin [--out signed.idjplugin]

私钥保管：仅线下保管，绝不进仓库/进 CI。公钥钉死在
lib/idj_signing.dart 的 kIdjBuiltInAuthorPubKey，换钥匙必须发版。

canonical JSON 口径（与 Dart idjCanonicalJson 完全对齐）：
- 递归键排序、紧凑分隔符 (',', ':')、ensure_ascii=False、UTF-8 字节；
- 被签内容 = 去掉 integrity.signature 后的 manifest 对象。
依赖：pip install pynacl
"""
import argparse
import base64
import json
import sys

try:
    from nacl.signing import SigningKey
except ImportError:
    sys.exit('缺少依赖：pip install pynacl')


def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--key', required=True, help='Ed25519 私钥 base64（raw 32 字节）')
    ap.add_argument('--in', dest='infile', required=True, help='输入 .idjplugin 包（JSON 文本）')
    ap.add_argument('--out', dest='outfile', help='输出包；缺省就地写回 --in')
    args = ap.parse_args()

    with open(args.infile, 'r', encoding='utf-8') as f:
        bundle = json.load(f)
    manifest = bundle.get('manifest')
    if not isinstance(manifest, dict):
        sys.exit('包里没有 manifest 对象')

    integrity = manifest.get('integrity')
    if not isinstance(integrity, dict):
        integrity = {}
    # 被签内容：去掉 signature 后的 manifest（保留 integrity 其他字段如
    # files 哈希；integrity 为扁平字符串形态时保持字符串不动）。
    sign_manifest = json.loads(json.dumps(manifest))
    integrity_field = sign_manifest.get('integrity')
    if isinstance(integrity_field, dict):
        integrity_field.pop('signature', None)

    payload = canonical(sign_manifest).encode('utf-8')
    sk = SigningKey(base64.b64decode(args.key))
    sig = sk.sign(payload).signature

    integrity['signature'] = {'alg': 'ed25519', 'value': base64.b64encode(sig).decode()}
    manifest['integrity'] = integrity

    out = args.outfile or args.infile
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(bundle, f, ensure_ascii=False, indent=None, separators=(',', ':'))
    print(f'已签名 → {out}')
    print(f'被签 payload sha256: {__import__("hashlib").sha256(payload).hexdigest()}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
