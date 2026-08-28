import 'package:cake_wallet/larp/larp_store.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';

/// Editor for an asset's displayed balance.
///
/// Opened by long-pressing an asset row. Nothing in the UI advertises it.
class LarpEditorModal extends StatefulWidget {
  const LarpEditorModal({super.key, required this.asset});

  final CryptoCurrency asset;

  static Future<void> show(BuildContext context, CryptoCurrency asset) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => LarpEditorModal(asset: asset),
    );
  }

  @override
  State<LarpEditorModal> createState() => _LarpEditorModalState();
}

class _LarpEditorModalState extends State<LarpEditorModal> {
  late final TextEditingController _controller =
      TextEditingController(text: larpStore.rawFor(widget.asset));

  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isNotEmpty && Money.tryParse(text, widget.asset) == null) {
      setState(() => _error = 'Not a valid ${widget.asset.name} amount');
      return;
    }
    larpStore.setAmount(widget.asset, text);
    Navigator.of(context).pop();
  }

  void _clear() {
    larpStore.clear(widget.asset);
    _controller.clear();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asset = widget.asset;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            asset.fullName ?? asset.name,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Displayed balance',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: InputDecoration(
              hintText: '0.00',
              errorText: _error,
              suffixText: asset.title,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          Text(
            'History is generated from this amount, across the last two '
            'months. Leave empty to show the real balance.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Observer(
            builder: (_) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Overrides active'),
              subtitle: const Text('Off shows every real balance again'),
              value: larpStore.enabled,
              onChanged: larpStore.setEnabled,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _clear,
                  child: const Text('Clear'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
