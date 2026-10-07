import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers/app_providers.dart';

final _logTailProvider = StreamProvider.autoDispose<List<String>>((
  ref,
) async* {
  final storage = ref.watch(storageProvider);
  while (true) {
    final file = File(storage.logFile);
    if (!file.existsSync()) {
      yield const [];
    } else {
      final lines = await file.readAsLines();
      yield lines.length > 300 ? lines.sublist(lines.length - 300) : lines;
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});

class LogsScreen extends ConsumerWidget {
  const LogsScreen({super.key});

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all logs?'),
        content: const Text('This permanently deletes the entire engine log. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(storageProvider).deleteFileIfExists(ref.read(storageProvider).logFile);
      ref.invalidate(_logTailProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(_logTailProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete all logs',
            onPressed: () => _confirmDeleteAll(context, ref),
          ),
        ],
      ),
      body: lines.when(
        data: (l) => l.isEmpty
            ? const Center(child: Text('No log entries yet.'))
            : ListView.builder(
                reverse: true,
                itemCount: l.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  child: Text(
                    l[l.length - 1 - i],
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
