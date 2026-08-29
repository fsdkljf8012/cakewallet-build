import 'dart:convert';

import 'package:cake_wallet/exchange/trade_state.dart';
import 'package:cake_wallet/larp/larp_watch.dart';
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

  /// Swaps whose deposit was paid with a larp send: trade id -> the moment it
  /// was sent. The provider never sees a deposit, so left alone the trade sits
  /// at "Unpaid" for ever; this is what lets it be aged instead.
  @observable
  ObservableMap<String, int> tradePayments = ObservableMap<String, int>();

  /// Assets currently mirroring a real address: symbol -> the address.
  @observable
  ObservableMap<String, String> watchAddresses = ObservableMap<String, String>();

  /// The history that came back from the chain for each watched asset. Kept
  /// rather than refetched so a restart shows it immediately, and so the
  /// explorer is asked once per address instead of once per rebuild.
  @observable
  ObservableMap<String, List<LarpWatchEntry>> watchTxs =
      ObservableMap<String, List<LarpWatchEntry>>();

  /// What [amounts] and [seeds] held before a watch took over, so clearing the
  /// address puts back exactly what was there -- the typed balance and the
  /// history generated from it -- rather than leaving the real one behind.
  /// An empty string means there was no entry at all.
  @observable
  ObservableMap<String, String> watchRestore = ObservableMap<String, String>();
  @observable
  ObservableMap<String, String> watchSeedRestore = ObservableMap<String, String>();

  /// Master switch. When false every override is ignored and the wallet's
  /// real values show through, which makes it easy to check what is real.
  @observable
  bool enabled = true;

  static String key(Currency currency) => currency.symbol.toUpperCase();

  @computed
  bool get hasAny => enabled && (amounts.isNotEmpty || watchAddresses.isNotEmpty);

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
  ///
  /// Ignores a repeat of the same amount to the same address within a minute.
  /// Committing can be triggered more than once -- a double tap on the confirm
  /// button is enough -- and that would otherwise post the transaction twice
  /// and take the balance down twice.
  @action
  void recordSend(Currency currency, Money amount, String address) {
    final k = key(currency);
    final current = moneyFor(currency);
    if (current == null) return;

    if (_isDuplicate(k, amount.toString(), address, false)) return;

    final remaining = current - amount;
    amounts[k] = (remaining.isNegative ? Money.zero(currency) : remaining).toString();
    _appendMovement(k, amount, address, false);
  }

  /// Records a top-up: the displayed balance rises by [amount] and an incoming
  /// entry appears in the history, dated now.
  @action
  void recordReceive(Currency currency, Money amount, String address) {
    final k = key(currency);
    final current = moneyFor(currency) ?? Money.zero(currency);

    if (_isDuplicate(k, amount.toString(), address, true)) return;

    amounts[k] = (current + amount).toString();
    // A top-up on an asset with no override yet establishes one, and seeds the
    // generated history from the same figure.
    seeds.putIfAbsent(k, () => amounts[k]!);
    _appendMovement(k, amount, address, true);
  }

  /// Notes that a swap's deposit went out as a larp send.
  @action
  void markTradePaid(String tradeId) {
    if (tradeId.isEmpty || tradePayments.containsKey(tradeId)) return;
    tradePayments[tradeId] = DateTime.now().millisecondsSinceEpoch;
    _save();
  }

  /// How much of a swap has "happened" by now, or null when the trade was
  /// paid for real and the provider's own state should stand.
  ///
  /// A real swap moves through several states over a few minutes rather than
  /// flipping straight to done, so this walks the same path on a clock. The
  /// exact wording is the provider vocabulary Cake already renders, so nothing
  /// downstream needs to know these came from here.
  TradeState? tradeStateFor(String tradeId) {
    if (!enabled) return null;
    final paidAt = tradePayments[tradeId];
    if (paidAt == null) return null;
    final seconds = (DateTime.now().millisecondsSinceEpoch - paidAt) / 1000;
    if (seconds < 90) return TradeState.paidUnconfirmed;
    if (seconds < 240) return TradeState.confirming;
    if (seconds < 420) return TradeState.exchanging;
    if (seconds < 540) return TradeState.sending;
    return TradeState.success;
  }

  String? watchAddressFor(Currency currency) => watchAddresses[key(currency)];

  bool isWatching(Currency currency) => enabled && watchAddresses.containsKey(key(currency));

  /// The watched history for [currency], or null when it is not watching one.
  List<LarpWatchEntry>? watchTxsFor(Currency currency) {
    if (!enabled) return null;
    return watchTxs[key(currency)];
  }

  /// Mirrors a real address: its balance becomes the displayed one and its
  /// transactions become the history.
  ///
  /// The balance is written into [amounts] rather than kept beside it, so
  /// every path that already reads an override -- the card, Max on send, the
  /// swap screen -- follows without knowing a watch exists. Sends still work
  /// on top of it and still bring it down.
  @action
  void applyWatch(Currency currency, String address, LarpWatchResult result) {
    final k = key(currency);
    // Only on the way in. Re-watching or refreshing must not overwrite the
    // typed balance with the last address's figure.
    if (!watchAddresses.containsKey(k)) {
      watchRestore[k] = amounts[k] ?? '';
      watchSeedRestore[k] = seeds[k] ?? '';
    }
    final balance = Money(result.balanceBaseUnits, currency).toString();
    watchAddresses[k] = address;
    watchTxs[k] = result.entries;
    amounts[k] = balance;
    // Nothing should generate from the old seed while a real history is on
    // screen, and this leaves the seed right if the watch is refreshed.
    seeds[k] = balance;
    _save();
  }

  /// Stops mirroring and puts back the balance and the generated history.
  @action
  void clearWatch(Currency currency) {
    final k = key(currency);
    if (!watchAddresses.containsKey(k)) return;
    watchAddresses.remove(k);
    watchTxs.remove(k);
    final amount = watchRestore.remove(k) ?? '';
    final seed = watchSeedRestore.remove(k) ?? '';
    if (amount.isEmpty) {
      amounts.remove(k);
    } else {
      amounts[k] = amount;
    }
    if (seed.isEmpty) {
      seeds.remove(k);
    } else {
      seeds[k] = seed;
    }
    _save();
  }

  bool _isDuplicate(String symbol, String amount, String address, bool incoming) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 60000;
    return sends.any((m) =>
        m.symbol == symbol &&
        m.amount == amount &&
        m.address == address &&
        m.incoming == incoming &&
        m.dateMillis >= cutoff);
  }

  void _appendMovement(String symbol, Money amount, String address, bool incoming) {
    sends.add(LarpSend(
      symbol: symbol,
      amount: amount.toString(),
      address: address,
      dateMillis: DateTime.now().millisecondsSinceEpoch,
      incoming: incoming,
    ));
    _save();
  }

  @action
  void clear(Currency currency) {
    final k = key(currency);
    amounts.remove(k);
    seeds.remove(k);
    sends.removeWhere((send) => send.symbol == k);
    watchAddresses.remove(k);
    watchTxs.remove(k);
    watchRestore.remove(k);
    watchSeedRestore.remove(k);
    _save();
  }

  @action
  void clearAll() {
    amounts.clear();
    seeds.clear();
    sends.clear();
    tradePayments.clear();
    watchAddresses.clear();
    watchTxs.clear();
    watchRestore.clear();
    watchSeedRestore.clear();
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
      final tradeMap = decoded['trades'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final watchMap = decoded['watch'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final watchTxMap = decoded['watchTxs'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final restoreMap = decoded['watchRestore'] as Map<String, dynamic>? ?? <String, dynamic>{};
      final seedRestoreMap =
          decoded['watchSeedRestore'] as Map<String, dynamic>? ?? <String, dynamic>{};
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
        tradePayments = ObservableMap<String, int>.of(
          tradeMap.map((k, dynamic v) => MapEntry(k, (v as num).toInt())),
        );
        watchAddresses = ObservableMap<String, String>.of(
          watchMap.map((k, dynamic v) => MapEntry(k, v.toString())),
        );
        watchTxs = ObservableMap<String, List<LarpWatchEntry>>.of(
          watchTxMap.map((k, dynamic v) => MapEntry(
                k,
                (v as List<dynamic>)
                    .map((dynamic e) => LarpWatchEntry.fromJson(e as Map<String, dynamic>))
                    .toList(),
              )),
        );
        watchRestore = ObservableMap<String, String>.of(
          restoreMap.map((k, dynamic v) => MapEntry(k, v.toString())),
        );
        watchSeedRestore = ObservableMap<String, String>.of(
          seedRestoreMap.map((k, dynamic v) => MapEntry(k, v.toString())),
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
        'trades': tradePayments,
        'watch': watchAddresses,
        'watchTxs': watchTxs
            .map((k, v) => MapEntry(k, v.map((entry) => entry.toJson()).toList())),
        'watchRestore': watchRestore,
        'watchSeedRestore': watchSeedRestore,
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
    this.incoming = false,
  });

  factory LarpSend.fromJson(Map<String, dynamic> json) => LarpSend(
        symbol: json['symbol'] as String? ?? '',
        amount: json['amount'] as String? ?? '0',
        address: json['address'] as String? ?? '',
        dateMillis: json['date'] as int? ?? 0,
        // Absent on records written before top-ups existed, which were all
        // sends.
        incoming: json['in'] as bool? ?? false,
      );

  final String symbol;
  final String amount;
  final String address;
  final int dateMillis;
  final bool incoming;

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(dateMillis);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'symbol': symbol,
        'amount': amount,
        'address': address,
        'date': dateMillis,
        'in': incoming,
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
