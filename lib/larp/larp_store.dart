import 'dart:convert';

import 'package:cw_core/amount/money.dart';
import 'package:cw_core/balance.dart';
import 'package:cw_core/currency.dart';
import 'package:mobx/mobx.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'larp_store.g.dart';

/// Per-asset display overrides.
///
/// Values are kept as the decimal string the user typed, not as base units,
/// so what is shown in the editor is exactly what was entered. Conversion to
/// [Money] happens at read time against the currency's own decimals.
class LarpStore = LarpStoreBase with _$LarpStore;

abstract class LarpStoreBase with Store {
  LarpStoreBase({SharedPreferences? prefs}) : _prefs = prefs {
    _load();
  }

  static const _prefsKey = 'larp_overrides_v1';

  SharedPreferences? _prefs;

  /// Asset symbol (upper case, e.g. "SOL", "USDC") -> decimal amount string.
  @observable
  ObservableMap<String, String> amounts = ObservableMap<String, String>();

  /// Master switch. When false every override is ignored and the wallet's
  /// real values show through, which makes it easy to check what is real.
  @observable
  bool enabled = true;

  static String key(Currency currency) => currency.symbol.toUpperCase();

  @computed
  bool get hasAny => enabled && amounts.isNotEmpty;

  /// The override for [currency], or null when there is none or the feature
  /// is switched off. Returns null rather than zero on a malformed value so
  /// the caller falls back to the real balance.
  Money? moneyFor(Currency currency) {
    if (!enabled) return null;
    final raw = amounts[key(currency)];
    if (raw == null || raw.trim().isEmpty) return null;
    return Money.tryParse(raw.trim(), currency);
  }

  String rawFor(Currency currency) => amounts[key(currency)] ?? '';

  @action
  void setAmount(Currency currency, String value) {
    final k = key(currency);
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      amounts.remove(k);
    } else {
      amounts[k] = trimmed;
    }
    _save();
  }

  @action
  void clear(Currency currency) {
    amounts.remove(key(currency));
    _save();
  }

  @action
  void clearAll() {
    amounts.clear();
    _save();
  }

  @action
  void setEnabled(bool value) {
    enabled = value;
    _save();
  }

  Future<void> _load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs?.getString(_prefsKey);
    if (raw == null) return;
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      final map = decoded['amounts'] as Map<String, dynamic>? ?? <String, dynamic>{};
      // Observables must only change inside an action.
      runInAction(() {
        enabled = decoded['enabled'] as bool? ?? true;
        amounts = ObservableMap<String, String>.of(
          map.map((k, dynamic v) => MapEntry(k, v.toString())),
        );
      });
    } catch (_) {
      // A malformed blob is not worth crashing over; start clean.
    }
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs?.setString(
      _prefsKey,
      json.encode(<String, dynamic>{
        'enabled': enabled,
        'amounts': amounts,
      }),
    );
  }

  /// Returns [original] with the override substituted, or [original] itself
  /// when there is none.
  ///
  /// Everything other than the available amount is zeroed: a made-up pending
  /// or frozen figure sitting beside a chosen balance would not add up.
  Balance applyTo(Currency currency, Balance original) {
    final override = moneyFor(currency);
    if (override == null) return original;
    final zero = Money.zero(currency);
    return LarpBalance(
      override,
      zero,
      secondAvailable: original.secondAvailable == null ? null : zero,
      secondUnavailable: original.secondUnavailable == null ? null : zero,
      frozen: original.frozen == null ? null : zero,
    );
  }
}

/// Balance is abstract and every coin subclasses it, so we need our own.
class LarpBalance extends Balance {
  const LarpBalance(
    super.available,
    super.unavailable, {
    super.secondAvailable,
    super.secondUnavailable,
    super.frozen,
  });
}

/// Single shared instance.
///
/// Deliberately not registered in di.dart: this keeps the feature to its own
/// directory plus a handful of call sites, so it is easy to find and easy to
/// lift out again.
final LarpStore larpStore = LarpStore();
