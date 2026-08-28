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

  /// The amount originally typed, per asset. Generation is seeded from this
  /// rather than from [amounts], so sending does not reshuffle past history:
  /// the balance moves, the story behind it does not.
  @observable
  ObservableMap<String, String> seeds = ObservableMap<String, String>();

  /// Sends made in the app. Kept separately so they appear as their own
  /// outgoing entries on top of the generated history.
  @observable
  ObservableList<LarpSend> sends = ObservableList<LarpSend>();

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
      seeds.remove(k);
    } else {
      amounts[k] = trimmed;
      // Typing a new figure restarts the story: reseed and drop old sends.
      seeds[k] = trimmed;
    }
    sends.removeWhere((send) => send.symbol == k);
    _save();
  }

  /// The figure generation is seeded from. Falls back to the current amount
  /// for overrides saved before seeds existed.
  String seedFor(Currency currency) {
    final k = key(currency);
    return seeds[k] ?? amounts[k] ?? '';
  }

  List<LarpSend> sendsFor(Currency currency) {
    final k = key(currency);
    return sends.where((send) => send.symbol == k).toList();
  }

  /// Records a send: the displayed balance drops by [amount] and the send is
  /// remembered so it shows in the history.
  @action
  void recordSend(Currency currency, Money amount, String address) {
    final k = key(currency);
    final current = moneyFor(currency);
    if (current == null) return;

    final remaining = current - amount;
    amounts[k] = (remaining.isNegative ? Money.zero(currency) : remaining).toString();
    sends.add(LarpSend(
      symbol: k,
      amount: amount.toString(),
      address: address,
      dateMillis: DateTime.now().millisecondsSinceEpoch,
    ));
    _save();
  }

  @action
  void clear(Currency currency) {
    final k = key(currency);
    amounts.remove(k);
    seeds.remove(k);
    sends.removeWhere((send) => send.symbol == k);
    _save();
  }

  @action
  void clearAll() {
    amounts.clear();
    seeds.clear();
    sends.clear();
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
      final seedMap = decoded['seeds'] as Map<String, dynamic>? ?? map;
      final sendList = decoded['sends'] as List<dynamic>? ?? <dynamic>[];
      runInAction(() {
        enabled = decoded['enabled'] as bool? ?? true;
        amounts = ObservableMap<String, String>.of(
          map.map((k, dynamic v) => MapEntry(k, v.toString())),
        );
        seeds = ObservableMap<String, String>.of(
          seedMap.map((k, dynamic v) => MapEntry(k, v.toString())),
        );
        sends = ObservableList<LarpSend>.of(
          sendList.map((dynamic e) => LarpSend.fromJson(e as Map<String, dynamic>)),
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
        'seeds': seeds,
        'sends': sends.map((send) => send.toJson()).toList(),
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

/// A send made inside the app.
class LarpSend {
  const LarpSend({
    required this.symbol,
    required this.amount,
    required this.address,
    required this.dateMillis,
  });

  factory LarpSend.fromJson(Map<String, dynamic> json) => LarpSend(
        symbol: json['symbol'] as String? ?? '',
        amount: json['amount'] as String? ?? '0',
        address: json['address'] as String? ?? '',
        dateMillis: json['date'] as int? ?? 0,
      );

  final String symbol;
  final String amount;
  final String address;
  final int dateMillis;

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(dateMillis);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'symbol': symbol,
        'amount': amount,
        'address': address,
        'date': dateMillis,
      };
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
