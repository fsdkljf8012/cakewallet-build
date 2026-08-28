import 'package:cake_wallet/larp/larp_store.dart';
import 'package:cake_wallet/larp/larp_tx.dart';
import 'package:cw_core/amount/money.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds to an asset's displayed balance and posts an incoming transaction
/// dated now.
///
/// Opened by long-pressing Receive. The editor on the asset row replaces a
/// balance outright; this one tops it up, which is what an actual deposit
/// looks like in the history.
class LarpReceiveModal extends StatefulWidget {
  const LarpReceiveModal({super.key, required this.assets, required this.initial});

  final List<CryptoCurrency> assets;
  final CryptoCurrency initial;

  static Future<bool?> show(
    BuildContext context, {
    required List<CryptoCurrency> assets,
    required CryptoCurrency initial,
  }) {
    if (assets.isEmpty) return Future<bool?>.value(false);
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => LarpReceiveModal(assets: assets, initial: initial),
    );
  }

  @override
  State<LarpReceiveModal> createState() => _LarpReceiveModalState();
}

class _LarpReceiveModalState extends State<LarpReceiveModal> {
  final TextEditingController _controller = TextEditingController();
  late CryptoCurrency _asset = widget.assets.contains(widget.initial)
      ? widget.initial
      : widget.assets.first;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final text = _controller.text.trim();
    final amount = Money.tryParse(text, _asset);
    if (text.isEmpty || amount == null || amount.isZero) {
      setState(() => _error = 'Enter an amount to add');
      return;
    }
    // A deposit comes from somewhere, and the details sheet shows it.
    final sender = LarpTxGenerator(
      _asset,
      BigInt.one,
      DateTime.now().microsecondsSinceEpoch.toString(),
    ).newAddress();

    larpStore.recordReceive(_asset, amount, sender);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            'Add to balance',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Posts an incoming transaction dated now',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          if (widget.assets.length > 1) ...[
            DropdownButtonFormField<CryptoCurrency>(
              initialValue: _asset,
              decoration: const InputDecoration(
                labelText: 'Asset',
                border: OutlineInputBorder(),
              ),
              items: widget.assets
                  .map((a) => DropdownMenuItem<CryptoCurrency>(
                        value: a,
                        child: Text('${a.fullName ?? a.name}  (${a.title})'),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _asset = value);
              },
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(
              hintText: '0.00',
              errorText: _error,
              suffixText: _asset.title,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _add(),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _add,
                  child: const Text('Add'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
