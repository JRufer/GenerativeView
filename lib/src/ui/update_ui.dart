// Showing an update from GitHub, and installing it when asked.

import 'package:flutter/material.dart';

import '../platform.dart';
import '../theme.dart';
import '../updates.dart';
import 'meta_panel.dart' show toast;
import 'sheet.dart';
import 'toast.dart';

/// Where this build stands against the releases on GitHub, with what can be
/// done about it: check, install, restart. Nothing when [updater] is null
/// (a build that can't look).
class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.updater});
  final Updater? updater;

  @override
  Widget build(BuildContext context) {
    final updater = this.updater;
    if (updater == null || !updater.canCheck) return const SizedBox.shrink();
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: updater.status,
      builder: (context, status, _) => _UpdateBody(updater: updater, status: status),
    );
  }
}

class _UpdateBody extends StatelessWidget {
  const _UpdateBody({required this.updater, required this.status});
  final Updater updater;
  final UpdateStatus status;

  Future<void> _install(BuildContext context) async {
    final build = status.build;
    if (build == null) return;
    if (await updater.installWay() == InstallWay.page) {
      final opened = await openUrl(build.page.toString());
      if (!opened && context.mounted) toast(context, 'Could not open the release page');
      return;
    }
    await updater.install();
  }

  Future<void> _restart(BuildContext context) async {
    final ok = await updater.restart();
    if (!ok && context.mounted) toast(context, 'Could not start the new build; close and reopen the app');
  }

  @override
  Widget build(BuildContext context) {
    final build = status.build;
    final (String title, String? detail) = switch (status.stage) {
      UpdateStage.idle => ('Updates', 'This is ${updater.currentRelease}.'),
      UpdateStage.checking => ('Checking for updates…', null),
      UpdateStage.upToDate => ('Up to date', '${updater.currentRelease} is the newest build.'),
      UpdateStage.available => ('${build?.title ?? 'A newer build'} is out', 'You have ${updater.currentRelease}.'),
      UpdateStage.downloading => ('Downloading ${build?.title ?? 'the update'}…', '${((status.progress ?? 0) * 100).round()}%'),
      UpdateStage.readyToInstall => ('${build?.title ?? 'The update'} is downloaded', status.message),
      UpdateStage.installed => ('${build?.title ?? 'The update'} is installed', 'Restart to use it. It also starts next time you open the app.'),
      UpdateStage.failed => ('The update did not work', status.message),
    };
    final actions = <Widget>[
      if (build != null && status.stage != UpdateStage.installed)
        TextButton(
          key: const ValueKey<String>('update-notes'),
          onPressed: () => openUrl(build.page.toString()),
          child: const Text('What\'s new'),
        ),
      switch (status.stage) {
        UpdateStage.idle || UpdateStage.upToDate || UpdateStage.checking => OutlinedButton(
          key: const ValueKey<String>('update-check'),
          onPressed: status.stage == UpdateStage.checking ? null : updater.check,
          child: const Text('Check now'),
        ),
        UpdateStage.available => FilledButton(
          key: const ValueKey<String>('update-install'),
          onPressed: () => _install(context),
          child: const Text('Install'),
        ),
        UpdateStage.downloading => OutlinedButton(
          key: const ValueKey<String>('update-cancel'),
          onPressed: updater.cancel,
          child: const Text('Cancel'),
        ),
        UpdateStage.readyToInstall => FilledButton(
          key: const ValueKey<String>('update-install'),
          onPressed: () => _install(context),
          child: const Text('Install'),
        ),
        UpdateStage.installed => FilledButton(
          key: const ValueKey<String>('update-restart'),
          onPressed: () => _restart(context),
          child: const Text('Restart'),
        ),
        UpdateStage.failed => OutlinedButton(
          key: const ValueKey<String>('update-retry'),
          onPressed: build == null ? updater.check : () => _install(context),
          child: const Text('Try again'),
        ),
      },
    ];
    return Container(
      key: const ValueKey<String>('update-card'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      decoration: BoxDecoration(
        color: Palette.raised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: status.stage == UpdateStage.available || status.stage == UpdateStage.installed ? Palette.accent : Palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                status.stage == UpdateStage.failed ? Icons.error_outline : Icons.system_update_alt,
                size: 18,
                color: status.stage == UpdateStage.failed ? Palette.danger : Palette.muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Palette.text)),
              ),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(detail, style: const TextStyle(fontSize: 12.5, height: 1.4, color: Palette.muted)),
          ],
          if (status.stage == UpdateStage.downloading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: status.progress),
          ],
          const SizedBox(height: 6),
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 4, children: actions),
        ],
      ),
    );
  }
}

/// The update on its own, from the toast that says one is out.
Future<void> showUpdatePanel(BuildContext context) => showPanel<void>(
  context,
  title: 'Update',
  icon: Icons.system_update_alt,
  width: 440,
  builder: (context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
    child: UpdateCard(updater: appUpdater),
  ),
);

/// Says once, at the foot of the window, when a newer build turns up, with
/// a way to it. Each build is announced only once a run.
class UpdateAnnouncer {
  UpdateAnnouncer(this.updater, this.navigator);
  final Updater updater;
  final GlobalKey<NavigatorState> navigator;
  final Set<String> _told = {};

  void attach() => updater.status.addListener(_changed);
  void detach() => updater.status.removeListener(_changed);

  void _changed() {
    final status = updater.status.value;
    final build = status.build;
    if (status.stage != UpdateStage.available || build == null || !_told.add(build.tag)) return;
    final context = navigator.currentContext;
    final messenger = context == null ? null : ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      toastBar(
        messenger,
        '${build.title} of GenerativeView is out',
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Update',
          onPressed: () {
            final at = navigator.currentContext;
            if (at != null) showUpdatePanel(at);
          },
        ),
      ),
    );
  }
}
