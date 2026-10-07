import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostpanel/app.dart';
import 'package:ghostpanel/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用冒烟测试：GhostPanel 能正常启动并渲染服务器列表页。
void main() {
  testWidgets('App 启动渲染 ServerListScreen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWithValue(StorageService(prefs))],
        child: const GhostPanelApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 标题与空态引导
    expect(find.text('GhostPanel'), findsOneWidget);
    expect(find.text('还没有配置工作站'), findsOneWidget);
    expect(find.text('添加第一台工作站'), findsOneWidget);
  });

  testWidgets('点击添加进入编辑页并可填写表单', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWithValue(StorageService(prefs))],
        child: const GhostPanelApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加第一台工作站'));
    await tester.pumpAndSettle();

    expect(find.text('添加工作站'), findsWidgets);
    expect(find.text('零打扰策略'), findsOneWidget);
    expect(find.text('隐形传输模式'), findsOneWidget);

    // 危险命令拦截在页面底部（ListView 懒加载），滚动到可见再断言
    await tester.scrollUntilVisible(
      find.text('危险命令拦截'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('危险命令拦截'), findsOneWidget);
  });

  testWidgets('保存配置后出现在服务器列表', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageProvider.overrideWithValue(StorageService(prefs))],
        child: const GhostPanelApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 进入编辑页
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // 填写必填字段
    await tester.enterText(
      find.widgetWithText(TextFormField, '名称（如：渲染工作站）'),
      '测试渲染机',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '主机 IP / 域名 *'),
      '192.168.1.50',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '用户名 *'),
      'alice',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'SSH 密码 *'),
      'secret',
    );
    await tester.pumpAndSettle();

    // 保存（AppBar 上的保存按钮）
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 回到列表页，应显示新服务器
    expect(find.text('测试渲染机'), findsOneWidget);
    expect(find.text('alice@192.168.1.50:22'), findsOneWidget);

    // 且已持久化
    final reloaded = StorageService(prefs).loadServers();
    expect(reloaded, hasLength(1));
    expect(reloaded.single.name, '测试渲染机');
    expect(reloaded.single.stealthMode, isTrue);
    expect(reloaded.single.bandwidthLimitMBs, 8);
  });
}
