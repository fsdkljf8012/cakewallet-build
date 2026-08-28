import 'package:cw_core/amount/money.dart';
import 'package:cw_core/currency.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/transaction_info.dart';

/// A transaction that exists only for display.
///
/// TransactionInfo is abstract and every coin subclasses it; this is our own
/// concrete one so generated history can sit alongside real entries without
/// touching any wallet's storage.
class LarpTransactionInfo extends TransactionInfo {
  LarpTransactionInfo({
    required String id,
    required Money amount,
    required this.currency,
    required TransactionDirection direction,
    required DateTime date,
    Money? fee,
    String? to,
    String? from,
    int confirmations = 0,
    bool isPending = false,
  }) {
    this.id = id;
    this.txHash = id;
    this.amount = amount;
    this.fee = fee;
    this.direction = direction;
    this.date = date;
    this.isPending = isPending;
    this.confirmations = confirmations;
    this.to = to;
    this.from = from;
  }

  final Currency currency;

  bool get isLarp => true;
}

/// Deterministic generator.
///
/// Seeded from the asset and the amount typed, so the same input always
/// produces the same history. Without that the list would reshuffle on every
/// app launch, which is the one thing that would make it obvious.
class LarpTxGenerator {
  LarpTxGenerator(this.currency, this.targetBaseUnits, String seedSource)
      : _state = _fnv1a('${currency.symbol}|$seedSource');

  final Currency currency;
  final BigInt targetBaseUnits;
  int _state;

  static const _daysBack = 60;

