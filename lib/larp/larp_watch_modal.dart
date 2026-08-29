import 'package:cake_wallet/larp/larp_store.dart';
import 'package:cake_wallet/larp/larp_watch.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Mirrors a real address: paste one and its balance and its transactions
/// take over the display for that asset.
///
/// Opened by long-pressing Swap. Clearing the field puts back whatever was
/// there before -- the typed balance and the history generated from it -- so
/// this is always reversible and never destroys what was set up by hand.
class LarpWatchModal extends StatefulWidget {
  const LarpWatchModal({super.key, required this.assets, required this.initial});

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
      builder: (_) => LarpWatchModal(assets: assets, initial: initial),
    );
  }

  @override
  State<LarpWatchModal> createState() => _LarpWatchModalState();
}

class _LarpWatchModalState extends State<LarpWatchModal> {
  final TextEditingController _controller = TextEditingController();
  late CryptoCurrency _asset =
      widget.assets.contains(widget.initial) ? widget.initial : widget.assets.first;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Shows the address already being mirrored, if there is one, so the field
  /// reflects the state rather than looking empty over a live watch.
  void _loadCurrent() {
    _controller.text = larpStore.watchAddressFor(_asset) ?? '';
  }

  /// Pasting is the whole gesture: it fills the field and looks the address
  /// up straight away rather than waiting for a second tap.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _controller.text = text;
      _error = null;
    });
    await _apply();
  }

  /// Empties the field and puts the generated balance and history back.
  void _clear() {
    larpStore.clearWatch(_asset);
    setState(() {
      _controller.clear();
      _error = null;
    });
  }

  Future<void> _apply() async {
    final address = _controller.text.trim();

    // An empty field is the way out of a watch, which is what makes this
    // reversible from the same control that started it.
    if (address.isEmpty) {
      _clear();
      if (mounted) Navigator.of(context).pop(true);
      return;
    }

    if (!LarpWatch.supports(_asset)) {
      setState(() => _error = LarpWatch.unsupportedReason(_asset));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final result = await LarpWatch.fetch(_asset, address);
      larpStore.applyWatch(_asset, address, result);
      if (mounted) Navigator.of(context).pop(true);
    } on LarpWatchException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Lookup failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final watching = larpStore.watchAddressFor(_asset) != null;
    final supported = LarpWatch.supports(_asset);

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
            'Mirror an address',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Shows that address’s real balance and history. '
            'Clear the field to go back to yours.',
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
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _asset = value;
                        _error = null;
                      });
                      // Each asset carries its own watch, so switching shows
                      // that one rather than the previous asset's address.
                      _loadCurrent();
                    },
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_busy,
            maxLines: 2,
            minLines: 1,
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: '${_asset.title} address',
              errorText: _error,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste),
                onPressed: _busy ? null : _paste,
              ),
            ),
            onChanged: (value) {
              // Emptying the field is the way back: the typed balance and the
              // generated history return the moment the address is gone,
              // without needing another button.
              if (value.trim().isEmpty && larpStore.watchAddressFor(_asset) != null) {
                _clear();
                return;
              }
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _busy ? null : _apply(),
          ),
          if (!supported) ...[
            const SizedBox(height: 8),
            Text(
              LarpWatch.unsupportedReason(_asset),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : watching
                          ? _clear
                          : () => Navigator.of(context).pop(false),
                  child: Text(watching ? 'Stop mirroring' : 'Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || !supported ? null : _apply,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Mirror'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
