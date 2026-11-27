import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';

/// 启动后发现新版本时弹的更新提示框。
///
/// P1 更新策略整改（2026-11-27）：移除「框内下载 APK + 调系统安装器」
/// 路径，全部平台统一为「提示 + 跳发布页」，用户在浏览器里自己下载、
/// 自己装。App 不再持有「下载并安装 APK」的能力（AppUpdateBridge 的
/// installApk 通道不再被调用；REQUEST_INSTALL_PACKAGES 权限可在
/// Manifest 中移除）。
/// 「稍后再说」只记这一个版本，有更新的版本下次启动还会再弹；
/// 原强制更新（FORCE_AFTER/FORCE_UNTIL）窗口不再改变弹窗行为——
/// 只把窗口信息显示出来，永远可以关掉、永远可以跳过（提示更新，
/// 不强制）。
Future<void> showAppUpdatePrompt(
  BuildContext context, {
  required AppVersion current,
  required AppReleaseInfo latest,
}) async {
  // 仅用于文案展示：告知发布说明里声明过强制窗口（不再据此改变交互）。
  final forced = AppUpdateChecker.isForceUpdate(
    current,
    latest,
    DateTime.now(),
  );
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      String? error;
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> openReleasePage() async {
            final opened = await AppUpdateChannel.openUrl(latest.htmlUrl);
            if (!opened && context.mounted) {
              setState(() => error = '无法打开浏览器，请手动前往发布页');
            } else if (context.mounted) {
              Navigator.of(context).pop();
            }
          }

          return AlertDialog(
            title: Text('发现新版本 ${latest.version}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前版本 $current → 最新版本 ${latest.version}'),
                  if (latest.notes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('更新说明：\n${latest.notes}'),
                  ],
                  if (forced) ...[
                    const SizedBox(height: 12),
                    Text(
                      '发布方提示：此版本声明了更新窗口，建议尽快更新。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '将前往发布页下载安装包，下载与安装由你在浏览器与系统安装器中完成。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await AppUpdateChecker.dismissUpdate(latest.version);
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                child: const Text('稍后再说'),
              ),
              FilledButton(
                onPressed: openReleasePage,
                child: const Text('打开发布页'),
              ),
            ],
          );
        },
      );
    },
  );
}