  static int _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash == 0 ? 0x811c9dc5 : hash;
  }

  /// xorshift32 -- small, deterministic, and good enough for cosmetics.
  int _next() {
    var x = _state;
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    _state = x & 0xffffffff;
    return _state;
  }

  int _rand(int maxExclusive) => maxExclusive <= 0 ? 0 : _next() % maxExclusive;

  double _randFraction() => _next() / 0xffffffff;

  String _hex(int length) {
    const chars = '0123456789abcdef';
    return List.generate(length, (_) => chars[_rand(16)]).join();
  }

  String _base58(int length) {
    const chars = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
    return List.generate(length, (_) => chars[_rand(chars.length)]).join();
  }

  /// Addresses shaped like the chain's real ones.
  ///
  /// Checked against the tag first so tokens inherit their host chain: USDC
  /// on Solana is tagged SOL and gets a Solana address, not a Bitcoin one.
  String _address() {
    final tag = (currency.tag ?? currency.symbol).toUpperCase();
    switch (tag) {
      // EVM chains all share the same 20-byte hex form.
      case 'ETH':
      case 'POL':
      case 'BSC':
      case 'BNB':
      case 'BASE':
      case 'ARB':
      case 'ARBITRUM':
      case 'AVAXC':
        return '0x${_hex(40)}';
      case 'SOL':
        return _base58(44);
      case 'TRX':
        return 'T${_base58(33)}';
      case 'XMR':
        return '4${_base58(94)}';
      case 'WOW':
        return 'Wo${_base58(95)}';
      case 'ZANO':
        return 'ZxC${_base58(94)}';
      case 'LTC':
        return 'ltc1q${_bech32(38)}';
      case 'BCH':
        return 'bitcoincash:q${_bech32(41)}';
      case 'DOGE':
        return 'D${_base58(33)}';
      case 'DASH':
        return 'X${_base58(33)}';
      case 'DCR':
        return 'Ds${_base58(33)}';
      case 'ZEC':
        return 't1${_base58(33)}';
      case 'XHV':
        return 'hvx${_base58(94)}';
      case 'XNO':
        return 'nano_${_nanoBody(60)}';
      case 'BAN':
        return 'ban_${_nanoBody(60)}';
      case 'BTC':
      default:
        return 'bc1q${_bech32(38)}';
    }
  }

  /// bech32 excludes 1, b, i and o.
  String _bech32(int length) {
    const chars = 'acdefghjklmnpqrstuvwxyz023456789';
    return List.generate(length, (_) => chars[_rand(chars.length)]).join();
  }

  /// Nano's own alphabet, which drops 0, 2, v and l.
  String _nanoBody(int length) {
    const chars = '13456789abcdefghijkmnopqrstuwxyz';
    return List.generate(length, (_) => chars[_rand(chars.length)]).join();
  }

  /// Public so LarpPendingTransaction can borrow the chain-shaped format.
  String newTxId() => _txId();

  String _txId() {
    final tag = (currency.tag ?? currency.symbol).toUpperCase();
    if (tag == 'SOL') return _base58(88);
    if (tag == 'XNO' || tag == 'BAN') return _hex(64).toUpperCase();
    return _hex(64);
  }

  /// Builds a history whose incoming minus outgoing equals the target exactly.
  ///
  /// Outgoing amounts are drawn first as fractions of the target, then the
  /// incoming side is sized to cover the target plus everything sent, so the
  /// arithmetic a viewer could do on screen actually adds up.
  List<LarpTransactionInfo> generate() {
    if (targetBaseUnits <= BigInt.zero) return <LarpTransactionInfo>[];

    final total = 5 + _rand(9); // 5..13 entries
    final outCount = 1 + _rand((total / 3).floor().clamp(1, 4));
    final inCount = total - outCount;

    final outs = <BigInt>[];
    var sentTotal = BigInt.zero;
    for (var i = 0; i < outCount; i++) {
      // 3%..18% of the target per outgoing transaction
      final pct = 0.03 + _randFraction() * 0.15;
      final value = _scale(targetBaseUnits, pct);
      if (value <= BigInt.zero) continue;
      outs.add(value);
      sentTotal += value;
    }

    final receivedTotal = targetBaseUnits + sentTotal;
    final ins = _split(receivedTotal, inCount);

    final now = DateTime.now();
    final entries = <LarpTransactionInfo>[];

    // Received first so the earliest entries fund the later sends.
    var slot = 0;
    final slots = ins.length + outs.length;
    final spacing = slots > 0 ? (_daysBack / slots) : 1.0;

    void add(BigInt value, TransactionDirection direction) {
      final dayOffset = _daysBack - (slot * spacing) - _randFraction() * spacing;
      final date = now.subtract(Duration(
        minutes: (dayOffset * 24 * 60).round().clamp(5, _daysBack * 24 * 60),
      ));
      final ageDays = now.difference(date).inDays;
      entries.add(LarpTransactionInfo(
        id: _txId(),
        amount: Money(value, currency),
        currency: currency,
        direction: direction,
        date: date,
        fee: Money(_scale(value, 0.0004 + _randFraction() * 0.0008), currency),
        to: direction == TransactionDirection.outgoing ? _address() : null,
        from: direction == TransactionDirection.incoming ? _address() : null,
        confirmations: 12 + ageDays * (120 + _rand(240)),
      ));
      slot++;
    }

    for (final value in ins) {
      add(value, TransactionDirection.incoming);
    }
    for (final value in outs) {
      add(value, TransactionDirection.outgoing);
    }

    entries.sort((a, b) => b.date.compareTo(a.date));
    return entries;
  }

  static BigInt _scale(BigInt value, double factor) =>
      (value * BigInt.from((factor * 1000000).round())) ~/ BigInt.from(1000000);

  /// Splits [total] into [count] uneven positive parts that sum exactly to it.
  List<BigInt> _split(BigInt total, int count) {
    if (count <= 0 || total <= BigInt.zero) return <BigInt>[];
    if (count == 1) return <BigInt>[total];

    final weights = List<double>.generate(count, (_) => 0.4 + _randFraction());
    final weightSum = weights.reduce((a, b) => a + b);

    final parts = <BigInt>[];
    var assigned = BigInt.zero;
    for (var i = 0; i < count - 1; i++) {
      final part = _scale(total, weights[i] / weightSum);
      parts.add(part);
      assigned += part;
    }
    // Last part absorbs the rounding so the sum is exact.
    parts.add(total - assigned);
    return parts;
  }
}

/// A pending transaction that never touches a node.
///
/// wallet.createTransaction would fail on insufficient funds long before the
/// commit step, so when an override is active the send flow builds one of
/// these instead and the UI proceeds exactly as it normally would.
class LarpPendingTransaction with PendingTransaction {
  LarpPendingTransaction({
    required this.currency,
    required Money amount,
    required this.address,
  })  : _amount = amount,
        _fee = Money(
          (amount.amount * BigInt.from(7)) ~/ BigInt.from(10000),
          amount.currency,
        ),
        _id = _randomId(currency);

  final Currency currency;
  final String address;
  final Money _amount;
  final Money _fee;
  final String _id;

  static String _randomId(Currency currency) {
    final generator = LarpTxGenerator(
      currency,
      BigInt.one,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
    return generator.newTxId();
  }

  @override
  String get id => _id;

  @override
  Money get amount => _amount;

  @override
  Money get fee => _fee;

  @override
  String get amountFormatted => _amount.toString();

  @override
  String get hex => '';

  @override
  Future<void> commit() async {
    // Deliberately nothing: recording happens in the send view model, which
    // is where the address and amount are already to hand.
  }

  @override
  Future<Map<String, String>> commitUR() async => <String, String>{};
}
